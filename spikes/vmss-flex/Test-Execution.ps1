$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Execution.psm1') -Force
function Reject([scriptblock]$Operation) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    if (-not $failed) { throw 'Unsafe execution input accepted.' }
}
$manifest = New-SpikeManifest -Head ('a' * 40)
$now = [DateTimeOffset]::UtcNow
$approval = @{
    schemaVersion = 1; reviewedHead = $manifest.head; executionDirectionConfirmed = $true; secretReadApproved = $true
    canonicalUbuntuVersion = '24.04.202609260'; installationId = 1
    workflowRef = 'jonathan-vella/ghr-smoke/.github/workflows/vmss-smoke.yml@refs/heads/main'
    smokeCommitSha = ('c' * 40); smokeWorkflowBlobSha = ('d' * 40)
    archiveSha256 = ('b' * 64); adminSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakefixture'
    pricing = @{
        refreshedUtc = $now.ToString('o'); b2sHourly = 0.0432; d2lsHourly = 0.091; p4Hourly = 0.008
        natHourly = 0.06; pipHourly = 0.01; peHourly = 0.02; dnsZoneHourly = 0.001
        natGb = 0.06; egressGb = 0.12; peGb = 0.02; dnsMillionQueries = 0.4
    }
    quota = @{
        subscription = $manifest.subscription; location = 'swedencentral'; refreshedUtc = $now.ToString('o')
        networkInterfaces = 3; premiumDisks = 2; natGateways = 1; publicIps = 1; privateEndpoints = 1; privateDnsZones = 1
    }
}
Assert-SpikeExecutionApproval $approval $manifest -Now $now
$approval.secretReadApproved = $false
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.secretReadApproved = $true
$approval.canonicalUbuntuVersion = 'latest'
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.canonicalUbuntuVersion = '24.04.202609260'
$approval.pricing.natGb = 10
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.pricing.natGb = 0.06
$approval.pricing.refreshedUtc = $now.AddHours(-25).ToString('o')
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.pricing.refreshedUtc = $now.ToString('o')
$approval.unexpected = 'fake-input'
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.Remove('unexpected')
$module = Get-Module Execution
& $module {
    param($approval)
    $branch = @{ ref = 'refs/heads/main'; object = @{ type = 'commit'; sha = $approval.smokeCommitSha } }
    $file = @{ type = 'file'; path = '.github/workflows/vmss-smoke.yml'; sha = $approval.smokeWorkflowBlobSha }
    Assert-SpikeSmokePins $approval $branch $file
    $branch.object.sha = 'e' * 40
    $rejected = $false
    try { Assert-SpikeSmokePins $approval $branch $file } catch { $rejected = $true }
    if (-not $rejected) { throw 'Mutation of smoke main after approval accepted.' }
    $branch.object.sha = $approval.smokeCommitSha
    $file.sha = 'e' * 40
    $rejected = $false
    try { Assert-SpikeSmokePins $approval $branch $file } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unreviewed workflow blob accepted.' }
} $approval
& $module {
    $script:permissionFixture = @{ value = @(@{ actions = @('*'); notActions = @(); condition = $null }) }
    function script:Invoke-SpikeCommand { return $script:permissionFixture }
}
Assert-SpikeCleanupPermission $manifest
& $module { $script:permissionFixture.value[0].notActions = @('Microsoft.Resources/subscriptions/resourceGroups/delete') }
Reject { Assert-SpikeCleanupPermission $manifest }
& $module {
    $script:permissionFixture.value[0].notActions = @()
    $script:permissionFixture.value[0].condition = 'unverified-condition'
}
Reject { Assert-SpikeCleanupPermission $manifest }
$oidcNames = @('GITHUB_ACTIONS', 'GHR_SPIKE_AZURE_CLIENT_ID', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')
$oidcSaved = @{}
foreach ($name in $oidcNames) { $oidcSaved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:GITHUB_ACTIONS = 'true'
    $env:GHR_SPIKE_AZURE_CLIENT_ID = '11111111-1111-1111-1111-111111111111'
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://fixture.actions.githubusercontent.com/token?fixture=1'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'fake-oidc-request'
    & $module {
        $script:oidcRefreshAfter = [DateTimeOffset]::UtcNow.AddSeconds(-1)
        function script:Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
            if ($Headers.Authorization -cne 'Bearer fake-oidc-request' -or $TimeoutSec -ne 20 -or
                $MaximumRedirection -ne 0 -or $Uri -notlike '*audience=api%3A%2F%2FAzureADTokenExchange') {
                throw 'OIDC request did not preserve bounded issuer/header/audience contract.'
            }
            return @{ value = 'fake-oidc-response' }
        }
        function script:Get-BoundedAzureCli { return @{ fileName = 'fake-cli'; prefix = @() } }
        function script:Invoke-BoundedProcess {
            param($FileName, $Arguments, $TimeoutSeconds)
            if ($FileName -cne 'fake-cli' -or $TimeoutSeconds -ne 45 -or
                $Arguments[0] -cne 'login' -or $Arguments -notcontains 'fake-oidc-response' -or
                $Arguments -notcontains '11111111-1111-1111-1111-111111111111') {
                throw 'OIDC refresh changed identity or process bound.'
            }
            return @{ exitCode = 0 }
        }
        Update-SpikeOidcLogin
        if ($script:oidcRefreshAfter -le [DateTimeOffset]::UtcNow) { throw 'OIDC refresh deadline not advanced.' }
    }
} finally {
    foreach ($name in $oidcNames) { [Environment]::SetEnvironmentVariable($name, $oidcSaved[$name]) }
}
$saved = $env:GHR_SPIKE60_EXECUTION_ENABLED
try {
    $env:GHR_SPIKE60_EXECUTION_ENABLED = 'false'
    & $module {
        function script:Invoke-SpikeCommand { throw 'Offline test attempted an Azure call.' }
    }
    $message = $null
    try { Invoke-SpikeExecution $manifest 'unused' $approval } catch { $message = $_.Exception.Message }
    if ($message -notlike 'Deployment disabled:*') { throw 'Disabled gate reached cloud/key processing.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("vmss60-disabled-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        Start-SpikeClock $manifest (Join-Path $directory 'manifest.json')
        $approval | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $directory 'approval.json')
        $runFailure = $null
        try {
            & (Join-Path $PSScriptRoot 'Run.ps1') -Action Execute `
                -ManifestPath (Join-Path $directory 'manifest.json') -ApprovalPath (Join-Path $directory 'approval.json') `
                -ConfirmCoordinatorExecutionDirection
        } catch { $runFailure = $_.Exception.Message }
        if ($runFailure -notlike 'Deployment disabled:*' -or $manifest.attempts -ne 0) {
            throw 'Disabled entrypoint reached cleanup/cloud work or reserved an invocation.'
        }
    } finally { Remove-Item -LiteralPath $directory -Recurse -Force }
} finally { $env:GHR_SPIKE60_EXECUTION_ENABLED = $saved }
Write-Output 'Execution/secret/cost gates, permission exclusions and disabled entrypoint passed offline.'
