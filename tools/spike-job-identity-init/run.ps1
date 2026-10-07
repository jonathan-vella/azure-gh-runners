param(
    [switch]$Resume,
    [string]$ProbeImageDigest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'harness-helpers.psm1') -Force
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$resourceGroup = 'rg-ghrunners-spike9-swc'
$managedResourceGroup = 'ME_ghr9-env_rg-ghrunners-spike9-swc_swedencentral'
$location = 'swedencentral'
$jobName = 'ghr9-secret-isolation'
$artifactPath = Join-Path $PSScriptRoot 'evidence.json'
$groupCreatedHere = $false
$secureParameterDirectory = $null
$secureParameterFiles = [System.Collections.Generic.List[string]]::new()
$ownershipTags = @{
    application = 'ghrunners'
    environment = 'spike'
    workload = 'gh-runners'
    owner = 'jonathan-vella'
    costcenter = 'platform-engineering'
    'tech-contact' = 'jonathan-vella'
    'technical-contact' = 'jonathan-vella'
    sla = 'development'
    'backup-policy' = 'none'
    'maint-window' = 'none'
    project = 'azure-gh-runners'
    issue = '9'
    purpose = 'init-container-secret-isolation-spike'
}

Assert-ProbeImageDigest -Digest $ProbeImageDigest

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

function New-RestrictedParametersFile {
    param([System.Collections.IDictionary]$Parameters)

    if ($null -eq $script:secureParameterDirectory) {
        $script:secureParameterDirectory = Join-Path $env:TEMP ("ghr9-" + [Guid]::NewGuid().ToString('N'))
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $directorySecurity = [Security.AccessControl.DirectorySecurity]::new()
        $directorySecurity.SetAccessRuleProtection($true, $false)
        $accessRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $null = $directorySecurity.AddAccessRule($accessRule)
        $null = [System.IO.Directory]::CreateDirectory($script:secureParameterDirectory)
        Set-Acl -LiteralPath $script:secureParameterDirectory -AclObject $directorySecurity
    }

    $path = Join-Path $script:secureParameterDirectory ([Guid]::NewGuid().ToString('N') + '.json')
    $script:secureParameterFiles.Add($path)
    $parameterFile = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{}
    }
    foreach ($name in $Parameters.Keys) {
        $parameterFile.parameters[$name] = @{ value = $Parameters[$name] }
    }
    $json = $parameterFile | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-BoundedDeployment {
    param(
        [string]$Name,
        [string]$TemplatePath,
        [string]$ParametersFile,
        [int]$TimeoutMinutes = 12
    )

    Invoke-AzText @(
        'deployment', 'group', 'create', '--name', $Name, '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--template-file', $TemplatePath, '--parameters', "@$ParametersFile",
        '--no-wait', '--only-show-errors', '--output', 'none'
    ) | Out-Null

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Invoke-AzText @(
            'deployment', 'group', 'show', '--name', $Name, '--resource-group', $resourceGroup, '--subscription', $subscription,
            '--query', 'properties.provisioningState', '--output', 'tsv'
        )
        if ($state.Trim() -in @('Succeeded', 'Failed', 'Canceled')) {
            Assert-DeploymentSucceeded -State $state.Trim()
            return Invoke-AzJson @(
                'deployment', 'group', 'show', '--name', $Name, '--resource-group', $resourceGroup, '--subscription', $subscription,
                '--query', 'properties.outputs', '--output', 'json'
            )
        }
        Start-Sleep -Seconds 15
    }

    try {
        Invoke-AzText @('deployment', 'group', 'cancel', '--name', $Name, '--resource-group', $resourceGroup, '--subscription', $subscription, '--output', 'none') | Out-Null
    } catch {
        throw "Deployment '$Name' exceeded its time limit and cancellation failed; resource cleanup will still run."
    }
    throw "Deployment '$Name' exceeded its $TimeoutMinutes minute time limit and was canceled."
}

function Remove-SecureParameterFiles {
    foreach ($path in $script:secureParameterFiles) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($script:secureParameterDirectory -and (Test-Path -LiteralPath $script:secureParameterDirectory)) {
        Remove-Item -LiteralPath $script:secureParameterDirectory -Recurse -Force
    }
    $script:secureParameterFiles.Clear()
    $script:secureParameterDirectory = $null
}

function Remove-SpikeResourceGroup {
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
        $expectedTags = $ownershipTags.Clone()
        $expectedTags['expiresOn'] = $group.tags.expiresOn
        if ($group.location -ne $location -or -not (Test-SpikeExpiryTag -Value $group.tags.expiresOn) -or
            -not (Test-SpikeResourceGroupTags -Tags $group.tags -ExpectedTags $expectedTags)) {
            throw 'Refusing cleanup because the resource group does not carry the complete issue 9 ownership tag contract.'
        }

        $resources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--query', '[].{id:id,name:name,type:type}', '--output', 'json')
        if (-not (Test-SpikeResourceInventory -Resources $resources)) {
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
        $expectedTags = $ownershipTags.Clone()
        $expectedTags['expiresOn'] = $existingGroup.tags.expiresOn
        if ($existingGroup.location -ne $location -or -not (Test-SpikeExpiryTag -Value $existingGroup.tags.expiresOn) -or
            -not (Test-SpikeResourceGroupTags -Tags $existingGroup.tags -ExpectedTags $expectedTags)) {
            throw 'Existing resource group does not match the isolated issue 9 spike.'
        }
        if ([DateTimeOffset]::Parse($existingGroup.tags.expiresOn).UtcDateTime -le [DateTime]::UtcNow) {
            throw 'Existing issue 9 spike resource group has expired and cannot be resumed.'
        }
        $groupResources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--output', 'json')
        if (@($groupResources).Count -gt 0) {
            throw 'Resume requires an empty spike resource group.'
        }
    } else {
        $expiry = [DateTime]::UtcNow.AddMinutes(40).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $groupTags = @{}
        foreach ($tagName in $ownershipTags.Keys) {
            $groupTags[$tagName] = $ownershipTags[$tagName]
        }
        $groupTags.expiresOn = $expiry
        $tagArguments = @()
        foreach ($tagName in $groupTags.Keys) {
            $tagArguments += "$tagName=$($groupTags[$tagName])"
        }
        $createGroupArguments = @(
            'group', 'create', '--name', $resourceGroup, '--location', $location, '--subscription', $subscription,
            '--tags'
        ) + $tagArguments + @('--output', 'none')
        $groupCreatedHere = $true
        Invoke-AzText $createGroupArguments | Out-Null
    }

    $canary = New-SyntheticValue
    $canaryBytes = [Text.Encoding]::UTF8.GetBytes($canary)
    $canaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canaryBytes)).ToLowerInvariant()
    $scaleCanary = New-SyntheticValue
    $jitConfig = 'synthetic-jit-config'
    $jitHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jitConfig))).ToLowerInvariant()
    $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
    $expiry = $group.tags.expiresOn

    $infraParametersFile = New-RestrictedParametersFile @{
        syntheticAppKey = $canary
        expiry = $expiry
    }
    try {
        $infraOutputs = Invoke-BoundedDeployment -Name 'spike9-infra' -TemplatePath (Join-Path $PSScriptRoot 'main.bicep') -ParametersFile $infraParametersFile
    } finally {
        if (Test-Path -LiteralPath $infraParametersFile) {
            Remove-Item -LiteralPath $infraParametersFile -Force
        }
    }
    $acrName = $infraOutputs.acrName.value
    $acrLoginServer = $infraOutputs.acrLoginServer.value
    $identityId = $infraOutputs.identityId.value
    $environmentId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/managedEnvironments/$($infraOutputs.environmentName.value)"
    $secretUri = $infraOutputs.syntheticSecretUri.value
    if ([string]::IsNullOrWhiteSpace($acrName) -or [string]::IsNullOrWhiteSpace($identityId) -or [string]::IsNullOrWhiteSpace($secretUri)) {
        throw 'Infrastructure deployment omitted a required non-secret output.'
    }

    $image = "$acrLoginServer/probe@$ProbeImageDigest"
    $scaleCanaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($scaleCanary))).ToLowerInvariant()
    $jobParametersFile = New-RestrictedParametersFile @{
        syntheticScaleAuth = $scaleCanary
        syntheticScaleAuthSha256 = $scaleCanaryHash
        environmentId = $environmentId
        identityId = $identityId
        registryServer = $acrLoginServer
        image = $image
        syntheticSecretUri = $secretUri
        syntheticAppKeySha256 = $canaryHash
        jitConfigSha256 = $jitHash
        expiry = $expiry
    }
    try {
        $null = Invoke-BoundedDeployment -Name 'spike9-job' -TemplatePath (Join-Path $PSScriptRoot 'job.bicep') -ParametersFile $jobParametersFile -TimeoutMinutes 5
    } finally {
        if (Test-Path -LiteralPath $jobParametersFile) {
            Remove-Item -LiteralPath $jobParametersFile -Force
        }
    }

    $jobUri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/jobs/$jobName"
    $jobApi = "$jobUri`?api-version=2026-07-01"
    $job = Invoke-AzJson @('rest', '--method', 'get', '--url', $jobApi, '--subscription', $subscription, '--output', 'json')
    $initEnv = @($job.properties.template.initContainers[0].env)
    $mainEnv = @($job.properties.template.containers[0].env)
    $containerEnvLines = @($initEnv + $mainEnv | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'value') {
            "$($_.name)=$($_.value)"
        }
    })
    $scaleAuth = @($job.properties.configuration.eventTriggerConfig.scale.rules[0].auth)
    $initAppRef = @($initEnv | Where-Object { $_.secretRef -eq 'synthetic-app-key' }).Count -eq 1
    $initHasNoOtherSecretRefs = @($initEnv | Where-Object {
        $_.PSObject.Properties.Name -contains 'secretRef' -and $_.secretRef -ne 'synthetic-app-key'
    }).Count -eq 0
    $mainHasNoSecretRefs = @($mainEnv | Where-Object { $_.PSObject.Properties.Name -contains 'secretRef' }).Count -eq 0
    $scaleSecretOnly = $scaleAuth.Count -eq 1 -and $scaleAuth[0].secretRef -eq 'scale-only-auth'
    $scaleCanaryNotInConfigEnv = -not (Test-CanaryHashLeak -EnvironmentLines $containerEnvLines -CanaryHash $scaleCanaryHash)
    $appKeyNotInConfigEnv = -not (Test-CanaryHashLeak -EnvironmentLines $containerEnvLines -CanaryHash $canaryHash)
    $identityLifecycleNone = $job.properties.configuration.identitySettings.Count -eq 1 -and $job.properties.configuration.identitySettings[0].lifecycle -eq 'None'
    if (-not ($initAppRef -and $initHasNoOtherSecretRefs -and $mainHasNoSecretRefs -and $scaleSecretOnly -and
        $scaleCanaryNotInConfigEnv -and $appKeyNotInConfigEnv -and $identityLifecycleNone)) {
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
    if ($status -notin @('Succeeded', 'Failed', 'Stopped', 'Degraded')) {
        $stopUri = "$jobUri/executions/$executionName/stop?api-version=2026-07-01"
        Invoke-AzText @('rest', '--method', 'post', '--url', $stopUri, '--subscription', $subscription, '--output', 'none') | Out-Null
        throw 'Probe execution exceeded its ten-minute wait and a stop was requested.'
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
            keyVault = '2026-05-15'
        }
        probeImage = $image
        executionStatus = $status
        assertions = [ordered]@{
            initSecretRefFromKeyVault = $true
            initSecretMatchesSyntheticHash = $true
            emptyDirSharedAndReadable = $true
            jitFileMode0400 = $true
            jitFileOwnedByUid65532 = $true
            mainRunningAsUid65532 = $true
            mainCanReadAndDeleteJitFile = $true
            mainHasNoSecretReferences = $true
            mainManagedIdentityEndpointAbsent = $true
            mainManagedIdentityTokenRequestDenied = $true
            appKeyAndScaleCanaryValuesAbsentFromMainEnvironment = $true
            scaleOnlySecretReferencedOnlyByScaleAuth = $true
            scaleCanaryValueAbsentFromInitEnvironment = $true
            diagnosticNsgDeniesRfc1918LateralTraffic = $true
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
    try {
        Remove-SecureParameterFiles
    } finally {
        if ($groupCreatedHere -or $Resume) {
            Remove-SpikeResourceGroup
        }
    }
}
