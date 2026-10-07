function Test-SpikeResourceGroupTags {
    param(
        [object]$Tags,
        [System.Collections.IDictionary]$ExpectedTags
    )

    foreach ($name in $ExpectedTags.Keys) {
        if ([string]$Tags.$name -cne [string]$ExpectedTags[$name]) {
            return $false
        }
    }
    return $true
}

function Test-SpikeResourceInventory {
    param([object[]]$Resources)

    foreach ($resource in $Resources) {
        $knownDns = (
            $resource.type -eq 'Microsoft.Network/privateDnsZones' -and $resource.name -in @(
                'privatelink.azurecr.io',
                'privatelink.vaultcore.azure.net'
            )
        ) -or (
            $resource.type -eq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' -and $resource.name -in @(
                'privatelink.azurecr.io/ghr9-vnet-link',
                'privatelink.vaultcore.azure.net/ghr9-vnet-link'
            )
        )
        $knownRole = $resource.type -eq 'Microsoft.Authorization/roleAssignments' -and
            $resource.id -match '/(registries/ghr9[^/]*|vaults/ghr9kv[^/]*)/providers/Microsoft.Authorization/roleAssignments/'
        $knownSpikeType = switch ($resource.type) {
            'Microsoft.App/managedEnvironments' { $resource.name -ceq 'ghr9-env' }
            'Microsoft.App/jobs' { $resource.name -ceq 'ghr9-secret-isolation' }
            'Microsoft.App/jobs/executions' { $resource.name -match '^ghr9-secret-isolation/[^/]+$' }
            'Microsoft.ContainerRegistry/registries' { $resource.name -match '^ghr9[a-z0-9]{5,}$' }
            'Microsoft.KeyVault/vaults' { $resource.name -match '^ghr9kv[a-z0-9]{5,}$' }
            'Microsoft.KeyVault/vaults/secrets' { $resource.name -match '^ghr9kv[a-z0-9]{5,}/synthetic-app-key$' }
            'Microsoft.ManagedIdentity/userAssignedIdentities' { $resource.name -ceq 'ghr9-job-identity' }
            'Microsoft.Network/networkSecurityGroups' { $resource.name -ceq 'ghr9-aca-nsg' }
            'Microsoft.Network/natGateways' { $resource.name -ceq 'ghr9-nat' }
            'Microsoft.Network/privateEndpoints' { $resource.name -in @('ghr9-acr-pe', 'ghr9-vault-pe') }
            'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' { $resource.name -in @('ghr9-acr-pe/default', 'ghr9-vault-pe/default') }
            'Microsoft.Network/publicIPAddresses' { $resource.name -ceq 'ghr9-nat-pip' }
            'Microsoft.Network/virtualNetworks' { $resource.name -ceq 'ghr9-vnet' }
            'Microsoft.Network/virtualNetworks/subnets' { $resource.name -in @('ghr9-vnet/aca', 'ghr9-vnet/private-endpoints') }
            default { $false }
        }
        if (-not ($knownSpikeType -or $knownDns -or $knownRole)) {
            return $false
        }
    }
    return $true
}

function Test-SpikeExpiryTag {
    param([string]$Value)

    $expiry = [DateTimeOffset]::MinValue
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry)
}

function Test-CanaryHashLeak {
    param(
        [string[]]$EnvironmentLines,
        [string]$CanaryHash
    )

    foreach ($line in $EnvironmentLines) {
        $separator = $line.IndexOf('=')
        $value = if ($separator -ge 0) { $line.Substring($separator + 1) } else { $line }
        $valueHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()
        if ($valueHash -eq $CanaryHash) {
            return $true
        }
    }
    return $false
}

function Assert-DeploymentSucceeded {
    param([string]$State)

    if ($State -ne 'Succeeded') {
        throw "Deployment ended in state '$State'."
    }
}

function Assert-ProbeImageDigest {
    param([string]$Digest)

    if ([string]::IsNullOrWhiteSpace($Digest)) {
        throw 'Probe image digest is required.'
    }
    if ($Digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw 'Probe image digest must be a lowercase sha256 digest.'
    }
}

function Assert-Sha256Hex {
    param([string]$Value)

    if ($Value -notmatch '^[a-f0-9]{64}$') {
        throw 'Synthetic secret proof must be a lowercase SHA-256 hex digest.'
    }
}

function Get-Sha256Hex {
    param([string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-DeclaredBicepParameters {
    param(
        [string]$TemplateContent,
        [string[]]$ParameterNames
    )

    $declared = [regex]::Matches($TemplateContent, '(?m)^param\s+([A-Za-z_][A-Za-z0-9_]*)\s+') |
        ForEach-Object { $_.Groups[1].Value }
    foreach ($name in $ParameterNames) {
        if ($name -notin $declared) {
            throw "Deployment parameter '$name' is not declared by the Bicep template."
        }
    }
}

function Assert-AcaPeerRules {
    param([object[]]$Rules)

    foreach ($expected in @(
            @{ name = 'allow-aca-subnet-peer-ingress'; direction = 'Inbound' },
            @{ name = 'allow-aca-subnet-peer-egress'; direction = 'Outbound' }
        )) {
        $matches = @($Rules | Where-Object { $_.name -ceq $expected.name })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one '$($expected.name)' NSG rule."
        }
        $properties = $matches[0].properties
        if ($properties.priority -ne 200 -or $properties.direction -cne $expected.direction -or
            $properties.access -cne 'Allow' -or $properties.protocol -cne '*' -or
            $properties.sourceAddressPrefix -cne '10.82.0.0/27' -or
            $properties.destinationAddressPrefix -cne '10.82.0.0/27' -or
            $properties.sourcePortRange -cne '*' -or $properties.destinationPortRange -cne '*') {
            throw "The '$($expected.name)' rule does not narrowly allow only the ACA subnet peer traffic before the RFC1918 deny."
        }
    }

    foreach ($expected in @(
            @{ direction = 'Inbound'; rule = 'deny-rfc1918-lateral-ingress'; prefixProperty = 'sourceAddressPrefixes'; otherProperty = 'destinationAddressPrefix' },
            @{ direction = 'Outbound'; rule = 'deny-rfc1918-lateral-egress'; prefixProperty = 'destinationAddressPrefixes'; otherProperty = 'sourceAddressPrefix' }
        )) {
        $denyRules = @($Rules | Where-Object {
                $_.name -ceq $expected.rule -and
                $_.properties.direction -ceq $expected.direction -and $_.properties.access -ceq 'Deny' -and
                $_.properties.priority -eq 300
            })
        if ($denyRules.Count -ne 1) {
            throw "The RFC1918 $($expected.direction) deny must remain at priority 300."
        }
        $properties = $denyRules[0].properties
        if (@($properties.($expected.prefixProperty)) -notcontains '10.0.0.0/8' -or
            @($properties.($expected.prefixProperty)) -notcontains '172.16.0.0/12' -or
            @($properties.($expected.prefixProperty)) -notcontains '192.168.0.0/16' -or
            $properties.($expected.otherProperty) -cne '*') {
            throw "The RFC1918 $($expected.direction) deny no longer covers the complete private-address floor."
        }
    }
}

function Get-RemainingTimeoutSeconds {
    param([DateTime]$Deadline)

    $remaining = [Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) {
        return 0
    }
    return [int][Math]::Min($remaining, 3600)
}

function Invoke-DeadlinePoll {
    param(
        [DateTime]$Deadline,
        [scriptblock]$Action,
        [scriptblock]$IsComplete,
        [string]$TimeoutMessage,
        [int]$PollIntervalSeconds = 10,
        [scriptblock]$Clock = { [DateTime]::UtcNow },
        [scriptblock]$Sleeper = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    while ($true) {
        $remaining = [Math]::Ceiling(($Deadline - (& $Clock)).TotalSeconds)
        if ($remaining -lt 1) {
            throw $TimeoutMessage
        }
        $result = & $Action ([int][Math]::Min($remaining, 3600))
        if (& $IsComplete $result) {
            return $result
        }
        $remaining = [Math]::Ceiling(($Deadline - (& $Clock)).TotalSeconds)
        if ($remaining -lt 1) {
            throw $TimeoutMessage
        }
        & $Sleeper ([int][Math]::Min($PollIntervalSeconds, $remaining))
    }
}

function Assert-CapacityRecovered {
    param([bool]$Confirmed)

    if (-not $Confirmed) {
        throw 'Test requires explicit confirmation that swedencentral ACA capacity has recovered.'
    }
}

function Get-SanitizedAzureErrorCode {
    param([string]$Diagnostics)

    $knownCodes = @(
        'AKSCapacityHeavyUsage',
        'ManagedEnvironmentCapacityHeavyUsageError',
        'AuthorizationFailed',
        'ResourceNotFound',
        'DeploymentFailed',
        'InvalidTemplateDeployment',
        'Conflict',
        'TooManyRequests',
        'OperationNotAllowed'
    )
    foreach ($code in $knownCodes) {
        if ($Diagnostics -match "(?<![A-Za-z])$([regex]::Escape($code))(?![A-Za-z])") {
            return $code
        }
    }
    return 'unclassified'
}

function Wait-ProcessBounded {
    param(
        [Diagnostics.Process]$Process,
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds
    )

    if ($Process.WaitForExit($TimeoutSeconds * 1000)) {
        return $true
    }
    try {
        $Process.Kill($true)
        $null = $Process.WaitForExit(5000)
    } catch {
        throw 'Timed-out local process could not be terminated.'
    }
    return $false
}

function Assert-ImageTransferReceipt {
    param(
        [object]$Receipt,
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$RegistryName,
        [string]$Digest
    )

    Assert-ProbeImageDigest -Digest $Digest
    if ($Receipt.issue -ne 9 -or $Receipt.subscriptionId -cne $SubscriptionId -or
        $Receipt.resourceGroup -cne $ResourceGroup -or $Receipt.registryName -cne $RegistryName -or
        $Receipt.repository -cne 'probe' -or $Receipt.digest -cne $Digest -or
        $Receipt.destinationDigestReadBack -cne $Digest -or $Receipt.privateEndpointApproved -ne $true -or
        $Receipt.sourcePath -cne 'issue-6-private-agent-pool-transfer' -or
        [string]::IsNullOrWhiteSpace([string]$Receipt.verifiedBy) -or
        -not (Test-SpikeExpiryTag -Value ([string]$Receipt.verifiedAtUtc))) {
        throw 'Image transfer receipt does not attest private digest readback into the prepared issue-9 ACR.'
    }
}

Export-ModuleMember -Function Test-SpikeResourceGroupTags, Test-SpikeResourceInventory, Test-SpikeExpiryTag, Test-CanaryHashLeak, Assert-DeploymentSucceeded, Assert-ProbeImageDigest, Assert-Sha256Hex, Get-Sha256Hex, Assert-DeclaredBicepParameters, Assert-AcaPeerRules, Get-RemainingTimeoutSeconds, Invoke-DeadlinePoll, Assert-CapacityRecovered, Get-SanitizedAzureErrorCode, Wait-ProcessBounded, Assert-ImageTransferReceipt
