$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Execution.psm1') -Force
function Reject([scriptblock]$Operation) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    if (-not $failed) { throw 'Unsafe execution input accepted.' }
}
$manifest = New-SpikeManifest -Head ('a' * 40)
if ($manifest.keyVaultName -cne ("kv-ghr60-" + $manifest.runId.Substring(0, 14) + $manifest.runOrdinal) -or
    $manifest.runOrdinal -ne 1 -or $manifest.keyVaultName.Length -ne 24) {
    throw 'Manifest vault name is not uniquely derived from its original run ID and ordinal.'
}
$originalRunId = 'a' * 32
$firstRun = New-SpikeManifest -Head ('a' * 40) -RunId $originalRunId -RunOrdinal 1
$secondRun = New-SpikeManifest -Head ('a' * 40) -RunId $originalRunId -RunOrdinal 2
if ($firstRun.runId -cne $secondRun.runId -or $firstRun.keyVaultName -ceq $secondRun.keyVaultName) {
    throw 'Complete run ordinals do not share the original envelope ID with distinct vault names.'
}
Reject { New-SpikeManifest -Head ('a' * 40) -RunId $originalRunId -RunOrdinal 3 }
$tamperedManifest = $manifest.Clone()
$tamperedManifest.keyVaultName = 'kv-ghr60-fffffffffffffff'
Reject { Assert-SpikeManifest $tamperedManifest }
$now = [DateTimeOffset]::UtcNow
$approval = @{
    schemaVersion = 1; reviewedHead = $manifest.head; executionDirectionConfirmed = $true; secretReadApproved = $true
    canonicalUbuntuVersion = '24.04.202609260'; installationId = 1
    workflowRef = 'jonathan-vella/ghr-smoke/.github/workflows/vmss-smoke.yml@refs/heads/main'
    smokeCommitSha = ('c' * 40); smokeWorkflowBlobSha = ('d' * 40)
    archiveSha256 = ('b' * 64); adminSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakefixture'
    appKeyFingerprint = [Convert]::ToBase64String([byte[]]::new(32))
    pricing = @{
        schemaVersion = 1; source = 'azure-retail-prices-api'; sourceUrl = 'https://prices.azure.com/api/retail/prices'
        retrievedUtc = $now.ToString('o'); currencyCode = 'USD'; region = 'swedencentral'
        b2sHourly = 0.0432; d2lsHourly = 0.091; p4MonthlyUsd = 5.8072
        natHourly = 0.045; natProcessedGb = 0.045; standardIpv4Hourly = 0.005
        privateEndpointHourly = 0.01; privateEndpointIngressGb = 0.01; privateEndpointEgressGb = 0.01
        internetEgressGb = 0.12; privateDnsZoneMonthly = 0.5; privateDnsQueriesPerMillion = 0.4
        keyVaultOperationsPer10k = 0.03
    }
    quota = @{
        subscription = $manifest.subscription; location = 'swedencentral'; refreshedUtc = $now.ToString('o')
        networkInterfaces = 3; premiumDisks = 2; natGateways = 1; publicIps = 1; privateEndpoints = 1; privateDnsZones = 1
    }
}
Assert-SpikeExecutionApproval $approval $manifest -Now $now
$approval.appKeyFingerprint = 'invalid'
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.appKeyFingerprint = [Convert]::ToBase64String([byte[]]::new(32))
$approval.secretReadApproved = $false
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.secretReadApproved = $true
$approval.canonicalUbuntuVersion = 'latest'
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.canonicalUbuntuVersion = '24.04.202609260'
$approval.pricing.natProcessedGb = 10
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.pricing.natProcessedGb = 0.045
$approval.pricing.retrievedUtc = $now.AddHours(-25).ToString('o')
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.pricing.retrievedUtc = $now.ToString('o')
$approval.unexpected = 'fake-input'
Reject { Assert-SpikeExecutionApproval $approval $manifest -Now $now }
$approval.Remove('unexpected')
$module = Get-Module Execution
& $module {
    $fixture = [Security.Cryptography.RSA]::Create(2048)
    $other = [Security.Cryptography.RSA]::Create(2048)
    try {
        $fingerprint = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($fixture.ExportSubjectPublicKeyInfo()))
        $manifest = @{ appKeyFingerprint = $fingerprint }
        $approval = @{ appKeyFingerprint = $fingerprint }
        Assert-SpikeAppKeyBinding $fixture.ExportRSAPrivateKeyPem() $manifest $approval
        Assert-SpikeAppKeyBinding $fixture.ExportPkcs8PrivateKeyPem() $manifest $approval
        foreach ($invalid in @(
            @{ pem = $fixture.ExportRSAPrivateKeyPem(); ledger = [Convert]::ToBase64String([byte[]]::new(32)); approval = $fingerprint },
            @{ pem = $fixture.ExportRSAPrivateKeyPem(); ledger = $fingerprint; approval = [Convert]::ToBase64String([byte[]]::new(32)) },
            @{ pem = $other.ExportRSAPrivateKeyPem(); ledger = $fingerprint; approval = $fingerprint },
            @{ pem = '-----BEGIN PRIVATE KEY-----sensitive-fixture-----END PRIVATE KEY-----'; ledger = $fingerprint; approval = $fingerprint }
        )) {
            $message = $null
            try { Assert-SpikeAppKeyBinding $invalid.pem @{ appKeyFingerprint = $invalid.ledger } @{ appKeyFingerprint = $invalid.approval } }
            catch { $message = $_.Exception.Message }
            if (-not $message -or $message -match 'BEGIN|sensitive-fixture' -or $message.Contains($fingerprint)) {
                throw 'Key-binding fixture accepted mismatch or exposed credential details.'
            }
        }
    } finally { $fixture.Dispose(); $other.Dispose() }
}
& $module {
    param($manifest, $approval)
    function script:New-SpikeCustomData { return 'Y2xvdWQtY29uZmln' }
    $generated = New-SpikeWorkerParameters $manifest $approval
    $goSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'parameters.go')
    $allowedBlock = [regex]::Match($goSource, 'allowed := \[\]string\{(?<keys>[^}]+)\}')
    if (-not $allowedBlock.Success) { throw 'Go worker parameter allowlist was not found.' }
    $goKeys = @([regex]::Matches($allowedBlock.Groups['keys'].Value, '"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $generatedKeys = @($generated.Keys | Sort-Object)
    if (Compare-Object $goKeys $generatedKeys -SyncWindow 0) {
        throw 'Generated controller worker parameters do not match the Go validator allowlist.'
    }
    $config = [ordered]@{
        runId = $manifest.runId; head = $manifest.head; runOrdinal = $manifest.runOrdinal
        workerParameters = $generated
    }
    $decoded = $config | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json -AsHashtable
    $jsonWorkerKeys = @($decoded.workerParameters.Keys | Sort-Object)
    if (@(Compare-Object $goKeys $jsonWorkerKeys -SyncWindow 0).Count -gt 0 -or
        $decoded.runOrdinal -ne $manifest.runOrdinal -or $jsonWorkerKeys -contains 'runOrdinal') {
        throw 'Serialized controller worker parameters do not match the Go validator contract.'
    }
} $manifest $approval

& $module {
    param($manifest)
    $script:nameAvailable = $false
    $script:checkedVaultNames = @()
    function script:Invoke-SpikeCommand {
        param([string[]]$Arguments)
        $script:checkedVaultNames += $Arguments[($Arguments.IndexOf('--name') + 1)]
        return $script:nameAvailable
    }
    if (Test-SpikeControllerRoleAssignments $manifest ('1' * 36) @() @()) {
        throw 'Missing exact role prerequisites were not rejected.'
    }
} $manifest
Reject { & $module { param($m) Assert-SpikeKeyVaultAvailable $m } $manifest }
& $module {
    param($manifest)
    if ($script:checkedVaultNames.Count -ne 1 -or $script:checkedVaultNames[0] -cne $manifest.keyVaultName) {
        throw 'Name availability check did not use the immutable manifest vault.'
    }
    $script:nameAvailable = $true
    Assert-SpikeKeyVaultAvailable $manifest
    $principal = '11111111-1111-1111-1111-111111111111'
    $secretScope = "$($manifest.scope)/providers/Microsoft.KeyVault/vaults/$($manifest.keyVaultName)/secrets/github-app-private-key"
    $rgAssignments = @(
        @{ id = 'vm'; principalId = $principal; scope = $manifest.scope
            roleDefinitionId = "$($manifest.scope)/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c" },
        @{ id = 'network'; principalId = $principal; scope = $manifest.scope
            roleDefinitionId = "$($manifest.scope)/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7" },
        @{ id = 'foreign'; principalId = ('2' * 36); scope = '/subscriptions/other'
            roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c' }
    )
    $secretAssignments = @(@{ id = 'secret'; principalId = $principal; scope = $secretScope
        roleDefinitionId = "$($manifest.scope)/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6" })
    if (-not (Test-SpikeControllerRoleAssignments $manifest $principal $rgAssignments $secretAssignments)) {
        throw 'Exact controller role allowlist was rejected.'
    }
    $wrongSecret = $secretAssignments[0].Clone()
    $wrongSecret.scope = "$($manifest.scope)/providers/Microsoft.KeyVault/vaults/kv-ghr60-fffffffffffffff/secrets/github-app-private-key"
    $rejected = $false
    try { Test-SpikeControllerRoleAssignments $manifest $principal $rgAssignments @($wrongSecret) }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Foreign run vault role scope was accepted.' }
    $broadRole = $rgAssignments[0].Clone()
    $broadRole.scope = '/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
    $rejected = $false
    try { Test-SpikeControllerRoleAssignments $manifest $principal @($broadRole, $rgAssignments[1]) $secretAssignments }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Broader controller grant was accepted.' }
} $manifest
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
$executionEnvironment = @(
    'GHR_SPIKE60_EXECUTION_ENABLED', 'GITHUB_ACTIONS', 'GITHUB_RUN_ATTEMPT',
    'GITHUB_REPOSITORY', 'GITHUB_REF', 'GITHUB_SHA', 'GHR_SPIKE_ENVIRONMENT',
    'GHR_SPIKE60_APP_PRIVATE_KEY', 'GHR_SPIKE_AZURE_CLIENT_ID'
)
$executionSaved = @{}
foreach ($name in $executionEnvironment) { $executionSaved[$name] = [Environment]::GetEnvironmentVariable($name) }
$executionPath = Join-Path ([IO.Path]::GetTempPath()) ("vmss60-dispatch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $executionPath | Out-Null
$dispatchManifest = $manifest.Clone()
try {
    $executionStart = [DateTimeOffset]::UtcNow
    $dispatchManifest.startedUtc = $executionStart.ToString('o')
    $dispatchManifest.workDeadlineUtc = $executionStart.AddHours(3).ToString('o')
    $dispatchManifest.hardDeadlineUtc = $executionStart.AddHours(4).ToString('o')
    $dispatchManifest.phase = 'active'
    $dispatchManifest.attempts = 0
    $env:GHR_SPIKE60_EXECUTION_ENABLED = 'true'
    $env:GITHUB_ACTIONS = 'true'
    $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GITHUB_REPOSITORY = 'jonathan-vella/azure-gh-runners'
    $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_SHA = $dispatchManifest.head
    $env:GHR_SPIKE_ENVIRONMENT = 'spike-vmss'
    $dispatchManifest.temporaryIdentityClientId = '11111111-1111-1111-1111-111111111111'
    $env:GHR_SPIKE_AZURE_CLIENT_ID = $dispatchManifest.temporaryIdentityClientId
    $dispatchFixture = [Security.Cryptography.RSA]::Create(2048)
    $env:GHR_SPIKE60_APP_PRIVATE_KEY = $dispatchFixture.ExportRSAPrivateKeyPem()
    $dispatchManifest.appKeyFingerprint = [Convert]::ToBase64String(
        [Security.Cryptography.SHA256]::HashData($dispatchFixture.ExportSubjectPublicKeyInfo()))
    $approval.appKeyFingerprint = $dispatchManifest.appKeyFingerprint
    $dispatchFixture.Dispose()
    & $module {
        param($manifest, $approval, $directory)
        function script:Assert-SpikeExecutionApproval {}
        function script:Write-SpikeManifest {}
        function script:Assert-SpikePreflight {}
        function script:New-SpikeCustomData { return 'Y2xvdWQtY29uZmln' }
        function script:Reserve-SpikeAttempt {}
        function script:Invoke-SpikeCommand {
            param([string[]]$Arguments, [int]$Seconds)
            $script:dispatchedFoundationName = $Arguments[($Arguments.IndexOf('--name') + 1)]
            throw 'execution-dispatch-captured'
        }
        $path = Join-Path $directory 'manifest.json'
        $script:executionSourceEnabled = $true
        try { Invoke-SpikeExecution $manifest $path $approval }
        catch {
            if ($_.Exception.Message -cne 'execution-dispatch-captured') { throw }
        } finally { $script:executionSourceEnabled = $false }
        $expected = Get-SpikeFoundationDeploymentName $manifest
        if ($script:dispatchedFoundationName -cne $expected) {
            throw 'Execution dispatch did not use the deterministic ordinal deployment name.'
        }
    } $dispatchManifest $approval $executionPath
} finally {
    foreach ($name in $executionEnvironment) { [Environment]::SetEnvironmentVariable($name, $executionSaved[$name]) }
    Remove-Item -LiteralPath $executionPath -Recurse -Force
}

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
& {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Supervisor.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Supervisor failed to parse.' }
    $cleanupTry = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
        $node.Finally.Extent.Text -like '*Remove-OwnedSpike*'
    }, $true)
    if (-not $cleanupTry) { throw 'Supervisor cleanup finally missing.' }
    $cleanupReceipt = @{ called = $false }
    function Invoke-SpikeCommand { throw 'synthetic-supervisor-observation-failed' }
    function Remove-OwnedSpike { param($Manifest, $Path) $cleanupReceipt.called = $true }
    $stop = [DateTimeOffset]::UtcNow.AddMinutes(1)
    $manifest = @{ subscription = 'fixture'; resourceGroup = 'fixture' }
    $ManifestPath = 'fixture'
    try { & ([scriptblock]::Create($cleanupTry.Extent.Text)) }
    catch {
        if ($_.Exception.Message -cne 'synthetic-supervisor-observation-failed') { throw }
    }
    if (-not $cleanupReceipt.called) { throw 'Supervisor observation failure skipped independent cleanup.' }
}
Write-Output 'Execution/secret/cost gates, permission exclusions and disabled entrypoint passed offline.'
