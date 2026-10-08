$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Reject([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    Assert $rejected $Message
}
$directory = Join-Path ([IO.Path]::GetTempPath()) "vmss60-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$path = Join-Path $directory 'manifest.json'
try {
    $manifest = New-SpikeManifest -Head ('a' * 40)
    Assert-SpikeManifest $manifest
    $id = $manifest.runId
    $manifest.runId = 'invalid'
    Reject { Assert-SpikeManifest $manifest } 'Invalid run nonce accepted with an integer attempt counter.'
    $manifest.runId = $id
    Assert ($manifest.capUsd -eq 10 -and -not $manifest.ContainsKey('envelopeUsd')) 'Obsolete partial budget bypass retained.'
    $manifest.extraSecret = 'not-a-real-secret'
    Reject { Assert-SpikeManifest $manifest } 'Unexpected fields accepted.'
    $manifest.Remove('extraSecret')
    $manifest.resourceGroup = 'rg-ghrunners-prod-swc'
    Reject { Assert-SpikeManifest $manifest } 'Production scope accepted.'
    $manifest.resourceGroup = 'rg-ghrunners-spike-vmss-swc'
    Reject { Remove-OwnedSpike -Manifest $manifest -Path $path } 'Prepared run reached cloud cleanup.'
    $start = [DateTimeOffset]::Parse('2026-10-07T20:00:00Z')
    Start-SpikeClock -Manifest $manifest -Path $path -Now $start
    Reject { Remove-OwnedSpike -Manifest $manifest -Path $path } 'Source-disabled cleanup reached Azure.'
    Reject { Start-SpikeClock -Manifest $manifest -Path $path -Now $start } 'Run clock reset accepted.'
    Write-SpikeManifest -Manifest $manifest -Path $path
    Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 2 -Now $start
    $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-SpikeManifest $loaded
    Assert ($loaded.attempts -eq 1) 'Attempt not durably reserved.'
    Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 1 -Now $start
    Reject { Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 1 -Now $start } 'Third attempt accepted.'
    $manifest.attempts = 0
    Reject { Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 3 -Now $start } 'Third worker accepted.'
    Reject { Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 1 -Now $start.AddHours(3) } 'Cleanup reserve consumed.'
    Reject { Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 1 -Now $start.AddSeconds(-1) } 'Clock reversal accepted.'
    $manifest.capUsd = 11
    Reject { Assert-SpikeManifest $manifest } 'Raised cost cap accepted.'
    $manifest.capUsd = 10
    $owned = [pscustomobject]@{
        id = $manifest.scope; name = $manifest.resourceGroup; location = 'swedencentral'
        tags = @{ 'spike-id' = '60'; 'spike-run-id' = $manifest.runId; 'spike-head' = $manifest.head
            'spike-run-ordinal' = [string]$manifest.runOrdinal }
    }
    Assert-OwnedSpikeGroup -Manifest $manifest -Group $owned
    $owned.tags.'spike-run-id' = 'foreign'
    Reject { Assert-OwnedSpikeGroup -Manifest $manifest -Group $owned } 'Foreign RG accepted for deletion.'

    $module = Get-Module Safety
    & $module {
        $script:cleanupSourceEnabled = $true
        function script:Invoke-SpikeAz {
            param([string[]]$Arguments, [int]$Seconds = 30)
            if ($Arguments[0] -eq 'account') {
                return [pscustomobject]@{ id = $script:subscription; tenantId = $script:tenant; name = 'shared' }
            }
            if ($Arguments[1] -eq 'exists') { return $false }
            throw 'Unexpected Azure call in offline absence test.'
        }
    }
    Remove-OwnedSpike -Manifest $manifest -Path $path
    Assert ($manifest.cleanup -eq 'absent-verified' -and $manifest.phase -eq 'closed') 'Absence not durably recorded.'
    Reject { Reserve-SpikeAttempt -Manifest $manifest -Path $path -Seconds 60 -Workers 1 -Now $start } 'Closed run reopened.'
    Remove-OwnedSpike -Manifest $manifest -Path $path
    Assert ($manifest.cleanup -eq 'absent-verified') 'Repeated absence cleanup failed.'
    $manifest.phase = 'active'
    $manifest.cleanup = 'not-started'
    & $module {
        $script:fakeGroup = $null
        $script:existsCalls = 0
        function script:Invoke-SpikeAz {
            param([string[]]$Arguments, [int]$Seconds = 30)
            if ($Arguments[0] -eq 'account') {
                return [pscustomobject]@{ id = $script:subscription; tenantId = $script:tenant; name = 'shared' }
            }
            if ($Arguments[1] -eq 'exists') {
                $script:existsCalls++
                return ($script:existsCalls -eq 1)
            }
            if ($Arguments[1] -eq 'show') { return $script:fakeGroup }
            throw 'Unexpected Azure metadata call.'
        }
        function script:Get-BoundedAzureCli { return @{ fileName = 'mock'; prefix = @() } }
        function script:Invoke-BoundedProcess {
            param($FileName, $Arguments, $TimeoutSeconds)
            if ($Arguments[0] -ne 'group' -or $Arguments[1] -ne 'delete' -or
                $Arguments[4] -ne '--name' -or $Arguments[5] -ne $script:group -or $TimeoutSeconds -ne 900 -or
                $Arguments -contains '--no-wait') {
                throw 'Cleanup command was not exact or bounded.'
            }
            return @{ exitCode = 0 }
        }
        function script:Start-Sleep { param($Seconds) }
    }
    $owned.tags.'spike-run-id' = $manifest.runId
    & $module { param($Owned) $script:fakeGroup = $Owned } $owned
    Remove-OwnedSpike -Manifest $manifest -Path $path
    Assert ($manifest.cleanup -eq 'absent-verified') 'Owned partial RG deletion not verified.'
    $manifest.phase = 'active'
    $manifest.cleanup = 'not-started'
    $manifest.cleanupDeleteReserved = $false
    $manifest.cleanupDeleteAcknowledged = $false
    & $module {
        $script:existsCalls = 0
        function script:Invoke-BoundedProcess { param($FileName, $Arguments, $TimeoutSeconds) return @{ exitCode = 1 } }
    }
    Reject { Remove-OwnedSpike -Manifest $manifest -Path $path } 'Deletion failure became success.'
    $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Assert ($loaded.cleanup -eq 'failed' -and $loaded.phase -eq 'cleanup') 'Delete failure not persisted.'
    Write-Output 'VMSS spike manifest, budget, attempt, lifetime and ownership tests passed (offline).'
} finally {
    Remove-Module Safety
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $directory
}
