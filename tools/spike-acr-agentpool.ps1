param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Setup', 'Cleanup')]
    [string]$Action,

    [string]$ClientId
)

$ErrorActionPreference = 'Stop'
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenant = '30bac921-1547-4b1e-8445-72455da783f1'
$resourceGroup = 'rg-ghrunners-spike6-swc'
$registry = 'ghrunners6jv20261007'
$applicationName = 'sp-ghrunners-spike6-20261007'
$branch = 'main'
$repository = 'jonathan-vella/azure-gh-runners'
$location = 'swedencentral'
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
    'maint-window=none'
)

function Invoke-Az {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' ')"
    }
}

function Get-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & az @Arguments -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' ')"
    }
    $output | ConvertFrom-Json
}

function Assert-Account {
    $account = Get-AzJson @('account', 'show', '--subscription', $subscription)
    if ($account.id -ne $subscription -or $account.tenantId -ne $tenant -or $account.name -ne 'shared') {
        throw 'Azure subscription or tenant mismatch; refusing the spike operation.'
    }
}

function Get-SpikeGroup {
    $exists = & az group exists --subscription $subscription --name $resourceGroup -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not check the exact spike resource group.' }
    if ($exists -ne 'true') { return $null }

    $group = Get-AzJson @('group', 'show', '--subscription', $subscription, '--name', $resourceGroup)
    if ($group.location -ne $location -or $group.tags.environment -ne 'spike' -or
        $group.tags.application -ne 'ghrunners') {
        throw 'The resource group exists but does not match the spike ownership tags; refusing to modify it.'
    }
    return $group
}

function Remove-SpikeGroup {
    if ($null -ne (Get-SpikeGroup)) {
        Invoke-Az @('group', 'delete', '--subscription', $subscription, '--name', $resourceGroup, '--yes', '--no-wait')
        $deleted = $false
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $exists = & az group exists --subscription $subscription --name $resourceGroup -o tsv
            if ($LASTEXITCODE -ne 0) { throw 'Could not verify spike resource group deletion.' }
            if ($exists -eq 'false') { $deleted = $true; break }
            if ($attempt -lt 20) { Start-Sleep -Seconds 30 }
        }
        if (-not $deleted) { throw 'Spike resource group deletion was not verified within 10 minutes.' }
    }
}

Assert-Account
$group = Get-SpikeGroup

if ($Action -eq 'Setup') {
    if ($null -ne $group) { throw 'Spike resource group already exists; setup is intentionally non-idempotent.' }
    $apps = @(Get-AzJson @('ad', 'app', 'list', '--display-name', $applicationName) |
        Where-Object displayName -eq $applicationName)
    if ($apps.Count -ne 0) { throw 'Spike app name already exists; refusing to reuse it.' }
    $nameCheck = Get-AzJson @('acr', 'check-name', '--name', $registry, '--subscription', $subscription)
    if (-not $nameCheck.nameAvailable) { throw 'The fixed spike registry name is unavailable.' }

    $app = $null
    $sp = $null
    try {
        $groupArguments = @('group', 'create', '--subscription', $subscription, '--name', $resourceGroup,
            '--location', $location, '--tags') + $tags
        Invoke-Az $groupArguments
        $registryArguments = @('acr', 'create', '--subscription', $subscription, '--resource-group', $resourceGroup,
            '--name', $registry, '--location', $location, '--sku', 'Premium', '--admin-enabled', 'false',
            '--public-network-enabled', 'false', '--tags') + $tags
        Invoke-Az $registryArguments

        $app = Get-AzJson @('ad', 'app', 'create', '--display-name', $applicationName,
            '--sign-in-audience', 'AzureADMyOrg')
        $sp = Get-AzJson @('ad', 'sp', 'create', '--id', $app.appId)
        $ficPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
        try {
            @{
                name = 'ghrunners-spike6-main'
                issuer = 'https://token.actions.githubusercontent.com'
                subject = "repo:${repository}:ref:refs/heads/${branch}"
                audiences = @('api://AzureADTokenExchange')
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ficPath -Encoding ascii
            Invoke-Az @('ad', 'app', 'federated-credential', 'create', '--id', $app.appId,
                '--parameters', "@$ficPath", '--only-show-errors')
        } finally {
            Remove-Item -LiteralPath $ficPath -Force -ErrorAction SilentlyContinue
        }

        $groupScope = "/subscriptions/${subscription}/resourceGroups/${resourceGroup}"
        $registryScope = "$groupScope/providers/Microsoft.ContainerRegistry/registries/$registry"
        Invoke-Az @('role', 'assignment', 'create', '--subscription', $subscription,
            '--assignee-object-id', $sp.id, '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'Contributor', '--scope', $groupScope, '--only-show-errors')
        foreach ($role in @('AcrPush', 'Container Registry Tasks Contributor')) {
            Invoke-Az @('role', 'assignment', 'create', '--subscription', $subscription,
                '--assignee-object-id', $sp.id, '--assignee-principal-type', 'ServicePrincipal',
                '--role', $role, '--scope', $registryScope, '--only-show-errors')
        }

        $federatedCredentials = @(Get-AzJson @('ad', 'app', 'federated-credential', 'list',
            '--id', $app.appId))
        if ($federatedCredentials.Count -ne 1 -or
            $federatedCredentials[0].name -ne 'ghrunners-spike6-main' -or
            $federatedCredentials[0].subject -ne "repo:${repository}:ref:refs/heads/${branch}" -or
            $federatedCredentials[0].issuer -ne 'https://token.actions.githubusercontent.com' -or
            @($federatedCredentials[0].audiences).Count -ne 1 -or
            $federatedCredentials[0].audiences[0] -ne 'api://AzureADTokenExchange') {
            throw 'The temporary app federated credential readback did not match the exact main-branch subject.'
        }

        $assignments = @(Get-AzJson @('role', 'assignment', 'list', '--subscription', $subscription,
            '--assignee-object-id', $sp.id, '--all'))
        $appAssignments = @($assignments | Where-Object principalId -eq $sp.id)
        $validAssignments = @(
            @{ role = 'Contributor'; scope = $groupScope },
            @{ role = 'AcrPush'; scope = $registryScope },
            @{ role = 'Container Registry Tasks Contributor'; scope = $registryScope }
        )
        $invalidAssignments = @($appAssignments | Where-Object {
            $assignment = $_
            @($validAssignments | Where-Object {
                $_.role -eq $assignment.roleDefinitionName -and $_.scope -eq $assignment.scope
            }).Count -eq 0
        })
        if ($appAssignments.Count -ne $validAssignments.Count -or $invalidAssignments.Count -ne 0) {
            throw 'The temporary app role assignments did not match the spike allowlist.'
        }

        $readback = Get-AzJson @('acr', 'show', '--subscription', $subscription,
            '--resource-group', $resourceGroup, '--name', $registry)
        if ($readback.sku.name -ne 'Premium' -or $readback.publicNetworkAccess -ne 'Disabled' -or
            $readback.adminUserEnabled -ne $false) {
            throw 'ACR security settings did not match the required private Premium configuration.'
        }
    } catch {
        $setupError = $_
        try { Remove-SpikeGroup } catch { Write-Warning 'Spike resource-group rollback needs operator cleanup.' }
        if ($null -ne $app) {
            try {
                $createdPrincipals = @(Get-AzJson @('ad', 'sp', 'list', '--filter', "appId eq '$($app.appId)'"))
                foreach ($principal in $createdPrincipals) {
                    Invoke-Az @('ad', 'sp', 'delete', '--id', $principal.id, '--only-show-errors')
                }
                Invoke-Az @('ad', 'app', 'delete', '--id', $app.appId, '--only-show-errors')
            } catch { Write-Warning 'Temporary Entra identity rollback needs operator cleanup.' }
        }
        throw $setupError
    }
    Write-Output "Resource group: $resourceGroup"
    Write-Output "Registry: $registry"
    Write-Output "Client ID (workflow_dispatch input): $($app.appId)"
    Write-Output "FIC subject: repo:${repository}:ref:refs/heads/${branch}"
    Write-Output 'The temporary app has no password or certificate credential.'
    Write-Output "If the workflow fails or times out, run: .\tools\spike-acr-agentpool.ps1 -Action Cleanup -ClientId $($app.appId)"
    Write-Output 'The same cleanup command is required after every workflow outcome.'
    return
}

if ($Action -eq 'Cleanup') {
    if ([string]::IsNullOrWhiteSpace($ClientId) -or $ClientId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Cleanup requires the exact temporary app client ID printed by Setup.'
    }
    Remove-SpikeGroup
    $apps = @(Get-AzJson @('ad', 'app', 'list', '--display-name', $applicationName) |
        Where-Object { $_.displayName -eq $applicationName -and $_.appId -eq $ClientId })
    if ($apps.Count -ne 1) { throw 'Expected exactly one matching spike app before cleanup.' }
    $app = $apps[0]
    if (@($app.passwordCredentials).Count -ne 0 -or @($app.keyCredentials).Count -ne 0) {
        throw 'Unexpected reusable credential on the temporary spike app; refusing deletion.'
    }
    $federatedCredentials = @(Get-AzJson @('ad', 'app', 'federated-credential', 'list', '--id', $ClientId))
    if ($federatedCredentials.Count -ne 1 -or
        $federatedCredentials[0].name -ne 'ghrunners-spike6-main' -or
        $federatedCredentials[0].subject -ne "repo:${repository}:ref:refs/heads/${branch}" -or
        $federatedCredentials[0].issuer -ne 'https://token.actions.githubusercontent.com' -or
        @($federatedCredentials[0].audiences).Count -ne 1 -or
        $federatedCredentials[0].audiences[0] -ne 'api://AzureADTokenExchange') {
        throw 'Temporary app trust differs from the exact main-branch spike credential; refusing deletion.'
    }
    $servicePrincipals = @(Get-AzJson @('ad', 'sp', 'list', '--filter', "appId eq '$ClientId'"))
    if ($servicePrincipals.Count -ne 1) { throw 'Expected exactly one service principal for the spike app.' }
    $remainingAssignments = @(Get-AzJson @('role', 'assignment', 'list', '--subscription', $subscription,
        '--assignee-object-id', $servicePrincipals[0].id, '--all'))
    if ($remainingAssignments.Count -ne 0) {
        throw 'Role assignments remain for the temporary app after group deletion; refusing identity deletion.'
    }
    Invoke-Az @('ad', 'sp', 'delete', '--id', $servicePrincipals[0].id, '--only-show-errors')
    Invoke-Az @('ad', 'app', 'delete', '--id', $ClientId, '--only-show-errors')

    $remainingApps = @()
    $remainingSps = @()
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $remainingApps = @(Get-AzJson @('ad', 'app', 'list', '--display-name', $applicationName) |
            Where-Object { $_.displayName -eq $applicationName -and $_.appId -eq $ClientId })
        $remainingSps = @(Get-AzJson @('ad', 'sp', 'list', '--filter', "appId eq '$ClientId'"))
        if ($remainingApps.Count -eq 0 -and $remainingSps.Count -eq 0) { break }
        if ($attempt -lt 10) { Start-Sleep -Seconds 6 }
    }
    $groupExists = & az group exists --subscription $subscription --name $resourceGroup -o tsv
    if ($LASTEXITCODE -ne 0 -or $groupExists -ne 'false' -or
        $remainingApps.Count -ne 0 -or $remainingSps.Count -ne 0) {
        throw 'Cleanup assertion failed: spike group, app, or service principal remains.'
    }
    Write-Output 'Verified the spike resource group, app, and service principal are absent.'
}
