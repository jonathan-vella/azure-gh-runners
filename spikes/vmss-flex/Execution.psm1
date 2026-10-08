Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1')
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1')
$script:oidcRefreshAfter = [DateTimeOffset]::UtcNow.AddMinutes(20)

function Update-SpikeOidcLogin {
    if ($env:GITHUB_ACTIONS -cne 'true' -or [DateTimeOffset]::UtcNow -lt $script:oidcRefreshAfter) { return }
    if ($env:GHR_SPIKE_AZURE_CLIENT_ID -cnotmatch '^[a-f0-9-]{36}$') { throw 'Original workflow OIDC client unavailable for bounded refresh.' }
    $uri = [uri]$env:ACTIONS_ID_TOKEN_REQUEST_URL
    if ($uri.Scheme -cne 'https' -or -not $uri.Host.EndsWith('.actions.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected GitHub OIDC issuer endpoint; no credential request.'
    }
    try {
        $separator = if ($uri.Query) { '&' } else { '?' }
        $response = Invoke-RestMethod -Uri ($uri.AbsoluteUri + $separator + 'audience=api%3A%2F%2FAzureADTokenExchange') `
            -Headers @{ Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" } -TimeoutSec 20 -MaximumRedirection 0
        if (-not $response.value -or $response.value.Length -gt 16384) { throw 'Invalid OIDC result.' }
    } catch { throw 'Bounded workflow OIDC refresh failed; credentials/provider output suppressed.' }
    $cli = Get-BoundedAzureCli
    $login = Invoke-BoundedProcess -FileName $cli.fileName -Arguments @($cli.prefix + @(
        'login', '--service-principal', '--username', $env:GHR_SPIKE_AZURE_CLIENT_ID,
        '--tenant', '30bac921-1547-4b1e-8445-72455da783f1', '--federated-token', $response.value,
        '--output', 'none', '--only-show-errors'
    )) -TimeoutSeconds 45
    $response = $null
    if ($login.exitCode -ne 0) { throw 'Original OIDC identity reauthentication failed; no identity substitution or widening.' }
    $script:oidcRefreshAfter = [DateTimeOffset]::UtcNow.AddMinutes(20)
}

function Assert-SpikeExecutionApproval {
    param([hashtable]$Approval, [hashtable]$Manifest, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    Assert-SpikeManifest $Manifest
    $keys = @('schemaVersion', 'reviewedHead', 'executionDirectionConfirmed', 'secretReadApproved',
        'canonicalUbuntuVersion', 'installationId', 'workflowRef', 'smokeCommitSha', 'smokeWorkflowBlobSha',
        'archiveSha256', 'adminSshPublicKey', 'appKeyFingerprint', 'pricing', 'quota')
    if ($Approval.Count -ne $keys.Count -or @($keys | Where-Object { -not $Approval.ContainsKey($_) }).Count -ne 0 -or
        $Approval.schemaVersion -ne 1 -or $Approval.reviewedHead -cne $Manifest.head -or
        $Approval.executionDirectionConfirmed -isnot [bool] -or $Approval.executionDirectionConfirmed -ne $true -or
        $Approval.secretReadApproved -isnot [bool] -or $Approval.secretReadApproved -ne $true -or
        $Approval.canonicalUbuntuVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        ($Approval.installationId -isnot [long] -and $Approval.installationId -isnot [int]) -or
        $Approval.installationId -le 0 -or $Approval.archiveSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Approval.appKeyFingerprint -cnotmatch '^[a-f0-9]{64}$' -or
        $Approval.smokeCommitSha -cnotmatch '^[a-f0-9]{40}$' -or $Approval.smokeWorkflowBlobSha -cnotmatch '^[a-f0-9]{40}$' -or
        $Approval.adminSshPublicKey -cnotmatch '^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,2}$' -or
        $Approval.adminSshPublicKey.Length -gt 4096 -or
        $Approval.workflowRef -cnotmatch '^jonathan-vella/ghr-smoke/\.github/workflows/[A-Za-z0-9_-]+\.ya?ml@refs/heads/main$') {
        throw 'Exact execution/secret authorization and immutable nonsecret inputs required.'
    }
    $pricing = $Approval.pricing
    $rates = @('b2sHourly', 'd2lsHourly', 'p4Hourly', 'natHourly', 'pipHourly', 'peHourly',
        'dnsZoneHourly', 'natGb', 'egressGb', 'peGb', 'dnsMillionQueries')
    if ($pricing -isnot [hashtable] -or $pricing.Count -ne ($rates.Count + 1) -or
        @($rates | Where-Object { -not $pricing.ContainsKey($_) }).Count -ne 0) {
        throw 'Complete refreshed USD pricing evidence is required.'
    }
    $stamp = [DateTimeOffset]::ParseExact($pricing.refreshedUtc, 'o', [cultureinfo]::InvariantCulture)
    if ($stamp -gt $Now -or $stamp -lt $Now.AddHours(-24)) { throw 'Pricing evidence is stale or in the future.' }
    foreach ($key in $rates) {
        if ($pricing[$key] -is [string] -or $pricing[$key] -is [bool] -or
            -not [double]::IsFinite([double]$pricing[$key]) -or [double]$pricing[$key] -le 0) {
            throw 'Every priced meter requires a finite positive USD rate.'
        }
    }
    $hourly = $pricing.b2sHourly + 2 * $pricing.d2lsHourly + 3 * $pricing.p4Hourly +
        $pricing.natHourly + $pricing.pipHourly + 2 * $pricing.peHourly + 2 * $pricing.dnsZoneHourly
    # Two sequential full runs each have a controller and one worker; guest byte/DNS quotas reset per VM.
    $variable = 2 * (8.589934592 * $pricing.natGb + 4.294967296 * ($pricing.egressGb + $pricing.peGb)) +
        ((4 * 14400 * 2 + 80) / 1000000) * $pricing.dnsMillionQueries
    if ($hourly -gt $Manifest.hourlyCeilingUsd -or $variable -gt 1.5 -or
        4 * $hourly + $Manifest.fixedReserveUsd -gt $Manifest.envelopeUsd) {
        throw 'Refreshed conservative pricing exceeds the original envelope; no deployment.'
    }
    $quota = $Approval.quota
    $headroom = @{ networkInterfaces = 3; premiumDisks = 2; natGateways = 1; publicIps = 1; privateEndpoints = 1; privateDnsZones = 1 }
    if ($quota -isnot [hashtable] -or $quota.Count -ne ($headroom.Count + 3) -or
        $quota.subscription -cne $Manifest.subscription -or $quota.location -cne 'swedencentral') {
        throw 'Exact region/subscription network and disk quota evidence required.'
    }
    $quotaStamp = [DateTimeOffset]::ParseExact($quota.refreshedUtc, 'o', [cultureinfo]::InvariantCulture)
    if ($quotaStamp -gt $Now -or $quotaStamp -lt $Now.AddHours(-24)) { throw 'Quota evidence is stale or in the future.' }
    foreach ($key in $headroom.Keys) {
        if (-not $quota.ContainsKey($key) -or
            ($quota[$key] -isnot [long] -and $quota[$key] -isnot [int]) -or $quota[$key] -lt $headroom[$key]) {
            throw 'NIC/disk/NAT/PIP/PE/DNS headroom insufficient; no resource creation.'
        }
    }
}

function Assert-SpikeCleanupPermission {
    param([hashtable]$Manifest)
    $permissions = Invoke-SpikeCommand @('rest', '--method', 'get', '--url',
        "https://management.azure.com/subscriptions/$($Manifest.subscription)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01",
        '--subscription', $Manifest.subscription, '-o', 'json', '--only-show-errors')
    foreach ($action in @('Microsoft.Resources/subscriptions/resourceGroups/write',
        'Microsoft.Resources/subscriptions/resourceGroups/delete', 'Microsoft.Resources/deployments/write')) {
        $allowed = $false
        foreach ($permission in $permissions.value) {
            if ($permission.ContainsKey('condition') -and $permission.condition) { continue }
            $include = @($permission.actions | Where-Object { $action -like $_ }).Count -gt 0
            $exclude = @($permission.notActions | Where-Object { $action -like $_ }).Count -gt 0
            if ($include -and -not $exclude) { $allowed = $true }
        }
        if (-not $allowed) { throw 'Existing identity lacks verifiable foundation/cleanup rights; never widen it.' }
    }
}

function Assert-SpikeKeyVaultAvailable {
    param([Parameter(Mandatory)][hashtable]$Manifest)
    $available = Invoke-SpikeCommand @('keyvault', 'check-name', '--subscription', $Manifest.subscription,
        '--name', $Manifest.keyVaultName, '--query', 'nameAvailable', '-o', 'json', '--only-show-errors')
    if ($available -isnot [bool] -or $available -ne $true) {
        throw 'Exact manifest-bound vault name unavailable; no substitution, purge or recovery.'
    }
}

function Get-SpikeFoundationDeploymentName {
    param([Parameter(Mandatory)][hashtable]$Manifest)
    if ($Manifest.runId -cnotmatch '^[a-f0-9]{32}$' -or $Manifest.runOrdinal -notin @(1, 2)) {
        throw 'Foundation deployment identity invalid.'
    }
    return "dep-ghr-spike60-$($Manifest.runId)-$($Manifest.runOrdinal)"
}

function New-SpikeWorkerParameters {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][hashtable]$Approval
    )
    return @{
        runId = $Manifest.runId; head = $Manifest.head; workerIndex = 1
        canonicalUbuntuVersion = $Approval.canonicalUbuntuVersion; adminSshPublicKey = $Approval.adminSshPublicKey
        flexScaleSetResourceId = 'not-set'
        workerSubnetResourceId = 'not-set'
        bootstrapCustomData = (New-SpikeCustomData worker $Manifest $Approval)
    }
}

function Test-SpikeControllerRoleAssignments {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$Principal,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResourceGroupAssignments,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SecretAssignments
    )
    if ($Principal -cnotmatch '^[a-f0-9-]{36}$') { throw 'Controller principal metadata invalid.' }
    $secretScope = Get-SpikeSecretScope $Manifest
    $approved = @('9980e02c-c2be-4d73-94e8-173b1dc7cf3c', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    $controllerRoles = @($ResourceGroupAssignments + $SecretAssignments |
        Where-Object principalId -IEQ $Principal | Sort-Object id -Unique)
    foreach ($assignment in $controllerRoles) {
        $id = ($assignment.roleDefinitionId -split '/')[-1]
        if (-not ($id -in $approved -and $assignment.scope -ieq $Manifest.scope) -and
            -not ($id -ceq '4633458b-17de-408a-b874-0445c86b69e6' -and $assignment.scope -ieq $secretScope)) {
            throw 'Controller has an unapproved role or broader scope; refusing execution.'
        }
    }
    foreach ($role in $approved) {
        if (@($controllerRoles | Where-Object { $_.scope -ieq $Manifest.scope -and
            $_.roleDefinitionId.EndsWith("/$role", [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { return $false }
    }
    if (@($controllerRoles | Where-Object { $_.scope -ieq $secretScope -and
        $_.roleDefinitionId.EndsWith('/4633458b-17de-408a-b874-0445c86b69e6', [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        return $false
    }
    return $true
}

function Invoke-SpikeCommand {
    param([string[]]$Arguments, [ValidateRange(1, 2700)][int]$Seconds = 30)
    Update-SpikeOidcLogin
    $cli = Get-BoundedAzureCli
    $result = Invoke-BoundedProcess -FileName $cli.fileName -Arguments @($cli.prefix + $Arguments) -TimeoutSeconds $Seconds
    if ($result.exitCode -ne 0) { throw 'Bounded spike Azure operation failed; provider output suppressed.' }
    try { return ConvertFrom-Json -InputObject $result.stdout -AsHashtable -ErrorAction Stop }
    catch { throw 'Spike Azure metadata was invalid; provider output suppressed.' }
}

function Assert-SpikePreflight {
    param([hashtable]$Manifest, [hashtable]$Approval)
    $sub = $Manifest.subscription
    $account = Invoke-SpikeCommand @('account', 'show', '--subscription', $sub, '-o', 'json', '--only-show-errors')
    if ($account.id -cne $sub -or $account.tenantId -cne $Manifest.tenant -or $account.name -cne 'shared') {
        throw 'Exact shared subscription and tenant required.'
    }
    if (Invoke-SpikeCommand @('group', 'exists', '--subscription', $sub, '-n', $Manifest.resourceGroup, '-o', 'json')) {
        throw 'Spike RG already exists; recover its original manifest, never overwrite it.'
    }
    $foundationDeploymentName = Get-SpikeFoundationDeploymentName $Manifest
    $prior = @(Invoke-SpikeCommand @('deployment', 'sub', 'list', '--subscription', $sub,
        '--query', "[?name=='$foundationDeploymentName'].name", '-o', 'json', '--only-show-errors') -Seconds 60)
    if ($prior.Count -ne 0) { throw 'This full-run ordinal already dispatched; retained history forbids replay after RG removal.' }
    $gh = (Get-Command gh -CommandType Application -ErrorAction Stop).Source
    $repository = Invoke-BoundedProcess -FileName $gh -Arguments @('api', 'repos/jonathan-vella/ghr-smoke') -TimeoutSeconds 20
    if ($repository.exitCode -ne 0) { throw 'Smoke repository metadata unavailable; no deployment.' }
    try { $metadata = $repository.stdout | ConvertFrom-Json -AsHashtable }
    catch { throw 'Smoke metadata invalid; provider output suppressed.' }
    if ($metadata.private -ne $false -or $metadata.visibility -cne 'public' -or $metadata.default_branch -cne 'main') {
        throw 'Approved public/default-main smoke contract changed; no deployment.'
    }
    $workflowPath = ($Approval.workflowRef -split '@')[0].Substring('jonathan-vella/ghr-smoke/'.Length)
    $branch = Invoke-BoundedProcess -FileName $gh -Arguments @('api',
        'repos/jonathan-vella/ghr-smoke/git/ref/heads/main') -TimeoutSeconds 20
    if ($branch.exitCode -ne 0) { throw 'Smoke default-branch commit unavailable; no deployment.' }
    try { $branchMetadata = $branch.stdout | ConvertFrom-Json -AsHashtable }
    catch { throw 'Smoke branch metadata invalid; provider output suppressed.' }
    Assert-SpikeSmokePins $Approval $branchMetadata $null
    $workflow = Invoke-BoundedProcess -FileName $gh -Arguments @('api',
        "repos/jonathan-vella/ghr-smoke/contents/${workflowPath}?ref=$($Approval.smokeCommitSha)") -TimeoutSeconds 20
    if ($workflow.exitCode -ne 0) { throw 'Reviewed smoke workflow absent/inaccessible; separate scope required.' }
    try { $file = $workflow.stdout | ConvertFrom-Json -AsHashtable }
    catch { throw 'Smoke workflow metadata invalid; provider output suppressed.' }
    Assert-SpikeSmokePins $Approval $branchMetadata $file
    Assert-SpikeCleanupPermission $Manifest
    Assert-SpikeKeyVaultAvailable $Manifest
    foreach ($provider in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault')) {
        $state = Invoke-SpikeCommand @('provider', 'show', '--subscription', $sub, '-n', $provider,
            '--query', 'registrationState', '-o', 'json', '--only-show-errors')
        if ($state -cne 'Registered') { throw 'Required provider not registered; no automatic registration.' }
    }
    $image = Invoke-SpikeCommand @('vm', 'image', 'show', '--subscription', $sub, '-l', 'swedencentral',
        '--urn', "Canonical:ubuntu-24_04-lts:server:$($Approval.canonicalUbuntuVersion)", '-o', 'json', '--only-show-errors')
    if ($image.name -cne $Approval.canonicalUbuntuVersion -or $image.hyperVGeneration -cne 'V2' -or
        $image.osDiskImage.operatingSystem -cne 'Linux') { throw 'Exact regional Gen2 Ubuntu image unavailable.' }
    $skus = @(Invoke-SpikeCommand @('vm', 'list-skus', '--subscription', $sub, '-l', 'swedencentral',
        '--resource-type', 'virtualMachines', '--all', '--query',
        "[?name=='Standard_B2s' || name=='Standard_D2ls_v5']", '-o', 'json', '--only-show-errors') -Seconds 60)
    $usage = @(Invoke-SpikeCommand @('vm', 'list-usage', '--subscription', $sub, '-l', 'swedencentral',
        '-o', 'json', '--only-show-errors'))
    foreach ($name in @('Standard_B2s', 'Standard_D2ls_v5')) {
        $sku = @($skus | Where-Object name -CEQ $name)
        if ($sku.Count -ne 1 -or $sku[0].restrictions.Count -ne 0) { throw 'Approved SKU unavailable or restricted.' }
        $required = if ($name -ceq 'Standard_B2s') { 2 } else { 4 }
        $quota = @($usage | Where-Object { $_.name.value -ieq $sku[0].family })
        if ($quota.Count -ne 1 -or $quota[0].currentValue + $required -gt $quota[0].limit) {
            throw 'Approved family quota insufficient; no substitution or quota request.'
        }
    }
    $regional = @($usage | Where-Object { $_.name.value -ieq 'cores' })
    if ($regional.Count -ne 1 -or $regional[0].currentValue + 6 -gt $regional[0].limit) {
        throw 'Regional six-vCPU ceiling has insufficient quota.'
    }
}

function Assert-SpikeSmokePins {
    param([hashtable]$Approval, [hashtable]$Branch, [AllowNull()][hashtable]$File)
    if ($Branch.ref -cne 'refs/heads/main' -or $Branch.object.type -cne 'commit' -or
        $Branch.object.sha -cne $Approval.smokeCommitSha) {
        throw 'Smoke main changed since review; no deployment.'
    }
    if ($null -ne $File) {
        $path = ($Approval.workflowRef -split '@')[0].Substring('jonathan-vella/ghr-smoke/'.Length)
        if ($File.type -cne 'file' -or $File.path -cne $path -or $File.sha -cne $Approval.smokeWorkflowBlobSha) {
            throw 'Smoke workflow content differs from reviewed blob; no deployment.'
        }
    }
}

function New-SpikeCustomData {
    param([ValidateSet('controller', 'worker')][string]$Mode, [hashtable]$Manifest,
        [hashtable]$Approval, [string]$Config = 'none')
    $script = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'guest-bootstrap.sh')).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $cloudInit = "#cloud-config`nwrite_files:`n  - path: /root/ghr-spike-bootstrap.sh`n    permissions: '0500'`n    encoding: b64`n    content: $encoded`nruncmd:`n  - [bash, /root/ghr-spike-bootstrap.sh, '$Mode', '$($Manifest.head)', '$($Approval.archiveSha256)', '$Config']`n"
    if ([Text.Encoding]::UTF8.GetByteCount($cloudInit) -gt 64000) { throw 'Cloud-init exceeds the reviewed guest-data bound.' }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudInit))
}

function Invoke-SpikeControllerCommand {
    param([hashtable]$Manifest, [string]$Script, [int]$Seconds = 180)
    $group = Invoke-SpikeCommand @('group', 'show', '--subscription', $Manifest.subscription,
        '-n', $Manifest.resourceGroup, '-o', 'json', '--only-show-errors')
    Assert-OwnedSpikeGroup $Manifest $group
    $result = Invoke-SpikeCommand @('vm', 'run-command', 'invoke', '--subscription', $Manifest.subscription,
        '-g', $Manifest.resourceGroup, '-n', 'vm-ghr-spike60-controller', '--command-id', 'RunShellScript',
        '--scripts', $Script, '-o', 'json', '--only-show-errors') -Seconds $Seconds
    $output = @($result.value | Where-Object code -Like '*/StdOut/*')
    if ($output.Count -ne 1 -or $output[0].message.Length -gt 2048) { throw 'Controller evidence unavailable.' }
    try { return $output[0].message | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Controller evidence was invalid; provider output suppressed.' }
}

function Invoke-SpikeControllerCleanup {
    param([hashtable]$Manifest)
    $script = @'
set -eu
timeout 180s systemctl stop ghr-spike60.service
if [ ! -f /var/lib/ghr-vmss/journal.json ]; then
  printf '%s\n' '{"result":"controller_never_started"}'
else
  timeout --signal=TERM --kill-after=10s 300s runuser --user controller -- \
    /opt/ghr-vmss/controller -cleanup-on-private-controller -controller-config /opt/ghr-vmss/controller.json
fi
'@
    $result = Invoke-SpikeControllerCommand $Manifest $script -Seconds 600
    if ($result.result -notin @('controller_cleanup_absence_verified', 'controller_never_started')) {
        throw 'Controller/GitHub cleanup remains unverified; exact RG cleanup is still mandatory.'
    }
}

function Save-SpikeControllerEvidence {
    param([hashtable]$Manifest, [string]$Path)
    $script = @'
set -eu
if [ -f /var/lib/ghr-vmss/journal.json ]; then
  journal=/var/lib/ghr-vmss/journal.json
else
  journal=/opt/ghr-vmss/controller.json
fi
result=controller_never_started
if [ -f /var/lib/ghr-vmss/outcome.json ]; then
  result=$(jq -er '.result' /var/lib/ghr-vmss/outcome.json)
fi
jq --arg result "$result" '{runId,head,startedUtc,attempts:(.attempts // 1),scaleSetId:(.scaleSetId // 0),result:$result,
  worker:(if .worker then .worker | {name,vmId,nicId,osDiskId,runnerId,jobRequestId,jobComplete,phase} else null end)}' "$journal"
'@
    $evidence = Invoke-SpikeControllerCommand $Manifest $script -Seconds 45
    if ($evidence.runId -cne $Manifest.runId -or $evidence.head -cne $Manifest.head -or
        $evidence.attempts -lt 1 -or $evidence.attempts -gt 2 -or
        [DateTimeOffset]::Parse($evidence.startedUtc) -ne [DateTimeOffset]::Parse($Manifest.startedUtc) -or
        $evidence.result -cnotmatch '^[a-z0-9_\n]+$') {
        throw 'Controller evidence does not match the immutable owner envelope.'
    }
    $evidence.keyVaultName = $Manifest.keyVaultName
    $evidence.keyVaultSecretScope = $Manifest.keyVaultSecretScope
    $evidence.keyVaultSoftDeleteRetentionInDays = $Manifest.keyVaultSoftDeleteRetentionInDays
    $evidence.keyVaultPurgeProtectionEnabled = $Manifest.keyVaultPurgeProtectionEnabled
    $evidence.appKeyFingerprint = $Manifest.appKeyFingerprint
    $evidence.ownerRevocationConfirmed = $Manifest.ownerRevocationConfirmed
    [IO.File]::WriteAllText($Path, ($evidence | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

function Invoke-SpikeExecution {
    param([hashtable]$Manifest, [string]$Path, [hashtable]$Approval)
    if ($env:GHR_SPIKE60_EXECUTION_ENABLED -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
        $env:GITHUB_RUN_ATTEMPT -cne '1' -or
        $env:GITHUB_REPOSITORY -cne 'jonathan-vella/azure-gh-runners' -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_SHA -cne $Manifest.head -or
        $env:GHR_SPIKE_ENVIRONMENT -cne 'platform-prod') {
        throw 'Deployment disabled: reviewed main-only protected workflow and exact direction required.'
    }
    Assert-SpikeExecutionApproval $Approval $Manifest
    if ($Manifest.attempts -ne 0 -or $Manifest.phase -ne 'active' -or
        [DateTimeOffset]::UtcNow.AddMinutes(75) -ge [DateTimeOffset]::Parse($Manifest.workDeadlineUtc)) {
        throw 'No resumed deployments or insufficient original work window.'
    }
    $key = [Environment]::GetEnvironmentVariable('GHR_SPIKE60_APP_PRIVATE_KEY')
    if (-not $key -or $key.Length -gt 16384 -or -not $key.Contains('PRIVATE KEY-----')) {
        throw 'Owner-supplied spike-only App key unavailable; never use the production key or retrieve it locally.'
    }
    $Manifest.appKeyFingerprint = $Approval.appKeyFingerprint
    Write-SpikeManifest -Manifest $Manifest -Path $Path
    Assert-SpikePreflight $Manifest $Approval
    $foundationDeploymentName = Get-SpikeFoundationDeploymentName $Manifest
    $config = @{
        runId = $Manifest.runId; head = $Manifest.head; startedUtc = $Manifest.startedUtc
        workDeadlineUtc = $Manifest.workDeadlineUtc; hardDeadlineUtc = $Manifest.hardDeadlineUtc
        foundationAttempts = 1; installationId = $Approval.installationId; runOrdinal = $Manifest.runOrdinal
        keyVaultName = $Manifest.keyVaultName
        secretVersion = ('0' * 32)
        templateSha256 = ('0' * 64)
        policy = @{
            repository = 'jonathan-vella/ghr-smoke'; visibility = 'public'; allowedEvents = @('workflow_dispatch')
            allowedRefs = @('refs/heads/main'); allowedWorkflows = @($Approval.workflowRef)
            workflowSha = $Approval.smokeCommitSha
        }
        workerParameters = New-SpikeWorkerParameters $Manifest $Approval
    }
    $configBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 12 -Compress)))
    $parameters = @{
        runId = @{ value = $Manifest.runId }; runOrdinal = @{ value = $Manifest.runOrdinal }
        head = @{ value = $Manifest.head }
        canonicalUbuntuVersion = @{ value = $Approval.canonicalUbuntuVersion }
        adminSshPublicKey = @{ value = $Approval.adminSshPublicKey }
        controllerBootstrapCustomData = @{ value = (New-SpikeCustomData controller $Manifest $Approval $configBase64) }
        githubAppPrivateKey = @{ value = $key }
    }
    $key = $null
    $parameterPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) "secure-$($Manifest.runId).json"
    try {
        Reserve-SpikeAttempt $Manifest $Path -Seconds 2700 -Workers 0
        $file = [IO.File]::Open($parameterPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            if (-not $IsWindows) {
                [IO.File]::SetUnixFileMode($parameterPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($parameters | ConvertTo-Json -Depth 12 -Compress))
            $file.Write($bytes); $file.Flush($true)
            [Array]::Clear($bytes)
        } finally { $file.Dispose() }
        $parameters = $null
        $deployment = Invoke-SpikeCommand @('deployment', 'sub', 'create', '--subscription', $Manifest.subscription,
            '--location', 'swedencentral', '--name', $foundationDeploymentName,
            '--template-file', (Join-Path $PSScriptRoot 'infra/subscription.bicep'),
            '--parameters', "@$parameterPath", '-o', 'json', '--only-show-errors') -Seconds 2700
    } finally {
        $parameters = $null
        if (Test-Path -LiteralPath $parameterPath) { Remove-Item -LiteralPath $parameterPath -Force }
        [Environment]::SetEnvironmentVariable('GHR_SPIKE60_APP_PRIVATE_KEY', $null)
    }
    $outputs = $deployment.properties.outputs
    $principal = $outputs.controllerPrincipalId.value
    $versionUri = $outputs.secretVersionUri.value
    $outputVaultName = $outputs.keyVaultName.value
    $outputSecretScope = $outputs.keyVaultSecretScope.value
    $flexId = $outputs.flexScaleSetResourceId.value
    $subnetId = $outputs.workerSubnetResourceId.value
    $expectedSecretScope = $Manifest.keyVaultSecretScope
    $versionUriPattern = '^https://' + [regex]::Escape($Manifest.keyVaultName) +
        '\.vault\.azure\.net/secrets/github-app-private-key/[a-f0-9]{32}$'
    if ($principal -cnotmatch '^[a-f0-9-]{36}$' -or $outputVaultName -cne $Manifest.keyVaultName -or
        $outputSecretScope -ine $expectedSecretScope -or
        $outputs.keyVaultSoftDeleteRetentionInDays.value -ne $Manifest.keyVaultSoftDeleteRetentionInDays -or
        $outputs.keyVaultPurgeProtectionEnabled.value -ne $Manifest.keyVaultPurgeProtectionEnabled -or
        $versionUri -cnotmatch $versionUriPattern -or
        $flexId -inotmatch "^$([regex]::Escape($Manifest.scope))/providers/Microsoft.Compute/virtualMachineScaleSets/[A-Za-z0-9_-]+$" -or
        $subnetId -inotmatch "^$([regex]::Escape($Manifest.scope))/providers/Microsoft.Network/virtualNetworks/[A-Za-z0-9_-]+/subnets/[A-Za-z0-9_-]+$") {
        throw 'Foundation credential metadata invalid; no controller start.'
    }
    $version = ($versionUri -split '/')[-1]
    $gateStop = [DateTimeOffset]::UtcNow.AddMinutes(20)
    $secretScope = Get-SpikeSecretScope $Manifest
    Write-Information -InformationAction Continue ("Owner-only exact role prerequisite: controller principal {0}; VM/Network Contributor at {1}; Key Vault Secrets User at {2}." -f $principal, $Manifest.scope, $secretScope)
    do {
        $rgRoles = @(Invoke-SpikeCommand @('role', 'assignment', 'list', '--subscription', $Manifest.subscription,
            '--scope', $Manifest.scope, '--all', '--include-inherited', '--fill-principal-name', 'false', '-o', 'json', '--only-show-errors'))
        $secretRoles = @(Invoke-SpikeCommand @('role', 'assignment', 'list', '--subscription', $Manifest.subscription,
            '--scope', $secretScope, '--all', '--include-inherited', '--fill-principal-name', 'false', '-o', 'json', '--only-show-errors'))
        if (Test-SpikeControllerRoleAssignments $Manifest $principal $rgRoles $secretRoles) { break }
        if ([DateTimeOffset]::UtcNow.AddSeconds(45) -ge $gateStop) { throw 'Owner-executed exact role prerequisites absent; no grant or widening attempted.' }
        Start-Sleep -Seconds 15
    } while ($true)
    Reserve-SpikeAttempt $Manifest $Path -Seconds 2700 -Workers 1
    $script = @'
set -eu
test "$(stat -c '%u:%a' /run/ghr-vmss/controller-ready)" = 0:444
jq --arg version '__VERSION__' --arg flex '__FLEX__' --arg subnet '__SUBNET__' \
  '.secretVersion=$version | .workerParameters.flexScaleSetResourceId=$flex | .workerParameters.workerSubnetResourceId=$subnet' \
  /opt/ghr-vmss/controller.json > /opt/ghr-vmss/controller-next.json
install -o root -g root -m 0444 /opt/ghr-vmss/controller-next.json /opt/ghr-vmss/controller.json
rm -f /opt/ghr-vmss/controller-next.json
systemctl start --no-block ghr-spike60.service
printf '%s\n' '{"result":"controller_start_requested"}'
'@
    $startResult = Invoke-SpikeControllerCommand $Manifest ($script.Replace('__VERSION__', $version).Replace('__FLEX__', $flexId).Replace('__SUBNET__', $subnetId))
    if ($startResult.result -cne 'controller_start_requested') { throw 'Controller start unverified.' }
    do {
        if ([DateTimeOffset]::UtcNow.AddMinutes(25) -ge [DateTimeOffset]::Parse($Manifest.workDeadlineUtc)) {
            throw 'Original work window ending; independent cleanup must take over.'
        }
        Start-Sleep -Seconds 30
        $status = Invoke-SpikeControllerCommand $Manifest @'
set -eu
state=$(systemctl is-active ghr-spike60.service || true)
case "$state" in
  active|activating|deactivating|inactive|failed) printf '{"state":"%s"}\n' "$state" ;;
  *) exit 1 ;;
esac
'@
    } while ($status.state -in @('active', 'activating', 'deactivating'))
    if ($status.state -cne 'inactive') { throw 'Controller lifecycle failed; acceptance remains unverified.' }
}

Export-ModuleMember -Function Assert-SpikeExecutionApproval, Invoke-SpikeExecution,
    Invoke-SpikeControllerCleanup, Invoke-SpikeCommand, Assert-SpikeCleanupPermission, Save-SpikeControllerEvidence
