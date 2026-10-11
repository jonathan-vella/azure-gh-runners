# Offline tests for image/windows/hooks/job-started.ps1. Plain pwsh, no Pester, no network.
# Usage: pwsh -NoProfile -File tests/windows/job-started.tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hook = Join-Path $PSScriptRoot '../../image/windows/hooks/job-started.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
$pwsh = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ghr-hook-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$script:failures = [System.Collections.Generic.List[string]]::new()
$script:count = 0
$envNames = 'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_WORKFLOW_REF', 'GITHUB_EVENT_PATH',
'GITHUB_BASE_REF', 'GITHUB_HEAD_REF', 'GHR_POLICY_PATH'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function New-Policy {
    param([string]$Visibility = 'public', [string[]]$Events = @('workflow_dispatch', 'schedule', 'push'),
        [string[]]$Refs = @('refs/heads/main'), [string[]]$Workflows = @('example/service/.github/workflows/ci.yml@refs/heads/main'))
    return [ordered]@{
        repository       = 'example/service'
        visibility       = $Visibility
        allowedEvents    = $Events
        allowedRefs      = $Refs
        allowedWorkflows = $Workflows
    }
}

function New-Repository {
    param([string]$Name = 'example/service', [bool]$Private = $false, [bool]$Fork = $false)
    return [ordered]@{ full_name = $Name; private = $Private; fork = $Fork }
}

function New-Payload {
    param([int]$Number = 17, [string]$State = 'open', [bool]$Private = $false, $Base = $null, $Head = $null)
    if ($null -eq $Base) { $Base = New-Repository -Private $Private }
    if ($null -eq $Head) { $Head = New-Repository -Private $Private }
    return [ordered]@{
        number       = $Number
        repository   = New-Repository -Private $Private
        pull_request = [ordered]@{
            number = $Number
            state  = $State
            base   = [ordered]@{ ref = 'main'; repo = $Base }
            head   = [ordered]@{ ref = 'feature'; repo = $Head }
        }
    }
}

function Get-Json { param($Value) return ($Value | ConvertTo-Json -Depth 10 -Compress) }

# Runs the hook in a fresh process; $Overrides can set a variable to $null to leave it unset.
function Invoke-Hook {
    param($Policy = (New-Policy), $Payload = $null, [hashtable]$Overrides = @{}, $PolicyText = $null,
        $PayloadText = $null, [switch]$DotSource)
    $policyPath = Join-Path $work 'policy.json'
    $payloadPath = Join-Path $work 'event.json'
    if ($null -eq $PolicyText) { $PolicyText = Get-Json $Policy }
    [System.IO.File]::WriteAllText($policyPath, $PolicyText, $utf8)
    if ($null -eq $PayloadText -and $null -ne $Payload) { $PayloadText = Get-Json $Payload }
    if ($null -ne $PayloadText) { [System.IO.File]::WriteAllText($payloadPath, $PayloadText, $utf8) }
    $values = @{
        GITHUB_REPOSITORY   = 'example/service'
        GITHUB_EVENT_NAME   = 'workflow_dispatch'
        GITHUB_REF          = 'refs/heads/main'
        GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/heads/main'
        GHR_POLICY_PATH     = $policyPath
    }
    if ($null -ne $PayloadText) { $values['GITHUB_EVENT_PATH'] = $payloadPath }
    foreach ($key in $Overrides.Keys) { $values[$key] = $Overrides[$key] }
    foreach ($name in $envNames) {
        [System.Environment]::SetEnvironmentVariable($name, $values[$name])
    }
    if ($DotSource) {
        $output = & $pwsh -NoProfile -NonInteractive -Command ". '$hook'" 2>&1 | Out-String
    }
    else {
        $output = & $pwsh -NoProfile -NonInteractive -File $hook 2>&1 | Out-String
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output.Trim() }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:count++
    try {
        & $Body
        Write-Host "ok - $Name"
    }
    catch {
        $script:failures.Add($Name)
        Write-Host "not ok - $Name`n  $($_.Exception.Message)"
    }
}

function Assert-Accepted {
    param($Result)
    if ($Result.Code -ne 0 -or $Result.Output -ne 'Consumer policy accepted job.') {
        throw "expected acceptance, got exit $($Result.Code): $($Result.Output)"
    }
}

function Assert-Rejected {
    param($Result, [string]$Reason = '')
    if ($Result.Code -ne 1) { throw "expected exit 1, got $($Result.Code): $($Result.Output)" }
    if ($Result.Output -notlike '*::error::Consumer policy rejected job:*') { throw "missing rejection marker: $($Result.Output)" }
    if ($Reason -and $Result.Output -notlike "*$Reason*") { throw "expected reason '$Reason', got: $($Result.Output)" }
    if ($Result.Output -match 'SECRET_CANARY|at <ScriptBlock>|Exception') { throw "output leaks details: $($Result.Output)" }
}

$prPolicy = New-Policy -Events @('workflow_dispatch', 'pull_request')
$prEnv = @{
    GITHUB_EVENT_NAME   = 'pull_request'
    GITHUB_REF          = 'refs/pull/17/merge'
    GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/pull/17/merge'
    GITHUB_BASE_REF     = 'main'
    GITHUB_HEAD_REF     = 'feature'
}

function Invoke-PullRequest {
    param($Payload = (New-Payload), $Policy = $prPolicy, [hashtable]$Overrides = @{}, $PayloadText = $null)
    $merged = $prEnv.Clone()
    foreach ($key in $Overrides.Keys) { $merged[$key] = $Overrides[$key] }
    return Invoke-Hook -Policy $Policy -Payload $Payload -PayloadText $PayloadText -Overrides $merged
}

try {
    Test-Case 'accepts public dispatch, schedule and push on the default branch' {
        foreach ($name in 'workflow_dispatch', 'schedule', 'push') {
            Assert-Accepted (Invoke-Hook -Overrides @{ GITHUB_EVENT_NAME = $name })
        }
    }
    Test-Case 'works when the runner dot-sources the hook' {
        Assert-Accepted (Invoke-Hook -DotSource)
        Assert-Rejected (Invoke-Hook -DotSource -Overrides @{ GITHUB_REPOSITORY = 'other/service' })
    }
    Test-Case 'accepts the policy generated for the Windows smoke consumer' {
        $entry = (Get-Content -Raw (Join-Path $PSScriptRoot '../../infra/generated/windows-consumers.json') | ConvertFrom-Json)[0]
        $smoke = Get-Json $entry.policy
        $workflow = $entry.policy.allowedWorkflows[0]
        Assert-Accepted (Invoke-Hook -PolicyText $smoke -Overrides @{
                GITHUB_REPOSITORY = $entry.policy.repository; GITHUB_WORKFLOW_REF = $workflow })
    }
    Test-Case 'matches repositories case-insensitively but workflow files exactly' {
        Assert-Accepted (Invoke-Hook -Overrides @{
                GITHUB_REPOSITORY = 'Example/Service'; GITHUB_WORKFLOW_REF = 'Example/Service/.github/workflows/ci.yml@refs/heads/main' })
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/CI.yml@refs/heads/main' })
    }
    Test-Case 'rejects a push to a non-default branch' {
        Assert-Rejected (Invoke-Hook -Overrides @{
                GITHUB_EVENT_NAME = 'push'; GITHUB_REF = 'refs/heads/dev'
                GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/heads/dev' }) 'job ref outside policy'
    }
    Test-Case 'rejects a workflow ref that differs from the job ref' {
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/heads/other' })
    }
    Test-Case 'rejects a workflow that is not allowlisted' {
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/evil.yml@refs/heads/main' }) 'workflow outside policy'
    }
    Test-Case 'rejects another repository, event or workflow repository' {
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_REPOSITORY = 'other/service' }) 'repository outside policy'
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_EVENT_NAME = 'repository_dispatch' }) 'event outside policy'
        Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_WORKFLOW_REF = 'other/service/.github/workflows/ci.yml@refs/heads/main' })
    }
    Test-Case 'rejects each missing, empty or tainted context variable' {
        foreach ($name in 'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_WORKFLOW_REF') {
            Assert-Rejected (Invoke-Hook -Overrides @{ $name = $null }) 'missing or invalid job context'
            Assert-Rejected (Invoke-Hook -Overrides @{ $name = '' }) 'missing or invalid job context'
            Assert-Rejected (Invoke-Hook -Overrides @{ $name = "SECRET_CANARY value" })
        }
    }
    Test-Case 'rejects workflow_run and pull_request_target even if a policy lists them' {
        foreach ($name in 'workflow_run', 'pull_request_target') {
            Assert-Rejected (Invoke-Hook -Overrides @{ GITHUB_EVENT_NAME = $name })
            Assert-Rejected (Invoke-Hook -Policy (New-Policy -Events @($name)) -Overrides @{ GITHUB_EVENT_NAME = $name }) 'policy violates event floor'
        }
    }
    Test-Case 'rejects a missing, empty or malformed policy' {
        Assert-Rejected (Invoke-Hook -Overrides @{ GHR_POLICY_PATH = (Join-Path $work 'absent.json') }) 'missing or oversized consumer policy'
        Assert-Rejected (Invoke-Hook -PolicyText '') 'missing or oversized consumer policy'
        Assert-Rejected (Invoke-Hook -PolicyText '{not json')
        Assert-Rejected (Invoke-Hook -PolicyText '[]') 'invalid consumer policy fields'
        Assert-Rejected (Invoke-Hook -PolicyText (' ' * 70000)) 'missing or oversized consumer policy'
    }
    Test-Case 'rejects policies with duplicate keys, extra fields or bad shapes' {
        $base = Get-Json (New-Policy)
        Assert-Rejected (Invoke-Hook -PolicyText $base.Replace('"visibility":"public"', '"visibility":"public","visibility":"private"')) 'duplicate JSON key'
        Assert-Rejected (Invoke-Hook -PolicyText $base.Replace('"visibility"', '"extra":1,"visibility"')) 'invalid consumer policy fields'
        Assert-Rejected (Invoke-Hook -PolicyText $base.Replace('"public"', '"internal"')) 'invalid policy visibility'
        Assert-Rejected (Invoke-Hook -PolicyText $base.Replace('example/service"', 'bad repo"')) 'invalid policy repository'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Events @('push', 'push'))) 'duplicate policy allowlist entry'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Refs @('refs/heads/main', 'refs/heads/dev'))) 'public policy requires one default ref'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Refs @('refs/tags/v1'))) 'invalid branch ref'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Refs @('refs/heads/bad..ref'))) 'invalid branch ref'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Workflows @('other/repo/.github/workflows/ci.yml@refs/heads/main'))) 'policy workflow outside repository or refs'
        Assert-Rejected (Invoke-Hook -Policy (New-Policy -Workflows @('example/service/.github/workflows/ci.yml@refs/heads/dev'))) 'policy workflow outside repository or refs'
    }

    Test-Case 'accepts an open same-repository public pull request' {
        Assert-Accepted (Invoke-PullRequest)
    }
    Test-Case 'accepts an open same-repository private pull request' {
        $policy = New-Policy -Visibility 'private' -Events @('workflow_dispatch', 'pull_request') -Refs @('refs/heads/main', 'refs/heads/dev')
        Assert-Accepted (Invoke-PullRequest -Policy $policy -Payload (New-Payload -Private $true))
        Assert-Rejected (Invoke-PullRequest -Policy $policy -Payload (New-Payload -Private $false)) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a public policy when the payload says the repositories are private' {
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -Private $true)) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a fork pull request' {
        $fork = New-Repository -Name 'attacker/service' -Fork $true
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -Head $fork)) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a fork flagged head or base even when the name matches' {
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -Head (New-Repository -Fork $true))) 'pull request repository mismatch or fork'
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -Base (New-Repository -Fork $true))) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a same-named fork that is not flagged as a fork' {
        $lookalike = New-Repository -Name 'attacker/service'
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -Head $lookalike)) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a pull request whose head repository was deleted' {
        $text = (Get-Json (New-Payload)).Replace('"head":{"ref":"feature","repo":{"full_name":"example/service","private":false,"fork":false}}', '"head":{"ref":"feature","repo":null}')
        Assert-Rejected (Invoke-PullRequest -PayloadText $text) 'pull request repository mismatch or fork'
    }
    Test-Case 'rejects a closed pull request' {
        Assert-Rejected (Invoke-PullRequest -Payload (New-Payload -State 'closed')) 'pull request is not open'
    }
    Test-Case 'rejects a merge ref that does not match the payload number' {
        Assert-Rejected (Invoke-PullRequest -Overrides @{
                GITHUB_REF = 'refs/pull/18/merge'; GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/pull/18/merge' }) 'not its merge ref'
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_REF = 'refs/heads/feature' }) 'not its merge ref'
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/pull/17/head' }) 'not its merge ref'
    }
    Test-Case 'never infers a pull request from GITHUB_REF alone' {
        $payload = New-Payload -Head (New-Repository -Name 'attacker/service' -Fork $true)
        Assert-Rejected (Invoke-PullRequest -Payload $payload)
        Assert-Rejected (Invoke-Hook -Policy $prPolicy -Overrides @{
                GITHUB_EVENT_NAME = 'workflow_dispatch'; GITHUB_REF = 'refs/pull/17/merge'
                GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/ci.yml@refs/pull/17/merge' }) 'job ref outside policy'
    }
    Test-Case 'rejects a pull request workflow that is not allowlisted' {
        Assert-Rejected (Invoke-PullRequest -Overrides @{
                GITHUB_WORKFLOW_REF = 'example/service/.github/workflows/evil.yml@refs/pull/17/merge' }) 'workflow outside policy'
    }
    Test-Case 'rejects a pull request with a base branch outside the policy' {
        $payload = New-Payload
        $payload.pull_request.base.ref = 'dev'
        Assert-Rejected (Invoke-PullRequest -Payload $payload -Overrides @{ GITHUB_BASE_REF = 'dev' }) 'pull request base outside policy'
    }
    Test-Case 'rejects pull request branch context mismatches' {
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_BASE_REF = 'other' }) 'branch context mismatch'
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_HEAD_REF = 'other' }) 'branch context mismatch'
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_HEAD_REF = $null }) 'branch context mismatch'
    }
    Test-Case 'rejects a pull request number mismatch or non-integer number' {
        $payload = New-Payload
        $payload.pull_request.number = 18
        Assert-Rejected (Invoke-PullRequest -Payload $payload) 'invalid pull request number'
        Assert-Rejected (Invoke-PullRequest -PayloadText (Get-Json (New-Payload)).Replace('"number":17,"repository"', '"number":"17","repository"')) 'invalid pull request number'
    }
    Test-Case 'rejects a missing or invalid pull request payload' {
        Assert-Rejected (Invoke-Hook -Policy $prPolicy -Overrides $prEnv) 'missing pull request payload'
        Assert-Rejected (Invoke-PullRequest -Overrides @{ GITHUB_EVENT_PATH = (Join-Path $work 'absent.json') }) 'missing pull request payload'
        Assert-Rejected (Invoke-PullRequest -PayloadText '{not json')
        Assert-Rejected (Invoke-PullRequest -PayloadText '[]') 'invalid pull request payload'
        Assert-Rejected (Invoke-PullRequest -PayloadText '{"number":17}') 'pull request is not open'
        Assert-Rejected (Invoke-PullRequest -PayloadText ((Get-Json (New-Payload)).Replace('"state":"open"', '"state":"open","state":"closed"'))) 'duplicate JSON key'
    }
    Test-Case 'rejects pull_request when the policy does not list it' {
        Assert-Rejected (Invoke-PullRequest -Policy (New-Policy)) 'event outside policy'
    }
}
finally {
    foreach ($name in $envNames) { [System.Environment]::SetEnvironmentVariable($name, $null) }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "`n$($script:count - $script:failures.Count) of $($script:count) hook tests passed."
if ($script:failures.Count -gt 0) {
    Write-Host "Failed: $($script:failures -join '; ')"
    exit 1
}
exit 0
