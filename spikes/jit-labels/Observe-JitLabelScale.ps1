param(
    [string]$ResourceGroup = 'rg-ghrunners-spike10-swc',
    [string]$JobName = 'caj-ghr-spike10-jit-labels',
    [string]$Owner = 'jonathan-vella',
    [string]$Repository = 'ghr-smoke',
    [string]$CustomLabel = 'ghr-smoke-jit-label-spike',
    [int]$MatchTimeoutSeconds = 300,
    [int]$NoWakeObservationSeconds = 120
)

$ErrorActionPreference = 'Stop'
$fullRepository = "$Owner/$Repository"
$matchWorkflow = 'jit-label-match.yml'
$noWakeWorkflow = 'jit-self-hosted-only.yml'
$script:matchRunId = $null
$script:noWakeRunId = $null
$script:runnerToClean = $null
$script:baselineExecutionNames = @()
$script:baselineExecutionsCaptured = $false

function Invoke-GhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI command failed: gh $($Arguments -join ' ')"
    }
    if ([string]::IsNullOrWhiteSpace(($output -join ''))) {
        return $null
    }
    return ($output -join "`n") | ConvertFrom-Json
}

function Get-Executions {
    $output = & az containerapp job execution list `
        --name $JobName `
        --resource-group $ResourceGroup `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to list executions for the named issue 10 ACA job.'
    }
    return @($output | ConvertFrom-Json)
}

function Get-WorkflowRun {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][datetime]$NotBeforeUtc
    )

    $runs = Invoke-GhJson -Arguments @(
        'run', 'list', '--repo', $fullRepository, '--workflow', $Workflow,
        '--event', 'workflow_dispatch', '--limit', '20',
        '--json', 'databaseId,createdAt,status,conclusion,headBranch'
    )
    return $runs |
        Where-Object {
            $_.headBranch -eq 'main' -and
            [datetime]::Parse($_.createdAt).ToUniversalTime() -ge $NotBeforeUtc
        } |
        Sort-Object { [datetime]::Parse($_.createdAt) } -Descending |
        Select-Object -First 1
}

function Start-Workflow {
    param([Parameter(Mandatory)][string]$Workflow)

    $startedAt = [datetime]::UtcNow.AddSeconds(-3)
    & gh workflow run $Workflow --repo $fullRepository --ref main
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to dispatch $Workflow in $fullRepository."
    }

    $deadline = [datetime]::UtcNow.AddSeconds(60)
    do {
        Start-Sleep -Seconds 3
        $run = Get-WorkflowRun -Workflow $Workflow -NotBeforeUtc $startedAt
        if ($run) {
            return $run
        }
    } while ([datetime]::UtcNow -lt $deadline)

    throw "The dispatched $Workflow run did not appear in GitHub Actions."
}

function Get-RunJobs {
    param([Parameter(Mandatory)][long]$RunId)
    return Invoke-GhJson -Arguments @(
        'api', "repos/$fullRepository/actions/runs/$RunId/jobs?per_page=100"
    )
}

function Get-RunnerByName {
    param([Parameter(Mandatory)][string]$Name)
    $encodedName = [uri]::EscapeDataString($Name)
    $response = Invoke-GhJson -Arguments @(
        'api', "repos/$fullRepository/actions/runners?name=$encodedName&per_page=100"
    )
    return @($response.runners | Where-Object { $_.name -eq $Name })
}

function Cancel-RunIfActive {
    param([long]$RunId)

    if (-not $RunId) {
        return
    }
    $run = Invoke-GhJson -Arguments @('run', 'view', "$RunId", '--repo', $fullRepository, '--json', 'status')
    if ($run.status -ne 'completed') {
        & gh run cancel $RunId --repo $fullRepository
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to cancel queued/active smoke workflow run $RunId."
        }
    }
}

function Remove-TestRunnerIfPresent {
    param([Parameter(Mandatory)][string]$Name)

    $runners = Get-RunnerByName -Name $Name
    foreach ($runner in $runners) {
        Invoke-GhJson -Arguments @(
            'api', '--method', 'DELETE',
            "repos/$fullRepository/actions/runners/$($runner.id)"
        ) | Out-Null
    }
    if ((Get-RunnerByName -Name $Name).Count -ne 0) {
        throw "Test runner '$Name' remains registered after cleanup."
    }
}

function Stop-NewExecutions {
    if (-not $script:baselineExecutionsCaptured) {
        return
    }

    $subscriptionId = & az account show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw 'Unable to identify the Azure subscription for scoped test-execution cleanup.'
    }

    foreach ($execution in (Get-Executions)) {
        if ($execution.name -in $script:baselineExecutionNames -or $execution.properties.status -ne 'Running') {
            continue
        }

        $escapedName = [uri]::EscapeDataString($execution.name)
        $resourceId = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/jobs/$JobName/executions/$escapedName/stop?api-version=2026-07-01"
        & az rest --method post --url $resourceId --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to stop the unexpected issue 10 execution '$($execution.name)'."
        }
        Write-Host "Stopped unexpected issue 10 execution: $($execution.name)"
    }
}

try {
    $initialRunners = Invoke-GhJson -Arguments @(
        'api', "repos/$fullRepository/actions/runners?per_page=100"
    )
    if (@($initialRunners.runners).Count -ne 0) {
        throw 'The smoke repository must have no registered runners before this exclusive label-matching test.'
    }

    $beforeMatch = @(Get-Executions | ForEach-Object { $_.name })
    $script:baselineExecutionNames = $beforeMatch
    $script:baselineExecutionsCaptured = $true
    $matchRun = Start-Workflow -Workflow $matchWorkflow
    $script:matchRunId = [long]$matchRun.databaseId
    Write-Host "Matched-label test run: $($script:matchRunId)"

    $deadline = [datetime]::UtcNow.AddSeconds($MatchTimeoutSeconds)
    $observedLabels = @()
    $runnerName = $null
    do {
        $runJobs = Get-RunJobs -RunId $script:matchRunId
        $job = @($runJobs.jobs | Where-Object { $_.name -eq 'verify-label-match' }) | Select-Object -First 1
        if ($job) {
            if (-not (@($job.labels) | Where-Object { $_ -ieq $CustomLabel })) {
                throw "The dispatched matching workflow did not request the expected custom-only label '$CustomLabel'."
            }
            if ($job.runner_name) {
                $runnerName = $job.runner_name
                $registered = Get-RunnerByName -Name $runnerName
                if ($registered.Count -eq 1) {
                    $script:runnerToClean = $runnerName
                    $observedLabels = @($registered[0].labels | ForEach-Object { $_.name })
                    Write-Host "Observed JIT runner '$runnerName' labels: $($observedLabels -join ', ')"
                }
            }
        }

        $runState = Invoke-GhJson -Arguments @(
            'run', 'view', "$($script:matchRunId)", '--repo', $fullRepository,
            '--json', 'status,conclusion'
        )
        if ($runState.status -eq 'completed') {
            break
        }
        Start-Sleep -Seconds 5
    } while ([datetime]::UtcNow -lt $deadline)

    if ($runState.status -ne 'completed' -or $runState.conclusion -ne 'success') {
        throw "Custom-label workflow did not succeed before the $MatchTimeoutSeconds-second deadline."
    }
    if (-not $runnerName -or -not ($observedLabels | Where-Object { $_ -ieq $CustomLabel })) {
        throw 'The actual registered JIT runner label set was not observed while the matching job was active.'
    }
    if (-not ($observedLabels | Where-Object { $_ -ieq 'self-hosted' })) {
        Write-Host 'Observed JIT registration did not include self-hosted.'
    } else {
        Write-Host 'Observed JIT registration includes self-hosted.'
    }

    $afterMatch = @(Get-Executions)
    $newMatchExecutions = @($afterMatch | Where-Object { $_.name -notin $beforeMatch })
    if ($newMatchExecutions.Count -ne 1 -or $newMatchExecutions[0].properties.status -ne 'Succeeded') {
        throw 'The matching workflow did not produce exactly one successful ACA job execution.'
    }
    Write-Host "Matched-label ACA execution succeeded: $($newMatchExecutions[0].name)"

    $runnerRemovalDeadline = [datetime]::UtcNow.AddSeconds(30)
    $remainingRunners = Get-RunnerByName -Name $runnerName
    while ($remainingRunners.Count -gt 0 -and [datetime]::UtcNow -lt $runnerRemovalDeadline) {
        Start-Sleep -Seconds 3
        $remainingRunners = Get-RunnerByName -Name $runnerName
    }
    $automaticRemovalSucceeded = $remainingRunners.Count -eq 0
    if (-not $automaticRemovalSucceeded) {
        Remove-TestRunnerIfPresent -Name $runnerName
        $script:runnerToClean = $null
        throw "The ephemeral runner did not deregister itself; explicit cleanup removed it."
    }
    $script:runnerToClean = $null
    Write-Host 'Ephemeral runner registration was removed automatically.'

    $beforeNoWake = @(Get-Executions | ForEach-Object { $_.name })
    $noWakeRun = Start-Workflow -Workflow $noWakeWorkflow
    $script:noWakeRunId = [long]$noWakeRun.databaseId
    Write-Host "Self-hosted-only no-wake test run: $($script:noWakeRunId)"

    $noWakeDeadline = [datetime]::UtcNow.AddSeconds($NoWakeObservationSeconds)
    do {
        $currentExecutions = @(Get-Executions | ForEach-Object { $_.name })
        if (@($currentExecutions | Where-Object { $_ -notin $beforeNoWake }).Count -ne 0) {
            throw 'The self-hosted-only job started a new ACA execution despite the custom-only scaler rule.'
        }

        $noWakeState = Invoke-GhJson -Arguments @(
            'run', 'view', "$($script:noWakeRunId)", '--repo', $fullRepository,
            '--json', 'status,conclusion'
        )
        if ($noWakeState.status -ne 'queued') {
            throw "The self-hosted-only workflow unexpectedly left the queued state: $($noWakeState.status)."
        }
        Start-Sleep -Seconds 5
    } while ([datetime]::UtcNow -lt $noWakeDeadline)

    Cancel-RunIfActive -RunId $script:noWakeRunId
    $script:noWakeRunId = $null
    Write-Host "Self-hosted-only workflow remained queued for $NoWakeObservationSeconds seconds; no ACA execution started."
} finally {
    Cancel-RunIfActive -RunId $script:noWakeRunId
    Cancel-RunIfActive -RunId $script:matchRunId
    if ($script:runnerToClean) {
        Remove-TestRunnerIfPresent -Name $script:runnerToClean
    }
    Stop-NewExecutions
}
