param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Test', 'Cleanup')]
    [string]$Mode,
    [string]$ProbeImageDigest,
    [string]$ImageTransferReceipt,
    [switch]$ConfirmCapacityRecovered
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'harness-helpers.psm1') -Force
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$resourceGroup = 'rg-ghrunners-spike9-swc'
$managedResourceGroup = 'ME_ghr9-env_rg-ghrunners-spike9-swc_swedencentral'
$location = 'swedencentral'
$jobName = 'ghr9-secret-isolation'
$preparedManifest = Join-Path $PSScriptRoot 'prepared.json'
$artifactPath = Join-Path $PSScriptRoot 'evidence.json'
$groupCreatedHere = $false
$preservePreparedGroup = $false
$cleanupOnExit = $false
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

function Invoke-AzText {
    param([string[]]$Arguments)

    $az = (Get-Command az -ErrorAction Stop).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $az
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $errorCode = Get-SanitizedAzureErrorCode -Diagnostics "$stdout`n$stderr"
        throw "Azure CLI command failed (exit=$($process.ExitCode); errorCode=$errorCode)."
    }
    return $stdout.TrimEnd()
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
        throw "Deployment '$Name' exceeded its time limit; cancellation failed and cleanup will still run."
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

function Get-SpikeResourceGroup {
    param([switch]$AllowExpired)

    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -ne 'true') {
        throw "Issue-9 resource group '$resourceGroup' does not exist."
    }
    $group = Invoke-AzJson @('group', 'show', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'json')
    $expectedTags = $ownershipTags.Clone()
    $expectedTags['expiresOn'] = $group.tags.expiresOn
    if ($group.location -ne $location -or -not (Test-SpikeExpiryTag -Value $group.tags.expiresOn) -or
        -not (Test-SpikeResourceGroupTags -Tags $group.tags -ExpectedTags $expectedTags)) {
        throw 'Resource group does not match the approved issue-9 ownership and region contract.'
    }
    if (-not $AllowExpired -and [DateTimeOffset]::Parse($group.tags.expiresOn).UtcDateTime -le [DateTime]::UtcNow) {
        throw 'Issue-9 resource group has expired.'
    }
    return $group
}

function Remove-SpikeResourceGroup {
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        $group = Get-SpikeResourceGroup -AllowExpired
        $resources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--query', '[].{id:id,name:name,type:type}', '--output', 'json')
        if (-not (Test-SpikeResourceInventory -Resources $resources)) {
            throw 'Refusing cleanup because the resource group contains an unrecognized resource.'
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
            if (Test-Path -LiteralPath $preparedManifest) {
                Remove-Item -LiteralPath $preparedManifest -Force
            }
            Write-Output 'ASSERT_cleanup_resource_group_absent=true'
            Write-Output 'ASSERT_aca_managed_resource_group_absent=true'
            return
        }
        Start-Sleep -Seconds 10
    }
    throw "ACA-managed resource group '$managedResourceGroup' remains after deleting the spike environment."
}

function New-SpikeResourceGroup {
    $exists = Invoke-AzText @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--output', 'tsv')
    if ($exists.Trim() -eq 'true') {
        throw 'Prepare requires the issue-9 resource group to be absent; use Cleanup only for a verified issue-9-owned group.'
    }
    $expiry = [DateTime]::UtcNow.AddMinutes(45).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $tags = $ownershipTags.Clone()
    $tags.expiresOn = $expiry
    $tagArguments = @()
    foreach ($tagName in $tags.Keys) {
        $tagArguments += "$tagName=$($tags[$tagName])"
    }
    $arguments = @(
        'group', 'create', '--name', $resourceGroup, '--location', $location, '--subscription', $subscription, '--tags'
    ) + $tagArguments + @('--output', 'none')
    $script:groupCreatedHere = $true
    Invoke-AzText $arguments | Out-Null
    return $expiry
}

function Assert-PreparedResources {
    param([object]$Manifest)

    $group = Get-SpikeResourceGroup
    if ($group.tags.expiresOn -cne $Manifest.expiresOn -or
        $Manifest.subscriptionId -cne $subscription -or
        $Manifest.resourceGroup -cne $resourceGroup -or
        $Manifest.region -cne $location) {
        throw 'Prepared manifest does not match the live issue-9 resource group.'
    }
    $resources = Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup, '--subscription', $subscription, '--query', '[].{id:id,name:name,type:type}', '--output', 'json')
    if (-not (Test-SpikeResourceInventory -Resources $resources)) {
        throw 'Prepared resource group contains an unrecognized resource.'
    }
    $acr = Invoke-AzJson @('resource', 'show', '--ids', $Manifest.registryId, '--api-version', '2025-11-01', '--subscription', $subscription, '--output', 'json')
    $vault = Invoke-AzJson @('resource', 'show', '--ids', $Manifest.vaultId, '--api-version', '2026-05-15', '--subscription', $subscription, '--output', 'json')
    $identity = Invoke-AzJson @('resource', 'show', '--ids', $Manifest.identityId, '--api-version', '2024-11-30', '--subscription', $subscription, '--output', 'json')
    $vnet = Invoke-AzJson @('resource', 'show', '--ids', $Manifest.vnetId, '--api-version', '2026-05-01', '--subscription', $subscription, '--output', 'json')
    $subnets = Invoke-AzJson @('network', 'vnet', 'subnet', 'list', '--resource-group', $resourceGroup, '--vnet-name', 'ghr9-vnet', '--subscription', $subscription, '--output', 'json')
    $acrEndpoint = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateEndpoints' -and $_.name -eq 'ghr9-acr-pe' })
    $vaultEndpoint = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateEndpoints' -and $_.name -eq 'ghr9-vault-pe' })
    $acrRoles = @($resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.id -match '/registries/ghr9[^/]*?/providers/Microsoft.Authorization/roleAssignments/' })
    $vaultRoles = @($resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.id -match '/vaults/ghr9kv[^/]*?/providers/Microsoft.Authorization/roleAssignments/' })
    $acaSubnet = @($subnets | Where-Object { $_.name -eq 'aca' })
    $privateEndpointSubnet = @($subnets | Where-Object { $_.name -eq 'private-endpoints' })
    if ($acr.name -cne $Manifest.registryName -or $acr.properties.publicNetworkAccess -cne 'Disabled' -or
        $acr.properties.networkRuleBypassOptions -cne 'None' -or $acr.sku.name -cne 'Premium' -or
        $vault.id -cne $Manifest.vaultId -or $vault.properties.publicNetworkAccess -cne 'Disabled' -or
        $identity.id -cne $Manifest.identityId -or $vnet.id -cne $Manifest.vnetId -or
        $acrEndpoint.Count -ne 1 -or $vaultEndpoint.Count -ne 1 -or $acaSubnet.Count -ne 1 -or
        $privateEndpointSubnet.Count -ne 1 -or
        $acaSubnet[0].id -cne $Manifest.acaSubnetId -or
        $privateEndpointSubnet[0].id -cne $Manifest.privateEndpointSubnetId -or
        $acaSubnet[0].delegations[0].serviceName -cne 'Microsoft.App/environments' -or
        $privateEndpointSubnet[0].privateEndpointNetworkPolicies -cne 'Disabled' -or
        $acrRoles.Count -ne 1 -or $vaultRoles.Count -ne 1) {
        throw 'Live ACR, Key Vault, identity, or private endpoint settings do not match the prepared manifest.'
    }
    $acrRole = Invoke-AzJson @('resource', 'show', '--ids', $acrRoles[0].id, '--api-version', '2022-04-01', '--subscription', $subscription, '--output', 'json')
    $vaultRole = Invoke-AzJson @('resource', 'show', '--ids', $vaultRoles[0].id, '--api-version', '2022-04-01', '--subscription', $subscription, '--output', 'json')
    if ($acrRole.properties.principalId -cne $identity.properties.principalId -or
        $acrRole.properties.roleDefinitionId -notmatch '/7f951dda-4ed3-4680-a7ca-43fe172d538d$' -or
        $vaultRole.properties.principalId -cne $identity.properties.principalId -or
        $vaultRole.properties.roleDefinitionId -notmatch '/4633458b-17de-408a-b874-0445c86b69e6$') {
        throw 'Live identity role assignments do not match the exact ACR pull and Key Vault secrets roles.'
    }
    foreach ($endpointResource in @(
            @{ Resource = $acrEndpoint[0]; ExpectedTarget = $Manifest.registryId },
            @{ Resource = $vaultEndpoint[0]; ExpectedTarget = $Manifest.vaultId }
        )) {
        $endpoint = Invoke-AzJson @('resource', 'show', '--ids', $endpointResource.Resource.id, '--api-version', '2026-05-01', '--subscription', $subscription, '--output', 'json')
        $connection = $endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState
        if ($connection.status -cne 'Approved' -or
            $endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId -cne $endpointResource.ExpectedTarget -or
            $endpoint.properties.subnet.id -cne $Manifest.privateEndpointSubnetId) {
            throw 'A prepared private endpoint is not approved for its expected private resource.'
        }
    }
}

function Invoke-Prepare {
    $expiry = New-SpikeResourceGroup
    $canary = New-SyntheticValue
    $parametersFile = New-RestrictedParametersFile @{
        syntheticAppKey = $canary
        expiry = $expiry
    }
    try {
        $outputs = Invoke-BoundedDeployment -Name 'spike9-infra' -TemplatePath (Join-Path $PSScriptRoot 'main.bicep') -ParametersFile $parametersFile -TimeoutMinutes 20
    } finally {
        if (Test-Path -LiteralPath $parametersFile) {
            Remove-Item -LiteralPath $parametersFile -Force
        }
    }
    $manifest = [ordered]@{
        issue = 9
        subscriptionId = $subscription
        resourceGroup = $resourceGroup
        region = $location
        expiresOn = $expiry
        registryName = $outputs.acrName.value
        registryLoginServer = $outputs.acrLoginServer.value
        registryId = $outputs.acrId.value
        vaultId = $outputs.vaultId.value
        identityId = $outputs.identityId.value
        vnetId = $outputs.vnetId.value
        acaSubnetId = $outputs.acaSubnetId.value
        privateEndpointSubnetId = $outputs.privateEndpointSubnetId.value
        syntheticSecretUri = $outputs.syntheticSecretUri.value
        preparedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ([string]::IsNullOrWhiteSpace($manifest.registryId) -or
        [string]::IsNullOrWhiteSpace($manifest.identityId) -or
        [string]::IsNullOrWhiteSpace($manifest.syntheticSecretUri)) {
        throw 'Infrastructure deployment omitted a required non-secret output.'
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $preparedManifest -Encoding utf8
    $script:preservePreparedGroup = $true
    Write-Output "Prepared issue-9 resources in $resourceGroup."
    Write-Output "ASSERT_aca_environment_not_created=true"
    Write-Output 'Next: use only the approved issue-6 private transfer path to preload this exact ACR, then run Test with its readback receipt.'
}

function Invoke-Test {
    Assert-CapacityRecovered -Confirmed ([bool]$ConfirmCapacityRecovered)
    $script:cleanupOnExit = $true
    if (-not (Test-Path -LiteralPath $preparedManifest)) {
        throw 'Prepared manifest is missing. Run Prepare, then complete private image transfer before Test.'
    }
    if ([string]::IsNullOrWhiteSpace($ImageTransferReceipt) -or -not (Test-Path -LiteralPath $ImageTransferReceipt)) {
        throw 'Test requires the receipt produced after private transfer and digest readback in the issue-9 ACR.'
    }
    Assert-ProbeImageDigest -Digest $ProbeImageDigest
    $manifest = Get-Content -LiteralPath $preparedManifest -Raw | ConvertFrom-Json
    $receipt = Get-Content -LiteralPath $ImageTransferReceipt -Raw | ConvertFrom-Json
    Assert-PreparedResources -Manifest $manifest
    Assert-ImageTransferReceipt -Receipt $receipt -SubscriptionId $subscription -ResourceGroup $resourceGroup -RegistryName $manifest.registryName -Digest $ProbeImageDigest
    if (Test-Path -LiteralPath $artifactPath) {
        Remove-Item -LiteralPath $artifactPath -Force
    }

    $expiry = $manifest.expiresOn
    $environmentParametersFile = New-RestrictedParametersFile @{
        expiry = $expiry
        subnetId = $manifest.acaSubnetId
    }
    try {
        $environmentOutputs = Invoke-BoundedDeployment -Name 'spike9-environment' -TemplatePath (Join-Path $PSScriptRoot 'environment.bicep') -ParametersFile $environmentParametersFile -TimeoutMinutes 12
    } finally {
        if (Test-Path -LiteralPath $environmentParametersFile) {
            Remove-Item -LiteralPath $environmentParametersFile -Force
        }
    }

    $canary = New-SyntheticValue
    $canaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canary))).ToLowerInvariant()
    $scaleCanary = New-SyntheticValue
    $scaleCanaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($scaleCanary))).ToLowerInvariant()
    $jitConfig = 'synthetic-jit-config'
    $jitHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jitConfig))).ToLowerInvariant()
    $image = "$($manifest.registryLoginServer)/probe@$ProbeImageDigest"
    $jobParametersFile = New-RestrictedParametersFile @{
        syntheticAppKey = $canary
        syntheticScaleAuth = $scaleCanary
        syntheticScaleAuthSha256 = $scaleCanaryHash
        environmentId = $environmentOutputs.environmentId.value
        identityId = $manifest.identityId
        registryServer = $manifest.registryLoginServer
        image = $image
        syntheticSecretUri = $manifest.syntheticSecretUri
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

try {
    switch ($Mode) {
        'Prepare' {
            Invoke-Prepare
        }
        'Test' {
            Invoke-Test
        }
        'Cleanup' {
            Remove-SpikeResourceGroup
        }
    }
} finally {
    try {
        Remove-SecureParameterFiles
    } finally {
        if (($groupCreatedHere -and -not $preservePreparedGroup) -or $cleanupOnExit) {
            Remove-SpikeResourceGroup
        }
    }
}
