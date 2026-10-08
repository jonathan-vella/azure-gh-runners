[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][switch]$ConfirmCoordinatorCleanupDirection
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Execution.psm1') -Force
Assert-SpikeSourceDisabled
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
Assert-SpikeManifest $manifest
if ($manifest.phase -ne 'active' -or $manifest.attempts -ne 0) {
    throw 'Supervisor requires the immutable original active envelope, before any create.'
}
$stop = [DateTimeOffset]::Parse($manifest.workDeadlineUtc)
while ([DateTimeOffset]::UtcNow -lt $stop) {
    $exists = Invoke-SpikeCommand @('group', 'exists', '--subscription', $manifest.subscription,
        '-n', $manifest.resourceGroup, '-o', 'json', '--only-show-errors')
    if ($exists -isnot [bool]) { throw 'Supervisor RG existence response invalid.' }
    if (-not $exists) {
        Write-Output 'RG absent; original supervisor ended without inferring identity, credential or GitHub cleanup.'
        return
    }
    $group = Invoke-SpikeCommand @('group', 'show', '--subscription', $manifest.subscription,
        '-n', $manifest.resourceGroup, '-o', 'json', '--only-show-errors')
    Assert-OwnedSpikeGroup $manifest $group
    Start-Sleep -Seconds ([int][Math]::Min(15, [Math]::Max(1, ($stop - [DateTimeOffset]::UtcNow).TotalSeconds)))
}
try {
    $exists = Invoke-SpikeCommand @('group', 'exists', '--subscription', $manifest.subscription,
        '-n', $manifest.resourceGroup, '-o', 'json', '--only-show-errors')
    if ($exists -isnot [bool]) { throw 'Supervisor RG existence response invalid.' }
    if ($exists) {
        try { Save-SpikeControllerEvidence $manifest "$ManifestPath.controller.json" }
        finally { Invoke-SpikeControllerCleanup $manifest }
    } else {
        Write-Output 'RG already absent. This supervisor does not infer GitHub cleanup or acceptance from Azure absence.'
    }
} finally {
    # Controller diagnostics/agent/key failures cannot skip exact-owned RG removal.
    Remove-OwnedSpike -Manifest $manifest -Path $ManifestPath
}
