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
        $knownSpikeType = $resource.type -in @(
            'Microsoft.App/managedEnvironments',
            'Microsoft.ContainerRegistry/registries',
            'Microsoft.KeyVault/vaults',
            'Microsoft.KeyVault/vaults/secrets',
            'Microsoft.ManagedIdentity/userAssignedIdentities',
            'Microsoft.Network/networkSecurityGroups',
            'Microsoft.Network/natGateways',
            'Microsoft.Network/privateEndpoints',
            'Microsoft.Network/privateEndpoints/privateDnsZoneGroups',
            'Microsoft.Network/publicIPAddresses',
            'Microsoft.Network/virtualNetworks',
            'Microsoft.Network/virtualNetworks/subnets'
        ) -and $resource.name -like 'ghr9*'
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

Export-ModuleMember -Function Test-SpikeResourceGroupTags, Test-SpikeResourceInventory, Test-SpikeExpiryTag, Test-CanaryHashLeak, Assert-DeploymentSucceeded, Assert-ProbeImageDigest, Assert-CapacityRecovered, Get-SanitizedAzureErrorCode, Assert-ImageTransferReceipt
