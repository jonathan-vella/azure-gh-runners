[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Cleanup')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{4,16}$')]
    [string]$RunSuffix,

    [Parameter(Mandatory)]
    [string]$PullIdentityResourceId,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId
)

$ErrorActionPreference = 'Stop'
$subscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenantId = '30bac921-1547-4b1e-8445-72455da783f1'
$resourceGroup = 'rg-ghrunners-spike10-swc'
$appDisplayName = "sp-ghrunners-spike10-$RunSuffix"
$ficName = 'spike10-platform-prod'
$ficIssuer = 'https://token.actions.githubusercontent.com'
$ficSubjectPrefix = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667'
$ficSubject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod'
$ficAudience = 'api://AzureADTokenExchange'
$expectedResourceGroup = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
Import-Module (Join-Path $PSScriptRoot 'Bounded-Command.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SpikeIdentity-Cleanup.psm1') -Force

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = Invoke-BoundedNativeCommand -Command 'az' -Arguments $Arguments -TimeoutSeconds 30
    if ([string]::IsNullOrWhiteSpace(($output -join ''))) { return $null }
    return ($output -join "`n") | ConvertFrom-Json
}

function Assert-GitHubSubjectTemplate {
    $output = Invoke-BoundedNativeCommand -Command 'gh' -Arguments @(
        'api', 'repos/jonathan-vella/azure-gh-runners/actions/oidc/customization/sub'
    ) -TimeoutSeconds 15
    try {
        $metadata = ($output -join "`n") | ConvertFrom-Json
    } catch {
        throw 'Repository OIDC subject customization response was invalid.'
    }
    if ($metadata.use_default -ne $true -or
        $metadata.use_immutable_subject -ne $true -or
        $metadata.sub_claim_prefix -cne $ficSubjectPrefix) {
        throw 'Repository OIDC subject template differs from the verified immutable-ID template; refusing to continue.'
    }
}

$identityId = $PullIdentityResourceId.TrimEnd('/')
if ($identityId -notlike "$expectedResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*") {
    throw 'The pull/Key Vault identity must be inside the exact spike 10 resource group.'
}

$account = Invoke-AzJson -Arguments @('account', 'show', '--subscription', $subscriptionId, '--output', 'json')
if ($account.id -ne $subscriptionId -or $account.tenantId -ne $tenantId -or $account.name -ne 'shared') {
    throw 'Authenticate to the approved shared subscription and tenant before running this script.'
}

if ($Action -eq 'Prepare') {
    $group = Invoke-AzJson -Arguments @('group', 'show', '--name', $resourceGroup, '--subscription', $subscriptionId, '--output', 'json')
    if ($group.id -ne $expectedResourceGroup -or $group.location -ne 'swedencentral') {
        throw 'The exact issue 10 resource group is absent or has an unexpected scope/location.'
    }
    $identity = Invoke-AzJson -Arguments @('identity', 'show', '--ids', $identityId, '--subscription', $subscriptionId, '--output', 'json')
    if ($identity.id -ine $identityId) { throw 'The specified spike 10 pull identity could not be verified.' }

    Assert-GitHubSubjectTemplate
    $existing = Invoke-AzJson -Arguments @(
        'ad', 'app', 'list', '--display-name', $appDisplayName, '--output', 'json'
    )
    if (@($existing).Count -ne 0) {
        throw "An app named '$appDisplayName' already exists; refusing to reuse it."
    }
    $app = $null
    $servicePrincipal = $null
    try {
        $app = Invoke-AzJson -Arguments @(
            'ad', 'app', 'create', '--display-name', $appDisplayName,
            '--sign-in-audience', 'AzureADMyOrg', '--output', 'json'
        )
        $servicePrincipal = Invoke-AzJson -Arguments @(
            'ad', 'sp', 'create', '--id', $app.appId, '--output', 'json'
        )

        $federatedCredential = @{
            name = $ficName
            issuer = $ficIssuer
            subject = $ficSubject
            description = "Issue 10 temporary deployment identity for $RunSuffix"
            audiences = @($ficAudience)
        } | ConvertTo-Json -Compress
        $federatedCredentialPath = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText(
                $federatedCredentialPath,
                $federatedCredential,
                [System.Text.UTF8Encoding]::new($false)
            )
            Invoke-AzJson -Arguments @(
                'ad', 'app', 'federated-credential', 'create',
                '--id', $app.appId, '--parameters', "@$federatedCredentialPath", '--output', 'json'
            ) | Out-Null
        } finally {
            if (Test-Path -LiteralPath $federatedCredentialPath) {
                Remove-Item -LiteralPath $federatedCredentialPath -Force
            }
        }
        $createdCredential = Invoke-AzJson -Arguments @(
            'ad', 'app', 'federated-credential', 'list', '--id', $app.appId, '--output', 'json'
        )
        if (@($createdCredential).Count -ne 1 -or
            $createdCredential[0].name -cne $ficName -or
            $createdCredential[0].issuer -cne $ficIssuer -or
            $createdCredential[0].subject -cne $ficSubject -or
            @($createdCredential[0].audiences | Where-Object { $_ -ceq $ficAudience }).Count -ne 1) {
            throw 'Federated credential readback did not match the exact spike-10 subject and audience.'
        }

        foreach ($assignment in @(
            @{ role = 'Contributor'; scope = $expectedResourceGroup },
            @{ role = 'Managed Identity Operator'; scope = $identityId }
        )) {
            Invoke-AzJson -Arguments @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $servicePrincipal.id,
                '--assignee-principal-type', 'ServicePrincipal',
                '--role', $assignment.role,
                '--scope', $assignment.scope,
                '--subscription', $subscriptionId,
                '--output', 'json'
            ) | Out-Null
        }

        $assignments = Invoke-AzJson -Arguments @(
            'role', 'assignment', 'list',
            '--assignee-object-id', $servicePrincipal.id,
            '--all', '--include-inherited',
            '--subscription', $subscriptionId,
            '--output', 'json'
        )
        if (@($assignments).Count -ne 2 -or
            @($assignments | Where-Object { $_.roleDefinitionName -eq 'Contributor' -and $_.scope -ieq $expectedResourceGroup }).Count -ne 1 -or
            @($assignments | Where-Object { $_.roleDefinitionName -eq 'Managed Identity Operator' -and $_.scope -ieq $identityId }).Count -ne 1) {
            throw 'The temporary identity has unexpected RBAC assignments; stop and have an authorized operator inspect it.'
        }
    } catch {
        $cleanupFailed = $false
        if ($servicePrincipal) {
            try {
                $partialAssignments = Invoke-AzJson -Arguments @(
                    'role', 'assignment', 'list',
                    '--assignee-object-id', $servicePrincipal.id,
                    '--all', '--include-inherited',
                    '--subscription', $subscriptionId,
                    '--output', 'json'
                )
                foreach ($assignment in $partialAssignments) {
                    $expected = ($assignment.roleDefinitionName -eq 'Contributor' -and $assignment.scope -ieq $expectedResourceGroup) -or
                        ($assignment.roleDefinitionName -eq 'Managed Identity Operator' -and $assignment.scope -ieq $identityId)
                    if (-not $expected) { throw 'Unexpected partial identity assignment.' }
                    Invoke-AzJson -Arguments @(
                        'role', 'assignment', 'delete', '--ids', $assignment.id,
                        '--subscription', $subscriptionId, '--output', 'json'
                    ) | Out-Null
                }
            } catch { $cleanupFailed = $true }
        }
        if ($app -and -not $cleanupFailed) {
            try {
                $partialCredentials = Invoke-AzJson -Arguments @(
                    'ad', 'app', 'federated-credential', 'list', '--id', $app.appId, '--output', 'json'
                )
                foreach ($credential in $partialCredentials) {
                    if ($credential.name -ne $ficName -or $credential.issuer -ne $ficIssuer -or $credential.subject -ne $ficSubject) {
                        throw 'Unexpected partial federated credential.'
                    }
                    Invoke-AzJson -Arguments @(
                        'ad', 'app', 'federated-credential', 'delete',
                        '--id', $app.appId, '--federated-credential-id', $credential.name, '--output', 'json'
                    ) | Out-Null
                }
                Invoke-AzJson -Arguments @('ad', 'app', 'delete', '--id', $app.appId, '--output', 'json') | Out-Null
            } catch { $cleanupFailed = $true }
        }
        if ($cleanupFailed) {
            throw 'Identity bootstrap failed and partial-identity cleanup was incomplete; an authorized operator must inspect the exact named app.'
        }
        throw
    }

    [pscustomobject]@{
        ClientId = $app.appId
        ServicePrincipalObjectId = $servicePrincipal.id
        ResourceGroupScope = $expectedResourceGroup
        PullIdentityScope = $identityId
        FederatedCredentialSubject = $ficSubject
        Reminder = 'Enter only ClientId as workflow input; no client secret or certificate is created.'
    } | Format-List
    return
}

if (-not $ClientId) {
    throw 'ClientId is required for exact temporary-identity cleanup.'
}
$apps = Invoke-AzJson -Arguments @(
    'ad', 'app', 'list', '--filter', "appId eq '$ClientId'", '--output', 'json'
)
$servicePrincipals = Invoke-AzJson -Arguments @(
    'ad', 'sp', 'list', '--filter', "appId eq '$ClientId'", '--output', 'json'
)
if (@($apps).Count -gt 1 -or @($servicePrincipals).Count -gt 1) {
    throw 'Multiple Entra objects matched the temporary client ID; refusing cleanup.'
}
$app = @($apps | Where-Object { $_.appId -ieq $ClientId }) | Select-Object -First 1
$servicePrincipal = @($servicePrincipals | Where-Object { $_.appId -ieq $ClientId }) | Select-Object -First 1
if (-not $app -and -not $servicePrincipal) {
    Write-Output "Temporary spike identity '$appDisplayName' is already absent; cleanup is complete."
    return
}

$assignments = @()
if ($servicePrincipal) {
    $assignments = @(
        Invoke-AzJson -Arguments @(
            'role', 'assignment', 'list',
            '--assignee-object-id', $servicePrincipal.id,
            '--all', '--include-inherited',
            '--subscription', $subscriptionId,
            '--output', 'json'
        )
    )
}

$credentials = @()
if ($app) {
    $credentials = @(
        Invoke-AzJson -Arguments @(
            'ad', 'app', 'federated-credential', 'list', '--id', $ClientId, '--output', 'json'
        )
    )
}
Assert-SpikeIdentityCleanupState `
    -App $app `
    -ServicePrincipal $servicePrincipal `
    -Assignments $assignments `
    -FederatedCredentials $credentials `
    -ExpectedDisplayName $appDisplayName `
    -ExpectedResourceGroup $expectedResourceGroup `
    -ExpectedPullIdentity $identityId `
    -ExpectedCredentialName $ficName `
    -ExpectedIssuer $ficIssuer `
    -ExpectedSubject $ficSubject `
    -ExpectedAudience $ficAudience | Out-Null

if ($PSCmdlet.ShouldProcess("$appDisplayName ($ClientId)", 'Remove only verified issue 10 identity resources')) {
    foreach ($credential in $credentials) {
        Invoke-AzJson -Arguments @(
            'ad', 'app', 'federated-credential', 'delete',
            '--id', $ClientId, '--federated-credential-id', $credential.name, '--output', 'json'
        ) | Out-Null
    }
    foreach ($assignment in $assignments) {
        Invoke-AzJson -Arguments @(
            'role', 'assignment', 'delete',
            '--ids', $assignment.id,
            '--subscription', $subscriptionId,
            '--output', 'json'
        ) | Out-Null
    }
    if ($servicePrincipal) {
        Invoke-AzJson -Arguments @('ad', 'sp', 'delete', '--id', $ClientId, '--output', 'json') | Out-Null
    }
    if ($app) {
        Invoke-AzJson -Arguments @('ad', 'app', 'delete', '--id', $ClientId, '--output', 'json') | Out-Null
    }

    $remainingApps = Invoke-AzJson -Arguments @(
        'ad', 'app', 'list', '--filter', "appId eq '$ClientId'", '--output', 'json'
    )
    $remainingServicePrincipals = Invoke-AzJson -Arguments @(
        'ad', 'sp', 'list', '--filter', "appId eq '$ClientId'", '--output', 'json'
    )
    if (@($remainingApps | Where-Object { $_.appId -ieq $ClientId }).Count -gt 0 -or
        @($remainingServicePrincipals | Where-Object { $_.appId -ieq $ClientId }).Count -gt 0) {
        throw 'Temporary app or service principal remains after cleanup.'
    }
    Write-Output "Removed '$appDisplayName' and only its remaining verified spike-scoped grants."
}
