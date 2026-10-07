param(
    [ValidateSet('Test', 'CleanupResources')]
    [string]$Mode = 'Test'
)

$ErrorActionPreference = 'Stop'

$subscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenantId = '30bac921-1547-4b1e-8445-72455da783f1'
$resourceGroup = 'rg-ghrunners-spike8-swc'
$location = 'swedencentral'
$containerAppsApiVersion = '2026-07-01'
$networkSecurityGroup = 'nsg-spike8-egress-swc'
$publicIp = 'pip-spike8-egress-swc'
$natGateway = 'nat-spike8-egress-swc'
$virtualNetwork = 'vnet-spike8-egress-swc'
$subnet = 'snet-aca'
$environment = 'acaenv-spike8-egress-swc'
$scalerJob = 'caj-spike8-keda'
$probeJob = 'caj-spike8-probe'
$curlImage = 'curlimages/curl@sha256:d43bdb28bae0be0998f3be83199bfb2b81e0a30b034b6d7586ce7e05de34c3fd'
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'RUNNER_TEMP is required to store non-secret test evidence and temporary request bodies.'
}
$evidencePath = Join-Path $env:RUNNER_TEMP 'spike8-evidence.json'
$resourceNames = @(
    $networkSecurityGroup, $publicIp, $natGateway, $virtualNetwork,
    "$virtualNetwork/$subnet", "$networkSecurityGroup/DenyGitHubApiForSpike8",
    $environment, $scalerJob, $probeJob
)
$tags = @(
    'application=ghrunners',
    'environment=spike',
    'workload=gh-runners',
    'owner=jonathan-vella',
    'costcenter=platform-engineering',
    'tech-contact=jonathan-vella',
    'technical-contact=jonathan-vella',
    'sla=development',
    'backup-policy=none',
    'maint-window=none',
    'spike-id=8'
)

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $allArguments = @($Arguments) + @('--subscription', $subscriptionId, '--only-show-errors')
    $output = & az @allArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = $output -join "`n"
        foreach ($secretName in @('GH_APP_PRIVATE_KEY')) {
            $secretValue = [Environment]::GetEnvironmentVariable($secretName)
            if (-not [string]::IsNullOrWhiteSpace($secretValue)) {
                $details = $details.Replace($secretValue, '[REDACTED]')
            }
        }
        throw "Azure CLI failed for '$($Arguments[0]) $($Arguments[1])': $details"
    }
    return ($output -join "`n")
}

function Get-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $json = Invoke-Az (@($Arguments) + @('--output', 'json'))
    try {
        return $json | ConvertFrom-Json
    } catch {
        throw "Azure CLI returned invalid JSON for '$($Arguments[0]) $($Arguments[1])'."
    }
}

function Get-AzResources {
    return @(Get-AzJson @('resource', 'list', '--resource-group', $resourceGroup))
}

function Invoke-ContainerAppsApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$ResourcePath,
        [AllowNull()][object]$Body
    )

    $uri = "https://management.azure.com$ResourcePath`?api-version=$containerAppsApiVersion"
    $arguments = @('rest', '--method', $Method, '--url', $uri)
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = Join-Path $env:RUNNER_TEMP "spike8-request-$([guid]::NewGuid().ToString('N')).json"
            $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            [System.IO.File]::WriteAllText($bodyPath, $json, [System.Text.UTF8Encoding]::new($false))
            & chmod 600 $bodyPath
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not restrict permissions on the temporary Azure request body.'
            }
            $arguments += @('--body', "@$bodyPath")
        }
        $response = Invoke-Az $arguments
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $null
        }
        try {
            return $response | ConvertFrom-Json
        } catch {
            throw "Azure Container Apps API returned invalid JSON for '$Method $ResourcePath'."
        }
    } finally {
        if ($bodyPath -and (Test-Path $bodyPath)) {
            Remove-Item -LiteralPath $bodyPath -Force
        }
    }
}

function Assert-ApprovedContext {
    $account = Get-AzJson @('account', 'show')
    if ($account.id -ne $subscriptionId -or $account.tenantId -ne $tenantId -or $account.name -ne 'shared') {
        throw 'Azure CLI is not authenticated to the approved shared subscription.'
    }
    $group = Get-AzJson @('group', 'show', '--name', $resourceGroup)
    if ($group.id -ne "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" -or
        $group.location -ne $location -or $group.tags.'spike-id' -cne '8' -or
        $group.tags.environment -cne 'spike') {
        throw 'The configured resource group is not the tagged issue #8 spike group.'
    }
}

function Get-NatMetrics {
    param(
        [Parameter(Mandatory)][string]$NatResourceId,
        [Parameter(Mandatory)][DateTime]$StartTime,
        [Parameter(Mandatory)][DateTime]$EndTime
    )

    $metrics = Get-AzJson @(
        'monitor', 'metrics', 'list', '--resource', $NatResourceId,
        '--metric', 'ByteCount', '--interval', 'PT1M', '--aggregation', 'Total',
        '--start-time', $StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        '--end-time', $EndTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    )
    $data = @($metrics.value | ForEach-Object { $_.timeseries } | ForEach-Object { $_.data })
    $points = @($data | Where-Object { $null -ne $_.timeStamp -and $null -ne $_.total })
    if ($points.Count -lt 2) {
        throw "NAT ByteCount metrics returned only $($points.Count) usable points for the requested interval."
    }
    return [pscustomobject]@{
        startTimeUtc = $StartTime.ToString('o')
        endTimeUtc = $EndTime.ToString('o')
        totalBytes = ($points | Measure-Object -Property total -Sum).Sum
        sampleCount = $points.Count
        points = $points
    }
}

function Start-ProbeExecution {
    param([Parameter(Mandatory)][string]$ExpectedStatus)

    $jobPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.App/jobs/$probeJob"
    $previousExecutions = Invoke-ContainerAppsApi -Method GET -ResourcePath "$jobPath/executions"
    $previousNames = @($previousExecutions.value | ForEach-Object { $_.name })
    $started = Invoke-ContainerAppsApi -Method POST -ResourcePath "$jobPath/start"
    $executionName = $started.name
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    while ([string]::IsNullOrWhiteSpace($executionName) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 10
        $currentExecutions = Invoke-ContainerAppsApi -Method GET -ResourcePath "$jobPath/executions"
        $newExecution = @($currentExecutions.value | Where-Object { $_.name -notin $previousNames } |
            Sort-Object { [DateTime]$_.properties.startTime } -Descending | Select-Object -First 1)
        if ($newExecution.Count -eq 1) {
            $executionName = $newExecution[0].name
        }
    }
    if ([string]::IsNullOrWhiteSpace($executionName)) {
        throw 'Azure did not expose a new diagnostic job execution after the start request.'
    }

    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        Start-Sleep -Seconds 10
        $execution = Invoke-ContainerAppsApi -Method GET -ResourcePath "$jobPath/executions/$executionName"
        $status = $execution.properties.status
        if ($status -in @('Succeeded', 'Failed', 'Canceled', 'Stopped', 'Degraded', 'Unknown')) {
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $expected = $status -eq $ExpectedStatus
    $evidence.probes += [pscustomobject]@{
        phase = if ($ExpectedStatus -eq 'Succeeded') { 'before-deny' } else { 'during-deny' }
        execution = $executionName
        status = $status
        startTimeUtc = $execution.properties.startTime
        endTimeUtc = $execution.properties.endTime
        expectedStatus = $ExpectedStatus
        assertionPassed = $expected
        errorDetailsObserved = $false
    }
    if (-not $expected) {
        throw "The workload-subnet deny probe was '$status'; expected '$ExpectedStatus'."
    }
}

function Wait-JobProvisioning {
    param([Parameter(Mandatory)][string]$JobPath)

    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        $job = Invoke-ContainerAppsApi -Method GET -ResourcePath $JobPath
        $state = $job.properties.provisioningState
        if ($state -in @('Succeeded', 'Failed', 'Canceled')) {
            break
        }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($state -ne 'Succeeded') {
        throw "Container Apps job provisioning ended in state '$state'."
    }
    return $job
}

function Write-Evidence {
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -Path $evidencePath -Encoding utf8
}

if ($Mode -eq 'CleanupResources') {
    $deleted = [System.Collections.Generic.List[string]]::new()
    try {
        Assert-ApprovedContext
        $resources = Get-AzResources
        $unexpected = @($resources | Where-Object { $_.name -notin $resourceNames })
        if ($unexpected.Count -gt 0) {
            throw 'Unexpected resources are present in the issue #8 group; refusing cleanup.'
        }
        $nestedResources = @("$virtualNetwork/$subnet", "$networkSecurityGroup/DenyGitHubApiForSpike8")
        $untagged = @($resources | Where-Object {
            $_.name -notin $nestedResources -and $_.tags.'spike-id' -cne '8'
        })
        if ($untagged.Count -gt 0) {
            throw 'A named resource lacks the issue #8 ownership tag; refusing cleanup.'
        }

        $deleteOrder = @($scalerJob, $probeJob, $environment, $virtualNetwork, $networkSecurityGroup, $natGateway, $publicIp)
        foreach ($name in $deleteOrder) {
            $resource = @($resources | Where-Object name -eq $name)
            if ($resource.Count -eq 1) {
                $null = Invoke-Az @('resource', 'delete', '--ids', $resource[0].id)
                $deleted.Add($resource[0].id)
            } elseif ($resource.Count -gt 1) {
                throw "More than one explicitly named resource '$name' exists; refusing cleanup."
            }
        }
        if (Test-Path $evidencePath) {
            $evidence = Get-Content -Raw -Path $evidencePath | ConvertFrom-Json
            $evidence | Add-Member -NotePropertyName cleanup -NotePropertyValue ([pscustomobject]@{
                attemptedAtUtc = [DateTime]::UtcNow.ToString('o')
                resourceGroupDeleted = $false
                deletedResourceIds = @($deleted)
                status = 'success'
            }) -Force
            Write-Evidence
        }
        Write-Output "Deleted $($deleted.Count) explicitly named issue #8 resources; resource group retained for operator cleanup."
    } catch {
        if (Test-Path $evidencePath) {
            $evidence = Get-Content -Raw -Path $evidencePath | ConvertFrom-Json
            $evidence | Add-Member -NotePropertyName cleanup -NotePropertyValue ([pscustomobject]@{
                attemptedAtUtc = [DateTime]::UtcNow.ToString('o')
                resourceGroupDeleted = $false
                deletedResourceIds = @($deleted)
                status = 'failed'
                error = $_.Exception.Message
            }) -Force
            Write-Evidence
        }
        throw
    }
    return
}

$evidence = [ordered]@{
    issue = 8
    subscriptionId = $subscriptionId
    resourceGroup = $resourceGroup
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    testWindowSecondsPerPhase = 180
    scalerAuthentication = 'GitHub App secrets referenced; secret values are not recorded.'
    scalerPollingObservation = 'not-observed; configuration and aggregate NAT counters do not prove a successful poll.'
    diagnosticImage = $curlImage
    natMetric = 'ByteCount'
    natMetricPhases = @()
    probes = @()
    scaleRule = $null
    classification = 'manual-review-required'
    conclusion = 'No automated acceptance decision is made from aggregate NAT metrics.'
}

try {
    Assert-ApprovedContext
    if ($env:GITHUB_REF -ne 'refs/heads/main' -or $env:SPIKE_CONFIRMATION -ne 'run-spike8') {
        throw 'Run only from main and provide the exact run-spike8 confirmation.'
    }
    foreach ($name in @('GH_APP_ID', 'GH_APP_INSTALLATION_ID', 'GH_APP_PRIVATE_KEY')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Required platform-prod secret '$name' is unavailable."
        }
    }
    $existing = Get-AzResources
    if ($existing.Count -ne 0) {
        throw 'The issue #8 resource group must be empty before the experiment.'
    }

    $null = Invoke-Az (@(
        'network', 'nsg', 'create', '--resource-group', $resourceGroup, '--name', $networkSecurityGroup,
        '--location', $location, '--tags'
    ) + $tags)
    $null = Invoke-Az (@(
        'network', 'public-ip', 'create', '--resource-group', $resourceGroup, '--name', $publicIp,
        '--location', $location, '--sku', 'Standard', '--allocation-method', 'Static', '--tags'
    ) + $tags)
    $null = Invoke-Az (@(
        'network', 'nat', 'gateway', 'create', '--resource-group', $resourceGroup, '--name', $natGateway,
        '--location', $location, '--public-ip-addresses', $publicIp, '--idle-timeout', '10', '--tags'
    ) + $tags)
    $null = Invoke-Az (@(
        'network', 'vnet', 'create', '--resource-group', $resourceGroup, '--name', $virtualNetwork,
        '--location', $location, '--address-prefixes', '10.252.8.0/24',
        '--subnet-name', $subnet, '--subnet-prefixes', '10.252.8.0/27', '--tags'
    ) + $tags)
    $null = Invoke-Az @(
        'network', 'vnet', 'subnet', 'update', '--resource-group', $resourceGroup,
        '--vnet-name', $virtualNetwork, '--name', $subnet,
        '--delegations', 'Microsoft.App/environments',
        '--network-security-group', $networkSecurityGroup,
        '--nat-gateway', $natGateway
    )
    $subnetId = Invoke-Az @(
        'network', 'vnet', 'subnet', 'show', '--resource-group', $resourceGroup,
        '--vnet-name', $virtualNetwork, '--name', $subnet, '--query', 'id', '--output', 'tsv'
    )
    $environmentPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.App/managedEnvironments/$environment"
    $environmentBody = @{
        location = $location
        properties = @{
            environmentMode = 'WorkloadProfiles'
            publicNetworkAccess = 'Disabled'
            vnetConfiguration = @{
                infrastructureSubnetId = $subnetId.Trim()
                internal = $true
            }
            workloadProfiles = @(@{
                name = 'Consumption'
                workloadProfileType = 'Consumption'
            })
        }
        tags = @{}
    }
    foreach ($tag in $tags) {
        $key, $value = $tag -split '=', 2
        $environmentBody.tags[$key] = $value
    }
    $null = Invoke-ContainerAppsApi -Method PUT -ResourcePath $environmentPath -Body $environmentBody
    $environmentDeadline = [DateTime]::UtcNow.AddMinutes(12)
    do {
        Start-Sleep -Seconds 30
        $environmentState = Invoke-ContainerAppsApi -Method GET -ResourcePath $environmentPath
        $provisioningState = $environmentState.properties.provisioningState
        if ($provisioningState -in @('Succeeded', 'Failed', 'Canceled')) {
            break
        }
    } while ([DateTime]::UtcNow -lt $environmentDeadline)
    $evidence.environmentProvisioning = [pscustomobject]@{
        status = $provisioningState
        errors = $environmentState.properties.deploymentErrors
    }
    if ($provisioningState -ne 'Succeeded') {
        throw "Container Apps environment provisioning ended in state '$provisioningState'."
    }
    $evidence.environmentNetwork = [pscustomobject]@{
        publicNetworkAccess = $environmentState.properties.publicNetworkAccess
        internal = $environmentState.properties.vnetConfiguration.internal
        infrastructureSubnetId = $environmentState.properties.vnetConfiguration.infrastructureSubnetId
    }
    if ($environmentState.properties.publicNetworkAccess -ne 'Disabled' -or
        $environmentState.properties.vnetConfiguration.internal -ne $true -or
        $environmentState.properties.vnetConfiguration.infrastructureSubnetId -ne $subnetId.Trim()) {
        throw 'The provisioned environment does not match the required private-network configuration.'
    }

    $publicApi = Invoke-RestMethod -Uri 'https://api.github.com/meta' -Headers @{ 'User-Agent' = 'azure-gh-runners-spike8' }
    $apiPrefixes = @($publicApi.api | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d+$' })
    if ($apiPrefixes.Count -eq 0 -or $apiPrefixes.Count -gt 1000) {
        throw 'GitHub metadata returned an unusable API CIDR list; the deny test cannot safely proceed.'
    }

    $probeScript = 'curl -fsS --connect-timeout 10 https://api.github.com/meta -o /dev/null'
    $jobBasePath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.App/jobs"
    $probeBody = @{
        location = $location
        properties = @{
            environmentId = $environmentPath
            configuration = @{
                triggerType = 'Manual'
                replicaTimeout = 60
                replicaRetryLimit = 0
                manualTriggerConfig = @{
                    parallelism = 1
                    replicaCompletionCount = 1
                }
            }
            template = @{
                containers = @(@{
                    name = $probeJob
                    image = $curlImage
                    command = @('sh')
                    args = @('-c', $probeScript)
                    resources = @{ cpu = 0.25; memory = '0.5Gi' }
                })
            }
        }
        tags = $environmentBody.tags
    }
    $null = Invoke-ContainerAppsApi -Method PUT -ResourcePath "$jobBasePath/$probeJob" -Body $probeBody
    $null = Wait-JobProvisioning -JobPath "$jobBasePath/$probeJob"
    Start-ProbeExecution -ExpectedStatus 'Succeeded'
    $natResourceId = Invoke-Az @(
        'network', 'nat', 'gateway', 'show', '--resource-group', $resourceGroup,
        '--name', $natGateway, '--query', 'id', '--output', 'tsv'
    )
    Start-Sleep -Seconds 180
    $baselineStart = [DateTime]::UtcNow.AddMinutes(-3)
    $baselineEnd = [DateTime]::UtcNow
    $evidence.natMetricPhases += [pscustomobject]@{
        phase = 'baseline-no-scale-rule'
        startedAtUtc = $baselineStart.ToString('o')
        endedAtUtc = $baselineEnd.ToString('o')
        response = $null
    }

    $metadata = @(
        'githubAPIURL=https://api.github.com',
        'owner=jonathan-vella',
        'runnerScope=repo',
        'repos=ghr-smoke',
        'labels=ghr-spike8-probe',
        'noDefaultLabels=true',
        'enableEtags=true',
        'targetWorkflowQueueLength=1',
        "applicationID=$env:GH_APP_ID",
        "installationID=$env:GH_APP_INSTALLATION_ID"
    )
    $metadataObject = @{}
    foreach ($entry in $metadata) {
        $key, $value = $entry -split '=', 2
        $metadataObject[$key] = $value
    }
    $scalerBody = @{
        location = $location
        properties = @{
            environmentId = $environmentPath
            configuration = @{
                triggerType = 'Event'
                replicaTimeout = 300
                replicaRetryLimit = 0
                eventTriggerConfig = @{
                    parallelism = 1
                    replicaCompletionCount = 1
                    scale = @{
                        pollingInterval = 30
                        minExecutions = 0
                        maxExecutions = 1
                        rules = @(@{
                            name = 'github-runner'
                            type = 'github-runner'
                            metadata = $metadataObject
                            auth = @(@{
                                triggerParameter = 'appKey'
                                secretRef = 'github-app-key'
                            })
                        })
                    }
                }
                secrets = @(@{
                    name = 'github-app-key'
                    value = $env:GH_APP_PRIVATE_KEY
                })
            }
            template = @{
                containers = @(@{
                    name = $scalerJob
                    image = $curlImage
                    command = @('sh')
                    args = @('-c', 'sleep 300')
                    resources = @{ cpu = 0.25; memory = '0.5Gi' }
                })
            }
        }
        tags = $environmentBody.tags
    }
    $null = Invoke-ContainerAppsApi -Method PUT -ResourcePath "$jobBasePath/$scalerJob" -Body $scalerBody

    $job = Wait-JobProvisioning -JobPath "$jobBasePath/$scalerJob"
    $rules = @($job.properties.configuration.eventTriggerConfig.scale.rules)
    $rule = @($rules | Where-Object name -eq 'github-runner')
    if ($rule.Count -ne 1 -or $rule[0].type -ne 'github-runner' -or
        $rule[0].metadata.githubAPIURL -ne 'https://api.github.com' -or
        $rule[0].metadata.owner -ne 'jonathan-vella' -or
        $rule[0].metadata.runnerScope -ne 'repo' -or
        $rule[0].metadata.repos -ne 'ghr-smoke' -or
        $rule[0].metadata.labels -ne 'ghr-spike8-probe' -or
        $rule[0].metadata.noDefaultLabels -ne 'true' -or
        $rule[0].metadata.enableEtags -ne 'true' -or
        $rule[0].metadata.targetWorkflowQueueLength -ne '1' -or
        $rule[0].metadata.applicationID -ne $env:GH_APP_ID -or
        $rule[0].metadata.installationID -ne $env:GH_APP_INSTALLATION_ID -or
        @($rule[0].auth | Where-Object { $_.triggerParameter -eq 'appKey' -and $_.secretRef -eq 'github-app-key' }).Count -ne 1) {
        throw 'The persisted KEDA rule does not match the expected GitHub App-authenticated test configuration.'
    }
    $evidence.scaleRule = [pscustomobject]@{
        persisted = $true
        type = $rule[0].type
        apiUrl = $rule[0].metadata.githubAPIURL
        owner = $rule[0].metadata.owner
        runnerScope = $rule[0].metadata.runnerScope
        repo = $rule[0].metadata.repos
        labels = $rule[0].metadata.labels
        noDefaultLabels = $rule[0].metadata.noDefaultLabels
        enableEtags = $rule[0].metadata.enableEtags
        targetWorkflowQueueLength = $rule[0].metadata.targetWorkflowQueueLength
        authParameter = 'appKey'
        secretReference = 'github-app-key'
        appKeyValueRecorded = $false
    }

    $activeStart = [DateTime]::UtcNow
    Start-Sleep -Seconds 180
    $activeEnd = [DateTime]::UtcNow
    $evidence.natMetricPhases += [pscustomobject]@{
        phase = 'github-app-authenticated-rule-configured'
        startedAtUtc = $activeStart.ToString('o')
        endedAtUtc = $activeEnd.ToString('o')
        response = $null
    }
    $executionsResult = Invoke-ContainerAppsApi -Method GET -ResourcePath "$jobBasePath/$scalerJob/executions"
    $executions = @($executionsResult.value)
    $evidence.scaleRuleExecutions = $executions.Count
    if ($executions.Count -ne 0) {
        throw 'The unique probe scale rule unexpectedly started a container execution; stopping the experiment.'
    }

    $denyRuleArgs = @(
        'network', 'nsg', 'rule', 'create', '--resource-group', $resourceGroup,
        '--nsg-name', $networkSecurityGroup, '--name', 'DenyGitHubApiForSpike8',
        '--priority', '100', '--direction', 'Outbound', '--access', 'Deny', '--protocol', 'Tcp',
        '--source-address-prefixes', '*', '--source-port-ranges', '*',
        '--destination-address-prefixes'
    ) + $apiPrefixes + @('--destination-port-ranges', '443', '--description', 'Temporary issue 8 GitHub API deny test.')
    $null = Invoke-Az $denyRuleArgs
    Start-ProbeExecution -ExpectedStatus 'Failed'
    $denyStart = [DateTime]::UtcNow
    Start-Sleep -Seconds 180
    $denyEnd = [DateTime]::UtcNow
    $evidence.natMetricPhases += [pscustomobject]@{
        phase = 'api-deny-rule-active'
        startedAtUtc = $denyStart.ToString('o')
        endedAtUtc = $denyEnd.ToString('o')
        response = $null
    }
    $evidence.apiDeny = [pscustomobject]@{
        source = 'https://api.github.com/meta'
        cidrCount = $apiPrefixes.Count
        destinationPrefixes = $apiPrefixes
        destinationPort = 443
        nsgRuleName = 'DenyGitHubApiForSpike8'
        nsgRulePriority = 100
        nsgRuleProtocol = 'Tcp'
        probeSucceededBeforeDeny = $true
        probeFailedDuringDeny = $true
        exactContainerErrorObserved = $false
        kedaPollOriginConclusion = 'manual-review-required'
    }
    Start-Sleep -Seconds 180
    foreach ($phase in $evidence.natMetricPhases) {
        $phase.response = Get-NatMetrics -NatResourceId $natResourceId.Trim() `
            -StartTime ([DateTime]$phase.startedAtUtc) -EndTime ([DateTime]$phase.endedAtUtc)
    }
    $evidence.metricComparison = [pscustomobject]@{
        baselineBytes = $evidence.natMetricPhases[0].response.totalBytes
        scalerEnabledBytes = $evidence.natMetricPhases[1].response.totalBytes
        denyActiveBytes = $evidence.natMetricPhases[2].response.totalBytes
        automaticConclusion = $false
    }
    $evidence.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-Evidence
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        @"
## Issue #8 KEDA egress evidence

- Subscription/resource group: ``$subscriptionId`` / ``$resourceGroup``
- GitHub App auth configuration: persisted with the real ``platform-prod`` secret reference; private key value was not recorded.
- Successful KEDA polling: **not asserted**. The available NAT metric is aggregate subnet evidence, not destination- or process-level attribution.
- Workload subnet probe: succeeded before the API deny and failed during the deny.
- NAT metric: ``ByteCount`` samples were captured in the no-rule, authenticated-scaler, and deny windows.
- KEDA polling origin: **manual review required**. Aggregate NAT counters and a workload deny probe are evidence inputs, not an automatic acceptance decision.
- Resource cleanup: see the ``cleanup`` record in the attached evidence artifact.
"@ | Add-Content -Path $env:GITHUB_STEP_SUMMARY
    }
} finally {
    if ($evidence -and -not $evidence.finishedAtUtc) {
        $evidence.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-Evidence
}
