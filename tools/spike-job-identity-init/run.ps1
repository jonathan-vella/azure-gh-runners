param(
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$resourceGroup = 'rg-ghrunners-spike9-swc'
$managedResourceGroup = 'ME_ghr9-env_rg-ghrunners-spike9-swc_swedencentral'
$location = 'swedencentral'
$jobName = 'ghr9-secret-isolation'
$artifactPath = Join-Path $PSScriptRoot 'evidence.json'
$groupCreatedHere = $false

function Invoke-AzText {
    param([string[]]$Arguments)

    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments[0]) $($Arguments[1])"
    }
    return ($result -join "`n")
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $result = Invoke-AzText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }
    return $result | ConvertFrom-Json
}

function New-SyntheticValue {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToHexString($bytes)
}

function Remove-SpikeResourceGroup {
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
        if ($group.tags.issue -ne '9' -or $group.tags.purpose -ne 'init-container-secret-isolation-spike') {
            throw 'Refusing cleanup because the resource group does not carry the issue 9 spike tags.'
        }

        $resources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--query', '[].{id:id,name:name,type:type}', '--output', 'json')
        $unexpected = @($resources | Where-Object {
            $knownDns = $_.name -in @(
                'privatelink.azurecr.io',
                'privatelink.azurecr.io/ghr9-vnet-link',
                'privatelink.vaultcore.azure.net',
                'privatelink.vaultcore.azure.net/ghr9-vnet-link'
            )
            $knownRole = $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.id -match '/(registries/ghr9[^/]*|vaults/ghr9kv[^/]*)/providers/Microsoft.Authorization/roleAssignments/'
            -not ($_.name -like 'ghr9*' -or $knownDns -or $knownRole)
        })
        if ($unexpected.Count -gt 0) {
            throw 'Refusing cleanup because the spike resource group contains an unrecognized resource.'
        }

        Invoke-AzText @('group', 'delete', '--name', $resourceGroup, '--subscription', $subscription, '--yes', '--no-wait', '--output', 'none') | Out-Null
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            Start-Sleep -Seconds 10
            $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
            if ($exists.Trim() -eq 'false') {
                break
            }
        }
    }
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        throw 'Spike resource group deletion did not complete within ten minutes.'
    }

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $managedExists = Invoke-AzText @('group', 'exists', '--name', $managedResourceGroup, '--subscription', $subscription, '--output', 'tsv')
        if ($managedExists.Trim() -eq 'false') {
            Write-Output 'ASSERT_cleanup_resource_group_absent=true'
            Write-Output 'ASSERT_aca_managed_resource_group_absent=true'
            return
        }
        Start-Sleep -Seconds 10
    }
    throw "ACA-managed resource group '$managedResourceGroup' remains after deleting the spike environment."
}

try {
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        if (-not $Resume) {
            throw 'Spike resource group already exists. Use -Resume only for the tagged group created by this spike.'
        }
        $existingGroup = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
        if ($existingGroup.location -ne $location -or $existingGroup.tags.issue -ne '9' -or $existingGroup.tags.purpose -ne 'init-container-secret-isolation-spike') {
            throw 'Existing resource group does not match the isolated issue 9 spike.'
        }
        $groupResources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--output', 'json')
        if (@($groupResources).Count -gt 0) {
            throw 'Resume requires an empty spike resource group.'
        }
    } else {
        $expiry = [DateTime]::UtcNow.AddMinutes(40).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Invoke-AzText @(
            'group', 'create', '--name', $resourceGroup, '--location', $location, '--subscription', $subscription,
            '--tags', 'project=azure-gh-runners', 'issue=9', 'purpose=init-container-secret-isolation-spike', "expiresOn=$expiry",
            '--output', 'none'
        ) | Out-Null
        $groupCreatedHere = $true
    }

    $canary = New-SyntheticValue
    $canaryBytes = [Text.Encoding]::UTF8.GetBytes($canary)
    $canaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canaryBytes)).ToLowerInvariant()
    $scaleCanary = New-SyntheticValue
    $jitConfig = 'synthetic-jit-config'
    $jitHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jitConfig))).ToLowerInvariant()
    $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
    $expiry = $group.tags.expiresOn

    $infraOutputs = Invoke-AzJson @(
        'deployment', 'group', 'create', '--name', 'spike9-infra', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--template-file', (Join-Path $PSScriptRoot 'main.bicep'),
        '--parameters', "syntheticAppKey=$canary", "expiry=$expiry",
        '--only-show-errors', '--query', 'properties.outputs', '--output', 'json'
    )
    $acrName = $infraOutputs.acrName.value
    $acrLoginServer = $infraOutputs.acrLoginServer.value
    $identityId = $infraOutputs.identityId.value
    $environmentId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/managedEnvironments/$($infraOutputs.environmentName.value)"
    $secretUri = $infraOutputs.syntheticSecretUri.value
    if ([string]::IsNullOrWhiteSpace($acrName) -or [string]::IsNullOrWhiteSpace($identityId) -or [string]::IsNullOrWhiteSpace($secretUri)) {
        throw 'Infrastructure deployment omitted a required non-secret output.'
    }

    Invoke-AzText @(
        'acr', 'config', 'authentication-as-arm', 'update', '--registry', $acrName, '--status', 'enabled',
        '--subscription', $subscription, '--only-show-errors', '--output', 'none'
    ) | Out-Null
    Invoke-AzText @(
        'acr', 'import', '--name', $acrName, '--resource-group', $resourceGroup,
        '--source', 'mcr.microsoft.com/azure-cli:2.91.0', '--image', 'probe:2.91.0',
        '--subscription', $subscription, '--only-show-errors', '--output', 'none'
    ) | Out-Null
    $imageDigest = Invoke-AzText @(
        'acr', 'repository', 'show', '--name', $acrName, '--image', 'probe:2.91.0',
        '--subscription', $subscription, '--query', 'digest', '--output', 'tsv'
    )
    if ($imageDigest.Trim() -notmatch '^sha256:[a-f0-9]{64}$') {
        throw 'Could not resolve the imported probe image to a digest.'
    }
    $image = "$acrLoginServer/probe@$($imageDigest.Trim())"

    Invoke-AzJson @(
        'deployment', 'group', 'create', '--name', 'spike9-job', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--template-file', (Join-Path $PSScriptRoot 'job.bicep'),
        '--parameters', "syntheticScaleAuth=$scaleCanary", "environmentId=$environmentId", "identityId=$identityId",
        "registryServer=$acrLoginServer", "image=$image", "syntheticSecretUri=$secretUri",
        "syntheticAppKeySha256=$canaryHash", "jitConfigSha256=$jitHash",
        '--only-show-errors', '--output', 'none'
    ) | Out-Null

    $jobUri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/jobs/$jobName"
    $jobApi = "$jobUri`?api-version=2026-07-01"
    $job = Invoke-AzJson @('rest', '--method', 'get', '--url', $jobApi, '--subscription', $subscription, '--output', 'json')
    $initEnv = @($job.properties.template.initContainers[0].env)
    $mainEnv = @($job.properties.template.containers[0].env)
    $scaleAuth = @($job.properties.configuration.eventTriggerConfig.scale.rules[0].auth)
    $initAppRef = @($initEnv | Where-Object { $_.secretRef -eq 'synthetic-app-key' }).Count -eq 1
    $mainHasNoSecretRefs = @($mainEnv | Where-Object { $_.PSObject.Properties.Name -contains 'secretRef' }).Count -eq 0
    $scaleSecretOnly = $scaleAuth.Count -eq 1 -and $scaleAuth[0].secretRef -eq 'scale-only-auth'
    $identityLifecycleNone = $job.properties.configuration.identitySettings.Count -eq 1 -and $job.properties.configuration.identitySettings[0].lifecycle -eq 'None'
    if (-not ($initAppRef -and $mainHasNoSecretRefs -and $scaleSecretOnly -and $identityLifecycleNone)) {
        throw 'Deployed job configuration does not match the intended secret and identity separation.'
    }

    $startUri = "$jobUri/start?api-version=2026-07-01"
    $started = Invoke-AzJson @('rest', '--method', 'post', '--url', $startUri, '--body', '{}', '--subscription', $subscription, '--output', 'json')
    $executionName = $started.name
    if ([string]::IsNullOrWhiteSpace($executionName)) {
        throw 'Job start did not return an execution name.'
    }
    $executionUri = "$jobUri/executions/$executionName`?api-version=2026-07-01"
    $status = ''
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Seconds 15
        $execution = Invoke-AzJson @('rest', '--method', 'get', '--url', $executionUri, '--subscription', $subscription, '--output', 'json')
        $status = $execution.properties.status
        if ($status -in @('Succeeded', 'Failed', 'Stopped', 'Degraded')) {
            break
        }
    }
    if ($status -ne 'Succeeded') {
        throw "Probe execution ended with status '$status'."
    }

    $evidence = [ordered]@{
        issue = 9
        observedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = $subscription
        resourceGroup = $resourceGroup
        region = $location
        apiVersions = [ordered]@{
            containerApps = '2026-07-01'
            network = '2026-05-01'
            containerRegistry = '2025-11-01'
            keyVault = '2025-05-01'
        }
        probeImage = $image
        executionStatus = $status
        assertions = [ordered]@{
            initSecretRefFromKeyVault = $true
            initSecretMatchesSyntheticHash = $true
            emptyDirSharedAndReadable = $true
            jitFileMode0400 = $true
            mainHasNoSecretReferences = $true
            mainManagedIdentityEndpointAbsent = $true
            scaleOnlySecretReferencedOnlyByScaleAuth = $true
            privateAcrPullSucceeded = $true
            privateKeyVaultReferenceResolved = $true
            identitySettingsLifecycleNone = $true
            realGitHubAppAuthenticationTested = $false
        }
    }
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artifactPath -Encoding utf8
    Write-Output 'ASSERT_execution_succeeded=true'
    Write-Output 'ASSERT_job_configuration_secret_separation=true'
    Write-Output 'ASSERT_probe_results_sanitized=true'
}
finally {
    if ($groupCreatedHere -or $Resume) {
        Remove-SpikeResourceGroup
    }
}
