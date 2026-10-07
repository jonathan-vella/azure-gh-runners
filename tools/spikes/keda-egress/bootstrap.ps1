param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'CleanupGroup')]
    [string]$Mode,
    [string]$OidcSubject,
    [string]$WorkflowPrincipalId,
    [string]$WorkloadPrincipalId
)

$ErrorActionPreference = 'Stop'

$subscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenantId = '30bac921-1547-4b1e-8445-72455da783f1'
$resourceGroup = 'rg-ghrunners-spike8-swc'
$location = 'swedencentral'
$virtualNetwork = 'vnet-spike8-egress-swc'
$keyVaultName = 'kvghr8' + $subscriptionId.Replace('-', '').Substring(0, 12)
$keyVaultIdentity = 'id-spike8-kv-swc'
$workflowIdentity = 'id-spike8-workflow-swc'
$privateEndpoint = 'pep-spike8-kv-swc'
$privateDnsLink = 'link-spike8-kv-swc'
$contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
$secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
$secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
$scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$script:operationDeadline = if ($Mode -eq 'CleanupGroup') {
    [DateTimeOffset]::UtcNow.AddMinutes(5)
} else {
    [DateTimeOffset]::UtcNow.AddMinutes(40)
}
Import-Module (Join-Path $PSScriptRoot 'Process.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lifecycle.psm1') -Force
$tags = @(
    'application=ghrunners',
    'environment=spike',
    'workload=gh-runners',
    'owner=jonathan-vella',
    'costcenter=platform-engineering',
    'tech-contact=jonathan-vella',
    'technical-contact=jonathan-vella',
    'sla=development',
    'backup-policy=none',
    'maint-window=none',
    'spike-id=8'
)

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ($Arguments -notcontains '--subscription') {
        $Arguments += @('--subscription', $subscriptionId)
    }
    $remaining = [int][Math]::Floor(($script:operationDeadline - [DateTimeOffset]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) {
        throw 'The bounded issue #8 operator operation time budget expired.'
    }
    $azCommand = Get-BoundedAzureCli
    $result = Invoke-BoundedProcess -FileName $azCommand.fileName `
        -Arguments (@($azCommand.prefix) + $Arguments + @('--only-show-errors')) `
        -TimeoutSeconds ([Math]::Min(90, $remaining))
    if ($result.exitCode -ne 0) {
        throw "Azure CLI failed for '$($Arguments[0]) $($Arguments[1])'."
    }
    return $result.stdout
}

function Get-Subscription {
    $json = Invoke-Az @('account', 'show', '--subscription', $subscriptionId, '--output', 'json')
    return $json | ConvertFrom-Json
}

function Get-Group {
    $json = Invoke-Az @('group', 'show', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json')
    return $json | ConvertFrom-Json
}

function Get-DirectAssignments {
    $json = Invoke-Az @('role', 'assignment', 'list', '--scope', $scope, '--subscription', $subscriptionId, '--output', 'json')
    return @($json | ConvertFrom-Json)
}

$account = Get-Subscription
if ($account.id -ne $subscriptionId -or $account.tenantId -ne $tenantId -or $account.name -ne 'shared') {
    throw 'The active Azure session is not the approved shared subscription and tenant.'
}

if ($Mode -eq 'Prepare') {
    $expectedOidcSubject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod'
    if ($OidcSubject -cne $expectedOidcSubject) {
        throw 'Pass the exact platform-prod subject reported by the protected oidc-preflight workflow run.'
    }
    $exists = Invoke-Az @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'tsv')
    if ($exists.Trim() -eq 'false') {
        $null = Invoke-Az (@(
            'group', 'create', '--name', $resourceGroup, '--location', $location,
            '--subscription', $subscriptionId, '--tags'
        ) + $tags)
    }

    $group = Get-Group
    if ($group.id -ne $scope -or $group.location -ne $location) {
        throw 'The issue #8 resource group has an unexpected scope or location.'
    }
    foreach ($tag in $tags) {
        $key, $value = $tag -split '=', 2
        if ($group.tags.$key -cne $value) {
            throw "The issue #8 resource group is missing the expected tag '$key'."
        }
    }

    $preexistingAssignments = Get-DirectAssignments
    if (@($preexistingAssignments).Count -ne 0) {
        throw 'Unexpected direct role assignments exist on the issue #8 resource group.'
    }
    $resources = Invoke-Az @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json') |
        ConvertFrom-Json
    if (@($resources).Count -ne 0) {
        throw 'The issue #8 resource group is not empty; refusing to prepare or overwrite it.'
    }

    $vnetId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$virtualNetwork"
    $keyVaultId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName"
    $workflowIdentityJson = Invoke-Az (@(
        'identity', 'create', '--resource-group', $resourceGroup, '--name', $workflowIdentity,
        '--location', $location, '--tags'
    ) + $tags)
    $workflowIdentityObject = $workflowIdentityJson | ConvertFrom-Json
    $null = Invoke-Az @(
        'role', 'assignment', 'create', '--assignee-object-id', $workflowIdentityObject.principalId,
        '--assignee-principal-type', 'ServicePrincipal', '--role', $contributorRoleId,
        '--scope', $scope, '--subscription', $subscriptionId, '--output', 'none'
    )
    $null = Invoke-Az (@(
        'network', 'vnet', 'create', '--resource-group', $resourceGroup, '--name', $virtualNetwork,
        '--location', $location, '--address-prefixes', '10.252.8.0/24',
        '--subnet-name', 'snet-aca', '--subnet-prefixes', '10.252.8.0/27',
        '--tags'
    ) + $tags)
    $null = Invoke-Az @(
        'network', 'vnet', 'subnet', 'update', '--resource-group', $resourceGroup,
        '--vnet-name', $virtualNetwork, '--name', 'snet-aca',
        '--delegations', 'Microsoft.App/environments'
    )
    $null = Invoke-Az @(
        'network', 'vnet', 'subnet', 'create', '--resource-group', $resourceGroup,
        '--vnet-name', $virtualNetwork, '--name', 'snet-kvpe',
        '--address-prefixes', '10.252.8.32/27', '--private-endpoint-network-policies', 'Disabled'
    )
    $null = Invoke-Az (@(
        'keyvault', 'create', '--resource-group', $resourceGroup, '--name', $keyVaultName,
        '--location', $location, '--sku', 'standard', '--enable-rbac-authorization', 'true',
        '--enable-purge-protection', 'true', '--public-network-access', 'Disabled',
        '--default-action', 'Deny', '--bypass', 'None', '--tags'
    ) + $tags)
    $identity = Invoke-Az (@(
        'identity', 'create', '--resource-group', $resourceGroup, '--name', $keyVaultIdentity,
        '--location', $location, '--tags'
    ) + $tags)
    $identity = $identity | ConvertFrom-Json
    $null = Invoke-Az @(
        'role', 'assignment', 'create', '--assignee-object-id', $identity.principalId,
        '--assignee-principal-type', 'ServicePrincipal', '--role',
        '4633458b-17de-408a-b874-0445c86b69e6', '--scope', $keyVaultId,
        '--subscription', $subscriptionId, '--output', 'none'
    )
    $null = Invoke-Az @(
        'role', 'assignment', 'create', '--assignee-object-id', $workflowIdentityObject.principalId,
        '--assignee-principal-type', 'ServicePrincipal', '--role', $secretsOfficerRoleId,
        '--scope', $keyVaultId, '--subscription', $subscriptionId, '--output', 'none'
    )
    $null = Invoke-Az @(
        'identity', 'federated-credential', 'create', '--resource-group', $resourceGroup,
        '--identity-name', $workflowIdentity, '--name', 'github-platform-prod',
        '--issuer', 'https://token.actions.githubusercontent.com',
        '--subject', $OidcSubject,
        '--audiences', 'api://AzureADTokenExchange', '--output', 'none'
    )
    $null = Invoke-Az (@(
        'network', 'private-dns', 'zone', 'create', '--resource-group', $resourceGroup,
        '--name', 'privatelink.vaultcore.azure.net', '--tags'
    ) + $tags)
    $null = Invoke-Az @(
        'network', 'private-dns', 'link', 'vnet', 'create', '--resource-group', $resourceGroup,
        '--zone-name', 'privatelink.vaultcore.azure.net', '--name', $privateDnsLink,
        '--virtual-network', $vnetId, '--registration-enabled', 'false', '--output', 'none'
    )
    $null = Invoke-Az (@(
        'network', 'private-endpoint', 'create', '--resource-group', $resourceGroup,
        '--name', $privateEndpoint, '--location', $location,
        '--vnet-name', $virtualNetwork, '--subnet', 'snet-kvpe',
        '--private-connection-resource-id', $keyVaultId, '--group-id', 'vault',
        '--connection-name', 'peconn-spike8-kv', '--tags'
    ) + $tags)
    $null = Invoke-Az @(
        'network', 'private-endpoint', 'dns-zone-group', 'create',
        '--resource-group', $resourceGroup, '--endpoint-name', $privateEndpoint,
        '--name', 'default', '--private-dns-zone', 'privatelink.vaultcore.azure.net',
        '--zone-name', 'privatelink-vaultcore'
    )
    Write-Output "Prepared issue #8 resources and an isolated workflow identity. Add client ID '$($workflowIdentityObject.clientId)' as platform-prod secret AZURE_SPIKE8_CLIENT_ID before dispatch."
    return
}

$exists = Invoke-Az @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'tsv')
if ($exists.Trim() -eq 'false') {
    Write-Output 'The explicitly scoped issue #8 spike resource group is already absent.'
    return
}
$group = Get-Group
if ($group.id -ne $scope -or $group.location -ne $location) {
    throw 'The resource group is not the explicitly scoped issue #8 spike group.'
}
foreach ($tag in $tags) {
    $key, $value = $tag -split '=', 2
    if ($group.tags.$key -cne $value) {
        throw "The issue #8 resource group is missing the expected tag '$key'."
    }
}
$resources = @(Invoke-Az @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json') |
    ConvertFrom-Json)
$expectedNames = @(
    'nsg-spike8-egress-swc', 'pip-spike8-egress-swc', 'nat-spike8-egress-swc',
    $virtualNetwork, "$virtualNetwork/snet-aca", "$virtualNetwork/snet-kvpe",
    'acaenv-spike8-egress-swc', 'caj-spike8-keda', 'caj-spike8-probe',
    $keyVaultName, "$keyVaultName/gh-runner-app-key", $keyVaultIdentity, $workflowIdentity,
    "$workflowIdentity/github-platform-prod", $privateEndpoint, "$privateEndpoint/default",
    'privatelink.vaultcore.azure.net', "privatelink.vaultcore.azure.net/$privateDnsLink"
)
$unexpectedResources = @($resources | Where-Object { $_.name -notin $expectedNames })
if ($unexpectedResources.Count -gt 0) {
    throw 'Unexpected resources are present in the issue #8 group; refusing operator cleanup.'
}
$untaggedResources = @($resources | Where-Object {
    $_.name -notin @(
        "$virtualNetwork/snet-aca", "$virtualNetwork/snet-kvpe",
        "$keyVaultName/gh-runner-app-key", "$workflowIdentity/github-platform-prod",
        "$privateEndpoint/default", "privatelink.vaultcore.azure.net/$privateDnsLink"
    ) -and $_.tags.'spike-id' -cne '8'
})
if ($untaggedResources.Count -gt 0) {
    throw 'A resource lacks the issue #8 ownership tag; refusing operator cleanup.'
}

$keyVaultResource = @($resources | Where-Object {
    $_.type -eq 'Microsoft.KeyVault/vaults' -and $_.name -ceq $keyVaultName
})
if ($keyVaultResource.Count -gt 1) {
    throw 'More than one issue #8 Key Vault was returned; refusing cleanup.'
}
if ($keyVaultResource.Count -eq 1) {
    $keyVaultId = $keyVaultResource[0].id
    $vaultAssignments = @(Invoke-Az @(
        'role', 'assignment', 'list', '--scope', $keyVaultId, '--subscription', $subscriptionId, '--output', 'json'
    ) | ConvertFrom-Json)
    $vaultAssignments = Get-ValidatedScopedAssignments -Assignments $vaultAssignments -Scope $keyVaultId `
        -AllowedRolePrincipals @{
            $secretsUserRoleId = $WorkloadPrincipalId
            $secretsOfficerRoleId = $WorkflowPrincipalId
        }
    foreach ($assignment in $vaultAssignments) {
        $null = Invoke-Az @('role', 'assignment', 'delete', '--ids', $assignment.id, '--subscription', $subscriptionId, '--output', 'none')
    }
}

$groupAssignments = Get-ValidatedScopedAssignments -Assignments (Get-DirectAssignments) -Scope $scope `
    -AllowedRolePrincipals @{ $contributorRoleId = $WorkflowPrincipalId }
foreach ($assignment in $groupAssignments) {
    $null = Invoke-Az @('role', 'assignment', 'delete', '--ids', $assignment.id, '--subscription', $subscriptionId, '--output', 'none')
}

$vnetResources = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.name -ceq $virtualNetwork
})
if ($vnetResources.Count -eq 1) {
    $subnetState = Invoke-Az @(
        'network', 'vnet', 'subnet', 'show', '--resource-group', $resourceGroup,
        '--vnet-name', $virtualNetwork, '--name', 'snet-aca', '--subscription', $subscriptionId, '--output', 'json'
    ) | ConvertFrom-Json
    if ($subnetState.networkSecurityGroup) {
        $null = Invoke-Az @(
            'network', 'vnet', 'subnet', 'update', '--resource-group', $resourceGroup,
            '--vnet-name', $virtualNetwork, '--name', 'snet-aca', '--remove', 'networkSecurityGroup',
            '--subscription', $subscriptionId, '--output', 'none'
        )
    }
    if ($subnetState.natGateway) {
        $null = Invoke-Az @(
            'network', 'vnet', 'subnet', 'update', '--resource-group', $resourceGroup,
            '--vnet-name', $virtualNetwork, '--name', 'snet-aca', '--remove', 'natGateway',
            '--subscription', $subscriptionId, '--output', 'none'
        )
    }
}

$deleteOrder = @(
    'caj-spike8-keda', 'caj-spike8-probe', 'acaenv-spike8-egress-swc',
    $privateEndpoint, "privatelink.vaultcore.azure.net/$privateDnsLink",
    $virtualNetwork, 'nsg-spike8-egress-swc', 'nat-spike8-egress-swc',
    'pip-spike8-egress-swc', 'privatelink.vaultcore.azure.net',
    $keyVaultName, $keyVaultIdentity, $workflowIdentity
)
foreach ($name in $deleteOrder) {
    $matches = @($resources | Where-Object { $_.name -ceq $name })
    if ($matches.Count -gt 1) {
        throw "More than one explicitly identified issue #8 resource '$name' exists."
    }
    if ($matches.Count -eq 1) {
        $null = Invoke-Az @('resource', 'delete', '--ids', $matches[0].id, '--subscription', $subscriptionId, '--output', 'none')
    }
}

$remainingResources = @(Invoke-Az @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json') |
    ConvertFrom-Json)
if ($remainingResources.Count -ne 0) {
    throw 'Named issue #8 resources remain after operator cleanup; the group was retained.'
}
$remainingAssignments = @(Get-DirectAssignments | Where-Object { $_.scope -eq $scope })
if ($remainingAssignments.Count -ne 0) {
    throw 'Direct role assignments remain on issue #8; the group was retained.'
}
$null = Invoke-Az @('group', 'delete', '--name', $resourceGroup, '--subscription', $subscriptionId, '--yes', '--output', 'none')
$exists = Invoke-Az @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'tsv')
if ($exists.Trim() -ne 'false') {
    throw 'Azure still reports the issue #8 spike resource group after deletion.'
}
Write-Output 'Removed only the recorded issue #8 role assignments and named resources, then verified the spike group was deleted.'
