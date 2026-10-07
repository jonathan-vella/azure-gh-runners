$ErrorActionPreference = 'Stop'
$observer = Join-Path $PSScriptRoot '..\Observe-JitLabelScale.ps1'
. $observer -DeploymentRunId 123456

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action } catch { return }
    throw $Message
}

$nonce = 'testnonce'
$now = [datetime]::UtcNow.ToString('o')
$script:MockJobState = '{"tags":{"spike-id":"10","spike-name":"jit-runner-labels","spike-deployment-run-id":"123456"}}'
$script:CommandRunner = {
    param($Command, $Arguments, $TimeoutSeconds)
    if ($Command -eq 'az' -and $Arguments -contains 'show') {
        return $script:MockJobState
    }
    throw "Unexpected mocked command: $Command"
}

$timeoutStart = [datetime]::UtcNow
try {
    Invoke-BoundedNativeCommand `
        -Command (Join-Path $PSHOME 'pwsh.exe') `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') `
        -TimeoutSeconds 1
    throw 'A hung external process unexpectedly completed without timing out.'
} catch {
    if ($_.Exception.Message -notmatch "exceeded its 1-second timeout") {
        throw
    }
}
Assert-True -Condition (([datetime]::UtcNow - $timeoutStart).TotalSeconds -lt 5) `
    -Message 'Bounded command timeout took longer than the permitted kill grace.'

$script:commandDeadline = [datetime]::UtcNow.AddSeconds(2)
$script:ObservedTimeout = 0
$script:CommandRunner = {
    param($Command, $Arguments, $TimeoutSeconds)
    $script:ObservedTimeout = $TimeoutSeconds
    return '{}'
}
Invoke-BoundedCommand -Command 'gh' -Arguments @('api', 'test') -TimeoutSeconds 15 | Out-Null
Assert-True -Condition ($script:ObservedTimeout -le 2) `
    -Message 'A subprocess timeout must not exceed the active observation deadline.'
$script:commandDeadline = $null
$script:CommandRunner = {
    param($Command, $Arguments, $TimeoutSeconds)
    if ($Command -eq 'az' -and $Arguments -contains 'show') {
        return $script:MockJobState
    }
    throw "Unexpected mocked command: $Command"
}

function Invoke-GhJson {
    param([string[]]$Arguments)
    return @(
        [pscustomobject]@{
            databaseId = 1
            createdAt = $now
            headBranch = 'main'
            displayTitle = "Spike 10 label match - $nonce"
        },
        [pscustomobject]@{
            databaseId = 2
            createdAt = $now
            headBranch = 'main'
            displayTitle = 'Spike 10 label match - someone-elses-nonce'
        }
    )
}

$selected = Get-WorkflowRun -Workflow $matchWorkflow -NotBeforeUtc ([datetime]::UtcNow.AddMinutes(-1)) -Nonce $nonce
Assert-True -Condition ($selected.databaseId -eq 1) -Message 'Run lookup must select only the nonce-correlated run.'

Assert-NoWakeJob -Jobs ([pscustomobject]@{
    jobs = @([pscustomobject]@{
        name = 'should-remain-queued'
        labels = @('self-hosted')
        status = 'queued'
        runner_name = $null
    })
})

Assert-Throws -Action {
    Assert-NoWakeJob -Jobs ([pscustomobject]@{
        jobs = @([pscustomobject]@{
            name = 'should-remain-queued'
            labels = @('self-hosted', 'extra')
            status = 'queued'
            runner_name = $null
        })
    })
} -Message 'Negative-control validation must reject extra runner labels.'

Assert-Throws -Action {
    Assert-NoWakeJob -Jobs ([pscustomobject]@{ jobs = @() })
} -Message 'Negative-control validation must reject a missing job.'

Assert-OwnedJob
$script:MockJobState = '{"tags":{"spike-id":"10","spike-name":"jit-runner-labels","spike-deployment-run-id":"654321"}}'
Assert-Throws -Action { Assert-OwnedJob } -Message 'Cleanup must refuse a job with another deployment run marker.'

Write-Output 'Observer mocked assertions passed.'
