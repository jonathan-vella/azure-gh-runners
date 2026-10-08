[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Inspect', 'Execute', 'Cleanup')][string]$Action,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$Head,
    [string]$IdentityEnvelopePath,
    [switch]$ConfirmCoordinatorCleanupDirection,
    [string]$ApprovalPath,
    [switch]$ConfirmCoordinatorExecutionDirection
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
        if (-not $IdentityEnvelopePath) { throw 'Original reserved identity envelope required; never create a hosted clock or nonce.' }
        Import-Module (Join-Path $PSScriptRoot 'Identity-Bridge.psm1')
        $state = Read-SpikeIdentityEnvelope $IdentityEnvelopePath
        if ($Head -and $state.head -cne $Head) { throw 'Identity envelope differs from exact reviewed head.' }
        Write-SpikeManifest -Manifest (ConvertTo-SpikeRuntimeManifest $state) -Path $path
        Write-Output 'Offline preparation complete. No cloud calls; deployment remains disabled.'
        return
    }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-SpikeManifest $manifest
    if ($Action -eq 'Execute') {
        if (-not $ConfirmCoordinatorExecutionDirection -or -not $ApprovalPath) {
            throw 'Exact execution direction and separately approved nonsecret gate record required.'
        }
        Import-Module (Join-Path $PSScriptRoot 'Execution.psm1') -Force
        $approval = Get-Content -LiteralPath $ApprovalPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        try {
            Invoke-SpikeExecution -Manifest $manifest -Path $path -Approval $approval
            Write-Output 'One-worker lifecycle ended. Policy/NAT/MI/protection/termination acceptance remains unverified.'
        } finally {
            [Environment]::SetEnvironmentVariable('GHR_SPIKE60_APP_PRIVATE_KEY', $null)
            try {
                if ($manifest.attempts -gt 0) {
                    try {
                        Save-SpikeControllerEvidence $manifest "$path.controller.json"
                    } finally {
                        try { Invoke-SpikeControllerCleanup $manifest }
                        finally { Save-SpikeControllerEvidence $manifest "$path.controller-final.json" }
                    }
                }
            } finally {
                if ($manifest.attempts -gt 0) { Remove-OwnedSpike -Manifest $manifest -Path $path }
            }
        }
    } elseif ($Action -eq 'Cleanup') {
        if (-not $ConfirmCoordinatorCleanupDirection) { throw 'Exact coordinator cleanup direction required.' }
        Import-Module (Join-Path $PSScriptRoot 'Execution.psm1')
        Assert-SpikeSourceDisabled
        Remove-OwnedSpike -Manifest $manifest -Path $path
        Write-Output 'Exact spike resource group absence verified.'
    } else {
        $manifest | ConvertTo-Json -Depth 4
    }
} finally {
    $lock.Dispose()
}
