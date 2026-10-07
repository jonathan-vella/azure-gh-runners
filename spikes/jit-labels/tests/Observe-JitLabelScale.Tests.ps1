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

function az {
    $global:LASTEXITCODE = 0
    return '{"tags":{"spike-id":"10","spike-name":"jit-runner-labels","spike-deployment-run-id":"123456"}}'
}
Assert-OwnedJob
$global:LASTEXITCODE = 0
function az {
    $global:LASTEXITCODE = 0
    return '{"tags":{"spike-id":"10","spike-name":"jit-runner-labels","spike-deployment-run-id":"654321"}}'
}
Assert-Throws -Action { Assert-OwnedJob } -Message 'Cleanup must refuse a job with another deployment run marker.'

Write-Output 'Observer mocked assertions passed.'
