[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Inspect', 'Cleanup')][string]$Action,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$Head,
    [switch]$ConfirmCoordinatorCleanupDirection
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
$path = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)) -PathType Container)) {
    throw 'Manifest parent directory must already exist outside committed artifacts.'
}
$lock = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ($Action -eq 'Prepare') {
        if (Test-Path -LiteralPath $path) { throw 'Manifest already exists; do not reset run history.' }
        Write-SpikeManifest -Manifest (New-SpikeManifest -Head $Head) -Path $path
        Write-Output 'Offline preparation complete. No cloud calls; deployment is not implemented or authorized by this command.'
        return
    }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Assert-SpikeManifest $manifest
    if ($Action -eq 'Cleanup') {
        if (-not $ConfirmCoordinatorCleanupDirection) { throw 'Exact coordinator cleanup direction required.' }
        Remove-OwnedSpike -Manifest $manifest -Path $path
        Write-Output 'Exact spike resource group absence verified.'
    } else {
        $manifest | ConvertTo-Json -Depth 4
    }
} finally {
    $lock.Dispose()
}
