param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]+$')]
    [long]$DeploymentRunId,
    [ValidateRange(60, 600)]
    [int]$MatchTimeoutSeconds = 300,
    [ValidateRange(120, 300)]
    [int]$NoWakeObservationSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ResourceGroup = 'rg-ghrunners-spike10-swc'
$JobName = 'caj-ghr-spike10-jit-labels'
$Owner = 'jonathan-vella'
$Repository = 'ghr-smoke'
$CustomLabel = 'ghr-smoke-jit-label-spike'
$SubscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$fullRepository = "$Owner/$Repository"
$matchWorkflow = 'jit-label-match.yml'
$noWakeWorkflow = 'jit-self-hosted-only.yml'
$script:matchRunId = $null
$script:noWakeRunId = $null
$script:runnerToClean = $null
$script:baselineExecutionNames = @()
$script:baselineExecutionsCaptured = $false
$script:ownedExecutionNames = [System.Collections.Generic.HashSet[string]]::new()
$script:commandDeadline = $null
Import-Module (Join-Path $PSScriptRoot 'Bounded-Command.psm1') -Force

function Invoke-BoundedCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15
    )

    $invokeArguments = @{
        Command = $Command
        Arguments = $Arguments
        TimeoutSeconds = $TimeoutSeconds
        CommandRunner = $script:CommandRunner
    }
    if ($script:commandDeadline) {
        $invokeArguments.Deadline = $script:commandDeadline
    }
    return Invoke-BoundedNativeCommand @invokeArguments
}

function New-CommandDeadline {
    param([Parameter(Mandatory)][ValidateRange(1, 600)][int]$Seconds)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    if ($script:commandDeadline -and $script:commandDeadline -lt $deadline) {
        return $script:commandDeadline
    }
    return $deadline
}

function Invoke-GhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = Invoke-BoundedCommand -Command 'gh' -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace(($output -join ''))) {
        return $null
    }
    return ($output -join "`n") | ConvertFrom-Json
}

function Get-Executions {
    $output = Invoke-BoundedCommand -Command 'az' -Arguments @(
        'containerapp', 'job', 'execution', 'list',
        '--name', $JobName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--output', 'json'
    )
    return @($output | ConvertFrom-Json)
}

function Assert-OwnedJob {
    $output = Invoke-BoundedCommand -Command 'az' -Arguments @(
        'containerapp', 'job', 'show', '--name', $JobName,
        '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId, '--output', 'json'
    )
    $job = $output | ConvertFrom-Json
    if ($job.tags.'spike-id' -ne '10' -or
        $job.tags.'spike-name' -ne 'jit-runner-labels' -or
        $job.tags.'spike-deployment-run-id' -ne "$DeploymentRunId") {
        throw 'The ACA job ownership marker does not match the supplied deployment run; refusing execution cleanup.'
    }
}

function Get-WorkflowRun {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][datetime]$NotBeforeUtc,
        [Parameter(Mandatory)][string]$Nonce
    )

    $runs = Invoke-GhJson -Arguments @(
        'run', 'list', '--repo', $fullRepository, '--workflow', $Workflow,
        '--event', 'workflow_dispatch', '--limit', '20',
        '--json', 'databaseId,createdAt,status,conclusion,headBranch,displayTitle'
    )
    $expectedTitle = if ($Workflow -eq $matchWorkflow) {
        "Spike 10 label match - $Nonce"
    } else {
        "Spike 10 no-wake - $Nonce"
    }
    return $runs |
        Where-Object {
            $_.headBranch -eq 'main' -and
            [datetime]::Parse($_.createdAt).ToUniversalTime() -ge $NotBeforeUtc -and
            $_.displayTitle -eq $expectedTitle
        } |
        Sort-Object { [datetime]::Parse($_.createdAt) } -Descending |
        Select-Object -First 1
}

function Start-Workflow {
    param([Parameter(Mandatory)][string]$Workflow)

    $nonce = [guid]::NewGuid().ToString('N')
    $startedAt = [datetime]::UtcNow.AddSeconds(-3)
    Invoke-BoundedCommand -Command 'gh' -Arguments @(
        'workflow', 'run', $Workflow, '--repo', $fullRepository, '--ref', 'main', '--field', "spike_nonce=$nonce"
    ) | Out-Null

    $deadline = New-CommandDeadline -Seconds 60
    $priorDeadline = $script:commandDeadline
    $script:commandDeadline = $deadline
    try {
        do {
            Start-Sleep -Seconds 3
            $run = Get-WorkflowRun -Workflow $Workflow -NotBeforeUtc $startedAt -Nonce $nonce
            if ($run) {
                return $run
            }
        } while ([datetime]::UtcNow -lt $deadline)
    } finally {
        $script:commandDeadline = $priorDeadline
    }

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
    $run = Invoke-GhJson -Arguments @(
        'run', 'view', "$RunId", '--repo', $fullRepository, '--json', 'status,conclusion'
    )
    if ($run.status -eq 'completed') {
        if ($RunId -eq $script:noWakeRunId -and $run.conclusion -ne 'cancelled') {
            throw "Self-hosted-only run $RunId completed without the required cancellation."
        }
        return
    }
    if ($run.status -ne 'completed') {
        Invoke-BoundedCommand -Command 'gh' -Arguments @('run', 'cancel', "$RunId", '--repo', $fullRepository) | Out-Null
        $deadline = New-CommandDeadline -Seconds 60
        $priorDeadline = $script:commandDeadline
        $script:commandDeadline = $deadline
        try {
            do {
                Start-Sleep -Seconds 3
                $run = Invoke-GhJson -Arguments @(
                    'run', 'view', "$RunId", '--repo', $fullRepository, '--json', 'status,conclusion'
                )
                if ($run.status -eq 'completed') {
                    if ($run.conclusion -ne 'cancelled') {
                        throw "Smoke workflow run $RunId completed with unexpected conclusion '$($run.conclusion)'."
                    }
                    return
                }
            } while ([datetime]::UtcNow -lt $deadline)
        } finally {
            $script:commandDeadline = $priorDeadline
        }
        throw "Smoke workflow run $RunId did not reach a cancelled terminal state."
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
    Assert-OwnedJob

    foreach ($execution in (Get-Executions)) {
        if ($execution.name -notin $script:ownedExecutionNames -or $execution.properties.status -ne 'Running') {
            continue
        }

        $escapedName = [uri]::EscapeDataString($execution.name)
        $resourceId = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/jobs/$JobName/executions/$escapedName/stop?api-version=2026-07-01"
        Invoke-BoundedCommand -Command 'az' -Arguments @(
            'rest', '--method', 'post', '--url', $resourceId, '--output', 'none'
        ) | Out-Null
        Write-Host "Stopped unexpected issue 10 execution: $($execution.name)"
    }

    foreach ($executionName in @($script:ownedExecutionNames)) {
        $deadline = New-CommandDeadline -Seconds 30
        $priorDeadline = $script:commandDeadline
        $script:commandDeadline = $deadline
        try {
            do {
                $current = Get-Executions | Where-Object name -eq $executionName | Select-Object -First 1
                if (-not $current -or $current.properties.status -ne 'Running') {
                    break
                }
                Start-Sleep -Seconds 3
            } while ([datetime]::UtcNow -lt $deadline)
        } finally {
            $script:commandDeadline = $priorDeadline
        }
        if ($current -and $current.properties.status -eq 'Running') {
            throw "Issue 10 execution '$executionName' remains active after cleanup."
        }
    }
}

function Assert-NoWakeJob {
    param([Parameter(Mandatory)]$Jobs)

    $jobs = @($Jobs.jobs | Where-Object name -eq 'should-remain-queued')
    if ($jobs.Count -ne 1) {
        throw 'The negative-control run did not expose exactly one expected runner job.'
    }
    $labels = @($jobs[0].labels)
    if ($labels.Count -ne 1 -or $labels[0] -ine 'self-hosted') {
        throw "The negative-control job requested unexpected runner labels: $($labels -join ', ')."
    }
    if ($jobs[0].status -ne 'queued' -or $jobs[0].runner_name) {
        throw 'The self-hosted-only job was not actually queued without an assigned runner.'
    }
}

function Assert-NoActiveProbeRuns {
    foreach ($workflow in @($matchWorkflow, $noWakeWorkflow)) {
        foreach ($status in @('queued', 'in_progress')) {
            $runs = Invoke-GhJson -Arguments @(
                'run', 'list', '--repo', $fullRepository, '--workflow', $workflow,
                '--status', $status, '--limit', '20', '--json', 'databaseId,status'
            )
            if (@($runs).Count -gt 0) {
                throw "A prior $workflow probe run is still $status; refusing a concurrent observation."
            }
        }
    }
}

function Invoke-JitLabelScaleObservation {
try {
    $activeSubscription = Invoke-BoundedCommand -Command 'az' -Arguments @(
        'account', 'show', '--subscription', $SubscriptionId, '--query', 'id', '--output', 'tsv'
    )
    if ($activeSubscription.Trim() -ne $SubscriptionId) {
        throw 'Azure CLI must be authenticated to the approved shared subscription before observation.'
    }

    $jobState = Invoke-BoundedCommand -Command 'az' -Arguments @(
        'containerapp', 'job', 'show', '--name', $JobName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--output', 'json'
    )
    $jobState = $jobState | ConvertFrom-Json
    if ($jobState.tags.'spike-id' -ne '10' -or
        $jobState.tags.'spike-name' -ne 'jit-runner-labels' -or
        $jobState.tags.'spike-deployment-run-id' -ne "$DeploymentRunId" -or
        $jobState.location -ne 'swedencentral') {
        throw 'The observed ACA job is not tagged as the issue 10 job in swedencentral.'
    }

    Assert-NoActiveProbeRuns
    $initialRunners = Invoke-GhJson -Arguments @(
        'api', "repos/$fullRepository/actions/runners?per_page=100"
    )
    if (@($initialRunners.runners).Count -ne 0) {
        throw 'The smoke repository must have no registered runners before this exclusive label-matching test.'
    }

    $initialExecutions = @(Get-Executions)
    if (@($initialExecutions | Where-Object { $_.properties.status -eq 'Running' }).Count -gt 0) {
        throw 'The issue 10 job already has a running execution; refusing to interfere with another test.'
    }
    $beforeMatch = @($initialExecutions | ForEach-Object { $_.name })
    $script:baselineExecutionNames = $beforeMatch
    $script:baselineExecutionsCaptured = $true
    $matchRun = Start-Workflow -Workflow $matchWorkflow
    $script:matchRunId = [long]$matchRun.databaseId
    Write-Host "Matched-label test run: $($script:matchRunId)"

    $deadline = New-CommandDeadline -Seconds $MatchTimeoutSeconds
    $script:commandDeadline = $deadline
    $observedLabels = @()
    $runnerName = $null
    do {
        $runJobs = Get-RunJobs -RunId $script:matchRunId
        $job = @($runJobs.jobs | Where-Object { $_.name -eq 'verify-label-match' }) | Select-Object -First 1
        if ($job) {
            $requestedLabels = @($job.labels)
            if ($requestedLabels.Count -ne 1 -or $requestedLabels[0] -ine $CustomLabel) {
                throw "The dispatched matching workflow did not request only the expected custom label '$CustomLabel'."
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
    $script:commandDeadline = $null
    if (-not ($observedLabels | Where-Object { $_ -ieq 'self-hosted' })) {
        Write-Host 'Observed JIT registration did not include self-hosted.'
    } else {
        Write-Host 'Observed JIT registration includes self-hosted.'
    }

    $afterMatch = @(Get-Executions)
    $newMatchExecutions = @($afterMatch | Where-Object { $_.name -notin $beforeMatch })
    foreach ($execution in $newMatchExecutions) {
        [void]$script:ownedExecutionNames.Add($execution.name)
    }
    if ($newMatchExecutions.Count -ne 1 -or $newMatchExecutions[0].properties.status -ne 'Succeeded') {
        throw 'The matching workflow did not produce exactly one successful ACA job execution.'
    }
    Write-Host "Matched-label ACA execution succeeded: $($newMatchExecutions[0].name)"

    $runnerRemovalDeadline = New-CommandDeadline -Seconds 30
    $script:commandDeadline = $runnerRemovalDeadline
    $remainingRunners = Get-RunnerByName -Name $runnerName
    while ($remainingRunners.Count -gt 0 -and [datetime]::UtcNow -lt $runnerRemovalDeadline) {
        Start-Sleep -Seconds 3
        $remainingRunners = Get-RunnerByName -Name $runnerName
    }
    $automaticRemovalSucceeded = $remainingRunners.Count -eq 0
    if (-not $automaticRemovalSucceeded) {
        Remove-TestRunnerIfPresent -Name $runnerName
        $script:runnerToClean = $null
        $script:commandDeadline = $null
        throw "The ephemeral runner did not deregister itself; explicit cleanup removed it."
    }
    $script:runnerToClean = $null
    Write-Host 'Ephemeral runner registration was removed automatically.'

    $beforeNoWake = @(Get-Executions | ForEach-Object { $_.name })
    $noWakeRun = Start-Workflow -Workflow $noWakeWorkflow
    $script:noWakeRunId = [long]$noWakeRun.databaseId
    Write-Host "Self-hosted-only no-wake test run: $($script:noWakeRunId)"

    $noWakeDeadline = New-CommandDeadline -Seconds $NoWakeObservationSeconds
    $script:commandDeadline = $noWakeDeadline
    do {
        $currentExecutionRecords = @(Get-Executions)
        $unexpectedExecutions = @($currentExecutionRecords | Where-Object { $_.name -notin $beforeNoWake })
        foreach ($execution in $unexpectedExecutions) {
            [void]$script:ownedExecutionNames.Add($execution.name)
        }
        if ($unexpectedExecutions.Count -ne 0) {
            throw 'The self-hosted-only job started a new ACA execution despite the custom-only scaler rule.'
        }

        $noWakeJobs = Get-RunJobs -RunId $script:noWakeRunId
        Assert-NoWakeJob -Jobs $noWakeJobs
        $noWakeState = Invoke-GhJson -Arguments @(
            'run', 'view', "$($script:noWakeRunId)", '--repo', $fullRepository,
            '--json', 'status,conclusion'
        )
        if ($noWakeState.status -notin @('queued', 'in_progress')) {
            throw "The self-hosted-only workflow unexpectedly left the pending state: $($noWakeState.status)."
        }
        Start-Sleep -Seconds 5
    } while ([datetime]::UtcNow -lt $noWakeDeadline)

    Cancel-RunIfActive -RunId $script:noWakeRunId
    $script:noWakeRunId = $null
    $script:commandDeadline = $null
    Write-Host "The self-hosted-only job stayed queued without an assignment for $NoWakeObservationSeconds seconds; no ACA execution started."
} finally {
    $script:commandDeadline = [datetime]::UtcNow.AddSeconds(90)
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($runId in @($script:noWakeRunId, $script:matchRunId)) {
        if ($runId) {
            try {
                Cancel-RunIfActive -RunId $runId
            } catch {
                $cleanupErrors.Add($_.Exception.Message)
            }
        }
    }
    if ($script:runnerToClean) {
        try {
            Remove-TestRunnerIfPresent -Name $script:runnerToClean
        } catch {
            $cleanupErrors.Add($_.Exception.Message)
        }
    }
    try {
        if ($script:baselineExecutionsCaptured) {
            Assert-OwnedJob
            foreach ($execution in (Get-Executions)) {
                if ($execution.name -notin $script:baselineExecutionNames) {
                    [void]$script:ownedExecutionNames.Add($execution.name)
                }
            }
        }
        Stop-NewExecutions
    } catch {
        $cleanupErrors.Add($_.Exception.Message)
    }
    if ($cleanupErrors.Count -gt 0) {
        throw "Observer cleanup had failures: $($cleanupErrors -join '; ')"
    }
    $script:commandDeadline = $null
}
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-JitLabelScaleObservation
}
