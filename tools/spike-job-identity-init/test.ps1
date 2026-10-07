$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'harness-helpers.psm1') -Force

$expectedTags = @{
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
    expiresOn = '2026-10-07T16:48:22Z'
}
$validTags = [pscustomobject]$expectedTags
if (-not (Test-SpikeResourceGroupTags -Tags $validTags -ExpectedTags $expectedTags)) {
    throw 'Unit test failed: approved ownership tags were rejected.'
}
$validTags | Add-Member -NotePropertyName owner -NotePropertyValue 'unexpected' -Force
if (Test-SpikeResourceGroupTags -Tags $validTags -ExpectedTags $expectedTags) {
    throw 'Unit test failed: mismatched ownership tags were accepted.'
}
$validTags | Add-Member -NotePropertyName owner -NotePropertyValue 'JONATHAN-VELLA' -Force
if (Test-SpikeResourceGroupTags -Tags $validTags -ExpectedTags $expectedTags) {
    throw 'Unit test failed: case-mismatched ownership tags were accepted.'
}
if (-not (Test-SpikeExpiryTag -Value '2026-10-07T16:48:22Z') -or (Test-SpikeExpiryTag -Value 'not-an-expiry')) {
    throw 'Unit test failed: expiry ownership tag validation is incorrect.'
}

$knownResources = @(
    [pscustomobject]@{ name = 'ghr9-vnet'; type = 'Microsoft.Network/virtualNetworks'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/ghr9-vnet' },
    [pscustomobject]@{ name = 'ghr9-env'; type = 'Microsoft.App/managedEnvironments'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/ghr9-env' },
    [pscustomobject]@{ name = 'ghr9-secret-isolation'; type = 'Microsoft.App/jobs'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/jobs/ghr9-secret-isolation' },
    [pscustomobject]@{ name = 'ghr9-secret-isolation/execution-123'; type = 'Microsoft.App/jobs/executions'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/jobs/ghr9-secret-isolation/executions/execution-123' },
    [pscustomobject]@{ name = 'ghr9abc123'; type = 'Microsoft.ContainerRegistry/registries'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/ghr9abc123' },
    [pscustomobject]@{ name = 'ghr9kvabc123'; type = 'Microsoft.KeyVault/vaults'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/ghr9kvabc123' },
    [pscustomobject]@{ name = 'ghr9kvabc123/synthetic-app-key'; type = 'Microsoft.KeyVault/vaults/secrets'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/ghr9kvabc123/secrets/synthetic-app-key' },
    [pscustomobject]@{ name = 'ghr9-job-identity'; type = 'Microsoft.ManagedIdentity/userAssignedIdentities'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ghr9-job-identity' },
    [pscustomobject]@{ name = 'ghr9-aca-nsg'; type = 'Microsoft.Network/networkSecurityGroups'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/ghr9-aca-nsg' },
    [pscustomobject]@{ name = 'ghr9-nat'; type = 'Microsoft.Network/natGateways'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/natGateways/ghr9-nat' },
    [pscustomobject]@{ name = 'ghr9-acr-pe'; type = 'Microsoft.Network/privateEndpoints'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/ghr9-acr-pe' },
    [pscustomobject]@{ name = 'ghr9-acr-pe/default'; type = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/ghr9-acr-pe/privateDnsZoneGroups/default' },
    [pscustomobject]@{ name = 'ghr9-vault-pe'; type = 'Microsoft.Network/privateEndpoints'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/ghr9-vault-pe' },
    [pscustomobject]@{ name = 'ghr9-vault-pe/default'; type = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/ghr9-vault-pe/privateDnsZoneGroups/default' },
    [pscustomobject]@{ name = 'ghr9-nat-pip'; type = 'Microsoft.Network/publicIPAddresses'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/ghr9-nat-pip' },
    [pscustomobject]@{ name = 'ghr9-vnet/aca'; type = 'Microsoft.Network/virtualNetworks/subnets'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/ghr9-vnet/subnets/aca' },
    [pscustomobject]@{ name = 'ghr9-vnet/private-endpoints'; type = 'Microsoft.Network/virtualNetworks/subnets'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/ghr9-vnet/subnets/private-endpoints' },
    [pscustomobject]@{ name = 'privatelink.azurecr.io'; type = 'Microsoft.Network/privateDnsZones'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io' },
    [pscustomobject]@{ name = 'privatelink.vaultcore.azure.net'; type = 'Microsoft.Network/privateDnsZones'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net' },
    [pscustomobject]@{ name = 'privatelink.azurecr.io/ghr9-vnet-link'; type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io/virtualNetworkLinks/ghr9-vnet-link' },
    [pscustomobject]@{ name = 'privatelink.vaultcore.azure.net/ghr9-vnet-link'; type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net/virtualNetworkLinks/ghr9-vnet-link' },
    [pscustomobject]@{ name = 'role-id'; type = 'Microsoft.Authorization/roleAssignments'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/ghr9abc/providers/Microsoft.Authorization/roleAssignments/role-id' }
)
if (-not (Test-SpikeResourceInventory -Resources $knownResources)) {
    throw 'Unit test failed: known spike resources were rejected.'
}
$unknownResources = $knownResources + @(
    [pscustomobject]@{ name = 'production-resource'; type = 'Microsoft.Storage/storageAccounts'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/production-resource' }
)
if (Test-SpikeResourceInventory -Resources $unknownResources) {
    throw 'Unit test failed: unknown resource inventory was accepted.'
}
$unexpectedGhr9Resource = @([pscustomobject]@{ name = 'ghr9-unexpected'; type = 'Microsoft.Storage/storageAccounts'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/ghr9-unexpected' })
if (Test-SpikeResourceInventory -Resources $unexpectedGhr9Resource) {
    throw 'Unit test failed: unrecognized ghr9-prefixed resource was accepted.'
}
$unrelatedJob = @([pscustomobject]@{ name = 'ghr9-unrelated-job'; type = 'Microsoft.App/jobs'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/jobs/ghr9-unrelated-job' })
if (Test-SpikeResourceInventory -Resources $unrelatedJob) {
    throw 'Unit test failed: an unrelated Container Apps job was accepted for cleanup.'
}

$sampleCanary = 'synthetic-app-key'
$sampleCanaryHash = Get-Sha256Hex -Value $sampleCanary
Assert-Sha256Hex -Value $sampleCanaryHash
$badCanaryHashRejected = $false
try {
    Assert-Sha256Hex -Value 'not-a-hash'
} catch {
    $badCanaryHashRejected = $true
}
if (-not $badCanaryHashRejected) {
    throw 'Unit test failed: malformed canary hash was accepted.'
}

$jobParameterNames = @(
    'syntheticScaleAuth',
    'syntheticScaleAuthSha256',
    'environmentId',
    'identityId',
    'registryServer',
    'image',
    'syntheticSecretUri',
    'syntheticAppKeySha256',
    'jitConfigSha256',
    'expiry'
)
$jobTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'job.bicep') -Raw
Assert-DeclaredBicepParameters -TemplateContent $jobTemplate -ParameterNames $jobParameterNames
$undeclaredJobParameterRejected = $false
try {
    Assert-DeclaredBicepParameters -TemplateContent $jobTemplate -ParameterNames ($jobParameterNames + 'syntheticAppKey')
} catch {
    $undeclaredJobParameterRejected = $true
}
if (-not $undeclaredJobParameterRejected) {
    throw 'Unit test failed: an undeclared job deployment parameter was accepted.'
}

$mainTemplateJson = az bicep build --file (Join-Path $PSScriptRoot 'main.bicep') --stdout | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unit test failed: main spike Bicep template could not be compiled for NSG assertions.'
}
$nsgResource = @($mainTemplateJson.resources | Where-Object { $_.type -eq 'Microsoft.Network/networkSecurityGroups' -and $_.name -eq 'ghr9-aca-nsg' })
if ($nsgResource.Count -ne 1) {
    throw 'Unit test failed: expected exactly one diagnostic ACA NSG in the compiled template.'
}
Assert-AcaPeerRules -Rules $nsgResource[0].properties.securityRules
$unsafePeerRules = @($nsgResource[0].properties.securityRules | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
$unsafePeerRules | Where-Object { $_.name -eq 'allow-aca-subnet-peer-ingress' } | ForEach-Object { $_.properties.sourceAddressPrefix = '10.0.0.0/8' }
$unsafePeerRuleRejected = $false
try {
    Assert-AcaPeerRules -Rules $unsafePeerRules
} catch {
    $unsafePeerRuleRejected = $true
}
if (-not $unsafePeerRuleRejected) {
    throw 'Unit test failed: broad RFC1918 ACA peer allowance was accepted.'
}

$fakeClock = [pscustomobject]@{ now = [DateTime]::UtcNow }
$fakeStart = $fakeClock.now
$observedTimeouts = [System.Collections.Generic.List[int]]::new()
$deadlineRejected = $false
try {
    Invoke-DeadlinePoll -Deadline $fakeClock.now.AddSeconds(10) -TimeoutMessage 'test deadline' -PollIntervalSeconds 1 -Clock {
        $fakeClock.now
    } -Sleeper {
        param($seconds)
        $fakeClock.now = $fakeClock.now.AddSeconds($seconds)
    } -Action {
        param($remaining)
        $observedTimeouts.Add($remaining)
        $fakeClock.now = $fakeClock.now.AddSeconds([Math]::Min(3, $remaining))
        'StillRunning'
    } -IsComplete {
        param($result)
        $result -eq 'Succeeded'
    }
} catch {
    $deadlineRejected = $_.Exception.Message -eq 'test deadline'
}
if (-not $deadlineRejected -or $fakeClock.now -ne $fakeStart.AddSeconds(10) -or
    $observedTimeouts.Count -ne 3 -or $observedTimeouts[2] -ne 2) {
    throw 'Unit test failed: polling did not enforce remaining wall-clock budget across slow calls.'
}

$canaryValue = 'synthetic-scale-canary'
$canaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canaryValue))).ToLowerInvariant()
if (-not (Test-CanaryHashLeak -EnvironmentLines @('PATH=/usr/bin', "UNEXPECTED=$canaryValue") -CanaryHash $canaryHash)) {
    throw 'Unit test failed: canary hash leak was missed.'
}
if (Test-CanaryHashLeak -EnvironmentLines @('PATH=/usr/bin', 'TOKEN=unrelated') -CanaryHash $canaryHash) {
    throw 'Unit test failed: clean environment was reported as a canary leak.'
}

Assert-DeploymentSucceeded -State 'Succeeded'
$failedStateRejected = $false
try {
    Assert-DeploymentSucceeded -State 'Failed'
} catch {
    $failedStateRejected = $true
}
if (-not $failedStateRejected) {
    throw 'Unit test failed: failed deployment state was accepted.'
}

$missingDigestRejected = $false
try {
    Assert-ProbeImageDigest -Digest ''
} catch {
    $missingDigestRejected = $true
}
if (-not $missingDigestRejected) {
    throw 'Unit test failed: missing probe digest was accepted.'
}
$invalidDigestRejected = $false
try {
    Assert-ProbeImageDigest -Digest 'latest'
} catch {
    $invalidDigestRejected = $true
}
if (-not $invalidDigestRejected) {
    throw 'Unit test failed: mutable image tag was accepted.'
}
Assert-ProbeImageDigest -Digest ('sha256:' + ('a' * 64))

Assert-CapacityRecovered -Confirmed $true
$capacityGateRejected = $false
try {
    Assert-CapacityRecovered -Confirmed $false
} catch {
    $capacityGateRejected = $true
}
if (-not $capacityGateRejected) {
    throw 'Unit test failed: ACA test was allowed without capacity recovery confirmation.'
}
if ((Get-SanitizedAzureErrorCode -Diagnostics 'Error: AKSCapacityHeavyUsage; credential=must-not-appear') -cne 'AKSCapacityHeavyUsage' -or
    (Get-SanitizedAzureErrorCode -Diagnostics 'credential=must-not-appear') -cne 'unclassified') {
    throw 'Unit test failed: Azure CLI error sanitization did not use the allowlist.'
}
$sleeper = [Diagnostics.Process]::new()
$sleeper.StartInfo = [Diagnostics.ProcessStartInfo]::new()
$sleeper.StartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
$sleeper.StartInfo.ArgumentList.Add('-NoProfile')
$sleeper.StartInfo.ArgumentList.Add('-Command')
$sleeper.StartInfo.ArgumentList.Add('Start-Sleep -Seconds 30')
$null = $sleeper.Start()
$timedOutProcessRejected = $false
try {
    if (Wait-ProcessBounded -Process $sleeper -TimeoutSeconds 1) {
        throw 'Unit test failed: a sleeping process was reported as completed.'
    }
    $timedOutProcessRejected = $sleeper.HasExited
} finally {
    if (-not $sleeper.HasExited) {
        $sleeper.Kill($true)
        $sleeper.WaitForExit(5000) | Out-Null
    }
    $sleeper.Dispose()
}
if (-not $timedOutProcessRejected) {
    throw 'Unit test failed: timed-out process was not terminated.'
}

$receipt = [pscustomobject]@{
    issue = 9
    subscriptionId = 'subscription-id'
    resourceGroup = 'rg-ghrunners-spike9-swc'
    registryName = 'ghr9registry'
    repository = 'probe'
    digest = 'sha256:' + ('a' * 64)
    destinationDigestReadBack = 'sha256:' + ('a' * 64)
    privateEndpointApproved = $true
    sourcePath = 'issue-6-private-agent-pool-transfer'
    verifiedBy = 'operator'
    verifiedAtUtc = '2026-10-07T16:48:22Z'
}
Assert-ImageTransferReceipt -Receipt $receipt -SubscriptionId 'subscription-id' -ResourceGroup 'rg-ghrunners-spike9-swc' -RegistryName 'ghr9registry' -Digest $receipt.digest
$receipt.destinationDigestReadBack = 'sha256:' + ('b' * 64)
$receiptRejected = $false
try {
    Assert-ImageTransferReceipt -Receipt $receipt -SubscriptionId 'subscription-id' -ResourceGroup 'rg-ghrunners-spike9-swc' -RegistryName 'ghr9registry' -Digest ('sha256:' + ('a' * 64))
} catch {
    $receiptRejected = $true
}
if (-not $receiptRejected) {
    throw 'Unit test failed: mismatched destination digest receipt was accepted.'
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw 'Python 3 is required to validate the main-container probe.'
}
Push-Location $PSScriptRoot
try {
    & $python.Source -B -m unittest -v test_main_probe.py
    if ($LASTEXITCODE -ne 0) {
        throw 'Main-container probe unit tests failed.'
    }
} finally {
    Pop-Location
}

foreach ($templateName in @('main.bicep', 'environment.bicep', 'job.bicep')) {
    $templatePath = Join-Path $PSScriptRoot $templateName
    az bicep build --file $templatePath --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Spike template build failed: $templateName"
    }
}

Write-Output 'Spike harness unit tests passed.'
