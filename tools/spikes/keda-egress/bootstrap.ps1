param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'CleanupGroup')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'

$subscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenantId = '30bac921-1547-4b1e-8445-72455da783f1'
$resourceGroup = 'rg-ghrunners-spike8-swc'
$location = 'swedencentral'
$deployClientId = '5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0'
$deployPrincipalId = '24ebb9cc-0e3b-4956-a333-5665a060f2c7'
$roleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
$scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
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

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed for '$($Arguments[0]) $($Arguments[1])'."
    }
    return ($output -join "`n")
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

$servicePrincipal = Invoke-Az @('ad', 'sp', 'show', '--id', $deployClientId, '--query', 'id', '--output', 'tsv')
if ($servicePrincipal.Trim() -ne $deployPrincipalId) {
    throw 'The platform-prod service principal does not match the approved identity.'
}

if ($Mode -eq 'Prepare') {
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

    $resources = Invoke-Az @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json') |
        ConvertFrom-Json
    if (@($resources).Count -ne 0) {
        throw 'The issue #8 resource group is not empty; refusing to prepare or overwrite it.'
    }

    $assignments = Get-DirectAssignments
    $ours = @($assignments | Where-Object {
        $_.principalId -eq $deployPrincipalId -and $_.roleDefinitionId -match "/$roleId$" -and $_.scope -eq $scope
    })
    if (@($assignments).Count -gt @($ours).Count) {
        throw 'Unexpected direct role assignments exist on the issue #8 resource group.'
    }
    if (@($ours).Count -gt 1) {
        throw 'Duplicate Contributor assignments exist on the issue #8 resource group.'
    }
    if (@($ours).Count -eq 0) {
        $null = Invoke-Az @(
            'role', 'assignment', 'create', '--assignee-object-id', $deployPrincipalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', $roleId,
            '--scope', $scope, '--subscription', $subscriptionId, '--output', 'none'
        )
    }
    Write-Output 'Prepared only the issue #8 resource group and its exact-scope Contributor grant.'
    return
}

$group = Get-Group
if ($group.id -ne $scope -or $group.location -ne $location -or $group.tags.'spike-id' -cne '8') {
    throw 'The resource group is not the explicitly tagged issue #8 spike group.'
}
$resources = Invoke-Az @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json') |
    ConvertFrom-Json
if (@($resources).Count -ne 0) {
    throw 'The issue #8 resource group is not empty; refusing to delete it.'
}

$assignments = Get-DirectAssignments
$unexpected = @($assignments | Where-Object {
    $_.principalId -ne $deployPrincipalId -or $_.roleDefinitionId -notmatch "/$roleId$" -or $_.scope -ne $scope
})
if (@($unexpected).Count -gt 0) {
    throw 'Unexpected direct role assignments exist on the issue #8 resource group; refusing cleanup.'
}
foreach ($assignment in $assignments) {
    $null = Invoke-Az @('role', 'assignment', 'delete', '--ids', $assignment.id, '--subscription', $subscriptionId, '--output', 'none')
}
$null = Invoke-Az @('group', 'delete', '--name', $resourceGroup, '--subscription', $subscriptionId, '--yes', '--output', 'none')
$exists = Invoke-Az @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'tsv')
if ($exists.Trim() -ne 'false') {
    throw 'Azure still reports the issue #8 resource group after deletion.'
}
Write-Output 'Deleted and verified the empty, explicitly tagged issue #8 spike resource group.'
