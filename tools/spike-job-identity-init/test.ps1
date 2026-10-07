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
    [pscustomobject]@{ name = 'privatelink.azurecr.io'; type = 'Microsoft.Network/privateDnsZones'; id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io' },
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
