#Requires -Version 7.0
<#
.SYNOPSIS
Bootstraps (or tears down) the identity and resource group for the isolated Windows runner backend.

.DESCRIPTION
Idempotent. Verifies every precondition and stops on unexpected state. Creates no secrets or certificates.
Supports -WhatIf. Run only after the owner approves; see docs/runbooks/bootstrap-windows.md.

Creates, when missing:
  - resource group with governance tags;
  - Entra app + service principal with ONE federated credential (the immutable-ID environment subject);
  - Owner on that resource group only (needed to create the orchestrator's role assignments);
  - the environment variable WINDOWS_AZURE_CLIENT_ID on the GitHub environment.

The Linux platform identity is never read, used or modified.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')][string]$TenantId,
    [string]$Location = 'swedencentral',
    [string]$ResourceGroupName = 'rg-ghrunners-win-swc',
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,39}$')][string]$Owner,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{1,100}$')][string]$Repo,
    [string]$EnvironmentName = 'platform-prod',
    [string]$AppDisplayName = 'sp-ghrunners-windows-deploy',
    [string]$CredentialName = 'gh-platform-prod-windows',
    [string]$CostCenter = 'platform-engineering',
    [switch]$Teardown,
    [switch]$DeleteResourceGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
$audience = 'api://AzureADTokenExchange'
$issuer = 'https://token.actions.githubusercontent.com'
$variableName = 'WINDOWS_AZURE_CLIENT_ID'
$repoSlug = "$Owner/$Repo"
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$requiredProviders = @(
    'Microsoft.App', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ContainerRegistry',
    'Microsoft.OperationalInsights', 'Microsoft.ManagedIdentity', 'Microsoft.Insights', 'Microsoft.Consumption'
)
$tags = [ordered]@{
    application = 'ghrunners'; environment = 'prod'; workload = 'gh-runners-windows'
    owner = $Owner; costcenter = $CostCenter; 'tech-contact' = $Owner; 'technical-contact' = $Owner
    sla = 'development'; 'backup-policy' = 'none'; 'maint-window' = 'none'
}

# The Windows MSI Azure CLI is invoked through its bundled Python to keep JSON quoting intact.
$azCommand = (Get-Command az -ErrorAction Stop).Source
$azPython = if ($IsWindows) { Join-Path (Split-Path $azCommand) '..\python.exe' } else { $null }
function Invoke-Az {
    $output = if ($azPython -and (Test-Path $azPython)) { & $azPython -IBm azure.cli @args --only-show-errors } else { & az @args --only-show-errors }
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed ($($args[0..1] -join ' ')); stop." }
    $output
}
function Invoke-Gh {
    $output = & gh @args
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI command failed ($($args[0..1] -join ' ')); stop." }
    $output
}
function ConvertFrom-CliJson($text) {
    $joined = ($text -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    $joined | ConvertFrom-Json -Depth 20
}
function Get-AzJson { ConvertFrom-CliJson (Invoke-Az @args -o json) }
function Get-GhJson { ConvertFrom-CliJson (Invoke-Gh @args) }

function Assert-Condition($condition, $message) { if (-not $condition) { throw "Unexpected state: $message" } }

# --- Preconditions (read-only; always run, including under -WhatIf) ---
$null = Get-Command gh -ErrorAction Stop
$account = Get-AzJson account show --subscription $SubscriptionId
Assert-Condition ($account.id -eq $SubscriptionId -and $account.tenantId -eq $TenantId) 'Azure CLI is not signed in to the given subscription and tenant.'
Assert-Condition ($account.state -eq 'Enabled') 'The subscription is not enabled.'

$repoInfo = Get-GhJson api "repos/$repoSlug"
Assert-Condition ($repoInfo.full_name -ieq $repoSlug) 'GitHub repository lookup mismatch.'

$oidc = Get-GhJson api "repos/$repoSlug/actions/oidc/customization/sub"
Assert-Condition ($oidc.use_default -eq $true) 'The repository customizes the OIDC subject claim; this script expects the default.'
Assert-Condition ($oidc.use_immutable_subject -eq $true) 'The repository does not use immutable-ID OIDC subjects; enable them first.'
$expectedPrefix = "repo:$($repoInfo.owner.login)@$($repoInfo.owner.id)/$($repoInfo.name)@$($repoInfo.id)"
Assert-Condition ($oidc.sub_claim_prefix -ceq $expectedPrefix) "OIDC prefix '$($oidc.sub_claim_prefix)' does not match the repository IDs ('$expectedPrefix')."
$subject = "$($oidc.sub_claim_prefix):environment:$EnvironmentName"

$environment = Get-GhJson api "repos/$repoSlug/environments/$EnvironmentName"
Assert-Condition ($environment.deployment_branch_policy.custom_branch_policies -eq $true -and $environment.deployment_branch_policy.protected_branches -eq $false) "Environment $EnvironmentName must restrict deployments to selected branches."
$branchPolicies = Get-GhJson api "repos/$repoSlug/environments/$EnvironmentName/deployment-branch-policies"
Assert-Condition ($branchPolicies.total_count -eq 1 -and $branchPolicies.branch_policies[0].name -ceq 'main' -and $branchPolicies.branch_policies[0].type -ceq 'branch') "Environment $EnvironmentName must allow only the main branch."

$apps = @(Get-AzJson ad app list --display-name $AppDisplayName | Where-Object { $_.displayName -ceq $AppDisplayName })
Assert-Condition ($apps.Count -le 1) "More than one Entra app is named '$AppDisplayName'."
$app = $apps | Select-Object -First 1

$groupExists = (Invoke-Az group exists --subscription $SubscriptionId --name $ResourceGroupName -o tsv) -join '' -eq 'true'
$group = if ($groupExists) { Get-AzJson group show --subscription $SubscriptionId --name $ResourceGroupName } else { $null }

function Get-ServicePrincipal($appId) {
    $found = @(Get-AzJson ad sp list --filter "appId eq '$appId'")
    Assert-Condition ($found.Count -le 1) 'More than one service principal for the app.'
    $found | Select-Object -First 1
}

# --- Teardown ---
if ($Teardown) {
    if ($app) {
        $sp = Get-ServicePrincipal $app.appId
        if ($sp) {
            $assignments = @(Get-AzJson role assignment list --subscription $SubscriptionId --assignee $sp.id --all)
            foreach ($assignment in $assignments) {
                Assert-Condition ($assignment.scope -ieq $scope) "The service principal has an assignment outside $scope; stop and review."
                if ($PSCmdlet.ShouldProcess($assignment.id, 'Delete role assignment')) {
                    $null = Invoke-Az role assignment delete --ids $assignment.id
                }
            }
        }
        if ($PSCmdlet.ShouldProcess($AppDisplayName, 'Delete Entra app (removes its federated credential and service principal)')) {
            $null = Invoke-Az ad app delete --id $app.id
        }
    }
    else {
        Write-Host "Entra app '$AppDisplayName' not found; nothing to delete."
    }
    $existingVariables = @((Get-GhJson api "repos/$repoSlug/environments/$EnvironmentName/variables").variables | ForEach-Object { $_.name })
    if ($variableName -in $existingVariables -and $PSCmdlet.ShouldProcess("$repoSlug/$EnvironmentName/$variableName", 'Delete environment variable')) {
        $null = Invoke-Gh variable delete $variableName --repo $repoSlug --env $EnvironmentName
    }
    if ($DeleteResourceGroup) {
        if ($group) {
            Assert-Condition ($group.tags.workload -ceq 'gh-runners-windows') "Resource group $ResourceGroupName is not tagged workload=gh-runners-windows; refusing to delete it."
            if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and everything in it')) {
                $null = Invoke-Az group delete --subscription $SubscriptionId --name $ResourceGroupName --yes --no-wait
                Write-Host 'Resource group deletion started (asynchronous).'
            }
        }
    }
    else {
        Write-Host "Resource group $ResourceGroupName was kept. Re-run with -DeleteResourceGroup to remove it."
    }
    return
}

# --- Provisioning preconditions ---
foreach ($provider in $requiredProviders) {
    $state = (Invoke-Az provider show --subscription $SubscriptionId --namespace $provider --query registrationState -o tsv) -join ''
    Assert-Condition ($state -eq 'Registered') "Resource provider $provider is '$state'; register it first (this script does not change subscription-wide settings)."
}
if ($group) {
    Assert-Condition ($group.location -eq $Location) "Resource group $ResourceGroupName exists in '$($group.location)', expected '$Location'."
}

# --- Resource group ---
if (-not $group) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $Location with governance tags")) {
        $tagArguments = $tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $group = Get-AzJson group create --subscription $SubscriptionId --name $ResourceGroupName --location $Location --tags @tagArguments
    }
}
else {
    $missing = $tags.GetEnumerator() | Where-Object { -not ($group.tags -and $group.tags.PSObject.Properties[$_.Key]) }
    if ($missing -and $PSCmdlet.ShouldProcess($ResourceGroupName, 'Add missing governance tags')) {
        $tagArguments = $missing | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $null = Invoke-Az tag update --subscription $SubscriptionId --resource-id $scope --operation Merge --tags @tagArguments
    }
}

# --- Entra app, service principal, federated credential (no secrets or certificates) ---
if (-not $app) {
    if ($PSCmdlet.ShouldProcess($AppDisplayName, 'Create Entra app registration (single tenant)')) {
        $app = Get-AzJson ad app create --display-name $AppDisplayName --sign-in-audience AzureADMyOrg
    }
}
if ($app) {
    Assert-Condition (@($app.passwordCredentials).Count -eq 0 -and @($app.keyCredentials).Count -eq 0) 'The app has password or certificate credentials; this identity must use OIDC only.'
}
$appId = if ($app) { $app.appId } else { '<new-app-id>' }
$sp = if ($app) { Get-ServicePrincipal $app.appId } else { $null }
if ($app -and -not $sp) {
    if ($PSCmdlet.ShouldProcess($AppDisplayName, 'Create service principal')) {
        $sp = Get-AzJson ad sp create --id $app.appId
    }
}

if ($app) {
    $credentials = @(Get-AzJson ad app federated-credential list --id $app.id)
    Assert-Condition ($credentials.Count -le 1) 'The app has more than one federated credential; this identity must have exactly one.'
    if ($credentials.Count -eq 1) {
        $existing = $credentials[0]
        Assert-Condition ($existing.name -ceq $CredentialName -and $existing.issuer -ceq $issuer -and $existing.subject -ceq $subject -and @($existing.audiences).Count -eq 1 -and $existing.audiences[0] -ceq $audience) 'The existing federated credential does not match the expected immutable environment subject.'
    }
    elseif ($PSCmdlet.ShouldProcess($CredentialName, "Create federated credential for subject $subject")) {
        $parameterFile = New-TemporaryFile
        try {
            @{ name = $CredentialName; issuer = $issuer; subject = $subject; audiences = @($audience); description = "GitHub Actions deploy for $repoSlug ($EnvironmentName)" } |
                ConvertTo-Json | Set-Content -Path $parameterFile -Encoding utf8
            $null = Invoke-Az ad app federated-credential create --id $app.id --parameters "@$parameterFile"
        }
        finally {
            Remove-Item $parameterFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Owner on the resource group only ---
if ($sp) {
    $assignments = @(Get-AzJson role assignment list --subscription $SubscriptionId --assignee $sp.id --all)
    foreach ($assignment in $assignments) {
        Assert-Condition ($assignment.scope -ieq $scope -and $assignment.roleDefinitionName -ceq 'Owner') "Unexpected role assignment '$($assignment.roleDefinitionName)' at '$($assignment.scope)'; the identity may hold only Owner on $ResourceGroupName."
    }
    if ($assignments.Count -eq 0 -and $PSCmdlet.ShouldProcess($scope, 'Assign Owner to the Windows deploy identity (resource group scope only)')) {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try {
                $null = Invoke-Az role assignment create --subscription $SubscriptionId --assignee-object-id $sp.id --assignee-principal-type ServicePrincipal --role $ownerRoleId --scope $scope
                break
            }
            catch {
                if ($attempt -eq 6) { throw }
                Start-Sleep -Seconds 10
            }
        }
    }
}

# --- GitHub environment variable (a non-secret client ID) ---
if ($app) {
    $current = @((Get-GhJson api "repos/$repoSlug/environments/$EnvironmentName/variables").variables) |
        Where-Object { $_ -and $_.name -ceq $variableName } | Select-Object -First 1
    if ((-not $current -or $current.value -cne $appId) -and $PSCmdlet.ShouldProcess("$repoSlug/$EnvironmentName/$variableName", 'Set environment variable')) {
        $null = Invoke-Gh variable set $variableName --repo $repoSlug --env $EnvironmentName --body $appId
    }
}

Write-Host ''
Write-Host "Subject         : $subject"
Write-Host "Resource group  : $ResourceGroupName ($Location)"
Write-Host "Windows app/ID  : $AppDisplayName / $appId"
Write-Host "Role            : Owner at $scope only"
Write-Host "GitHub variable : $variableName (environment $EnvironmentName)"
if ($WhatIfPreference) { Write-Host 'WhatIf: nothing was changed.' }
