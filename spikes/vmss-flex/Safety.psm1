Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force

$script:subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$script:tenant = '30bac921-1547-4b1e-8445-72455da783f1'
$script:group = 'rg-ghrunners-spike-vmss-swc'
$script:scope = "/subscriptions/$script:subscription/resourceGroups/$script:group"

function New-SpikeManifest {
    param([Parameter(Mandatory)][string]$Head)
    if ($Head -cnotmatch '^[a-f0-9]{40}$') { throw 'Exact reviewed commit SHA required.' }
    return @{
        schemaVersion = 1; issue = 60; runId = [guid]::NewGuid().ToString('N')
        head = $Head; subscription = $script:subscription; tenant = $script:tenant
        resourceGroup = $script:group; scope = $script:scope; location = 'swedencentral'
        controllerSku = 'Standard_B2s'; workerSku = 'Standard_D2ls_v5'
        maxWorkers = 2; maxAttempts = 2; attempts = 0
        maxHours = 4; cleanupReserveMinutes = 60; capUsd = 10
        # These are ceilings, not quotes: price refresh and measured byte/log limits
        # are required before this envelope may authorize a deployment.
        hourlyCeilingUsd = 0.5; fixedReserveUsd = 6; envelopeUsd = 8
        startedUtc = $null; workDeadlineUtc = $null; hardDeadlineUtc = $null
        phase = 'prepared'; cleanup = 'not-started'
    }
}

function Assert-SpikeManifest {
    param([Parameter(Mandatory)][hashtable]$Manifest)
    $expected = New-SpikeManifest -Head $Manifest.head
    if ($Manifest.Count -ne $expected.Count) { throw 'Unexpected manifest fields; refusing unsafe state.' }
    foreach ($key in $expected.Keys) {
        if (-not $Manifest.ContainsKey($key)) { throw 'Missing manifest field.' }
        if ($key -notin @('runId', 'attempts', 'startedUtc', 'workDeadlineUtc', 'hardDeadlineUtc', 'phase', 'cleanup') -and
            $Manifest[$key] -cne $expected[$key]) { throw 'Manifest scope or hard-limit drift.' }
    }
    if ($Manifest.runId -cnotmatch '^[a-f0-9]{32}$' -or
        $Manifest.attempts -isnot [long] -and $Manifest.attempts -isnot [int] -or
        $Manifest.attempts -lt 0 -or $Manifest.attempts -gt 2 -or
        $Manifest.phase -notin @('prepared', 'active', 'cleanup', 'closed') -or
        $Manifest.cleanup -notin @('not-started', 'pending', 'failed', 'absent-verified')) {
        throw 'Invalid manifest state.'
    }
    if ($Manifest.phase -eq 'prepared') {
        if ($null -ne $Manifest.startedUtc -or $null -ne $Manifest.workDeadlineUtc -or
            $null -ne $Manifest.hardDeadlineUtc -or $Manifest.attempts -ne 0 -or
            $Manifest.cleanup -ne 'not-started') { throw 'Prepared manifest contains runtime state.' }
    } else {
        $start = [DateTimeOffset]::ParseExact($Manifest.startedUtc, 'o', [cultureinfo]::InvariantCulture)
        $work = [DateTimeOffset]::ParseExact($Manifest.workDeadlineUtc, 'o', [cultureinfo]::InvariantCulture)
        $hard = [DateTimeOffset]::ParseExact($Manifest.hardDeadlineUtc, 'o', [cultureinfo]::InvariantCulture)
        if ($start.Offset -ne [timespan]::Zero -or $work -ne $start.AddHours(3) -or
            $hard -ne $start.AddHours(4)) { throw 'Manifest lifetime or cleanup reserve drift.' }
        if (($Manifest.phase -eq 'closed') -ne ($Manifest.cleanup -eq 'absent-verified') -or
            $Manifest.phase -eq 'active' -and $Manifest.cleanup -ne 'not-started') {
            throw 'Manifest cleanup transition is invalid.'
        }
    }
}

function Write-SpikeManifest {
    param([Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)][string]$Path)
    Assert-SpikeManifest $Manifest
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Start-SpikeClock {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)][string]$Path,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    Assert-SpikeManifest $Manifest
    if ($Manifest.phase -ne 'prepared') { throw 'A run may start only once; never reset the four-hour clock.' }
    $Now = $Now.ToUniversalTime()
    $Manifest.startedUtc = $Now.ToString('o')
    $Manifest.workDeadlineUtc = $Now.AddHours(3).ToString('o')
    $Manifest.hardDeadlineUtc = $Now.AddHours(4).ToString('o')
    $Manifest.phase = 'active'
    Write-SpikeManifest -Manifest $Manifest -Path $Path
}

function Reserve-SpikeAttempt {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 2700)][int]$Seconds,
        [ValidateRange(0, 2)][int]$Workers,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    Assert-SpikeManifest $Manifest
    if ($Manifest.phase -ne 'active' -or $Manifest.attempts -ge 2 -or
        $Now -lt [DateTimeOffset]::Parse($Manifest.startedUtc) -or
        $Now.AddSeconds($Seconds + 15) -ge [DateTimeOffset]::Parse($Manifest.workDeadlineUtc) -or
        $Manifest.envelopeUsd -ge $Manifest.capUsd) {
        throw 'Attempt, time or cost gate exhausted; enter cleanup without another deployment.'
    }
    # Persist before sending ARM any mutating request, including failed deployments.
    $Manifest.attempts++
    Write-SpikeManifest -Manifest $Manifest -Path $Path
}

function Assert-OwnedSpikeGroup {
    param([Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)]$Group)
    Assert-SpikeManifest $Manifest
    if ($Group.id -ine $script:scope -or $Group.name -cne $script:group -or
        $Group.location -cne 'swedencentral' -or
        $Group.tags.'spike-id' -cne '60' -or $Group.tags.'spike-run-id' -cne $Manifest.runId -or
        $Group.tags.'spike-head' -cne $Manifest.head) {
        throw 'Exact owned spike RG verification failed; no deletion was requested.'
    }
}

function Invoke-SpikeAz {
    param([string[]]$Arguments, [int]$Seconds = 30)
    $cli = Get-BoundedAzureCli
    $result = Invoke-BoundedProcess -FileName $cli.fileName -Arguments @($cli.prefix + $Arguments) -TimeoutSeconds $Seconds
    if ($result.exitCode -ne 0) {
        throw 'Bounded Azure operation failed; provider output suppressed. Cleanup remains unverified.'
    }
    try { return ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop }
    catch { throw 'Azure operation returned invalid structured metadata; provider output suppressed.' }
}

function Remove-OwnedSpike {
    param([Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)][string]$Path)
    Assert-SpikeManifest $Manifest
    if ($Manifest.phase -eq 'prepared') { throw 'Prepared run owns no cloud resources; refusing cloud calls.' }
    # Cleanup has its own bounded recovery window even if an interrupted operator
    # resumes after the hard deadline. It can never start experimental work.
    $cleanupStop = [DateTimeOffset]::UtcNow.AddMinutes(45)
    $Manifest.phase = 'cleanup'
    $Manifest.cleanup = 'pending'
    Write-SpikeManifest -Manifest $Manifest -Path $Path
    try {
        $account = Invoke-SpikeAz @('account', 'show', '--subscription', $script:subscription, '-o', 'json', '--only-show-errors')
        if ($account.id -cne $script:subscription -or $account.tenantId -cne $script:tenant -or $account.name -cne 'shared') {
            throw 'Cleanup subscription/tenant mismatch.'
        }
        $exists = Invoke-SpikeAz @('group', 'exists', '--subscription', $script:subscription, '--name', $script:group, '-o', 'json')
        if ($exists -isnot [bool]) { throw 'RG existence response was not boolean.' }
        if ($exists) {
            $group = Invoke-SpikeAz @('group', 'show', '--subscription', $script:subscription, '--name', $script:group, '-o', 'json', '--only-show-errors')
            Assert-OwnedSpikeGroup -Manifest $Manifest -Group $group
            $cli = Get-BoundedAzureCli
            $result = Invoke-BoundedProcess -FileName $cli.fileName -Arguments @($cli.prefix + @(
                'group', 'delete', '--subscription', $script:subscription, '--name', $script:group,
                '--yes', '--no-wait', '--only-show-errors', '-o', 'none'
            )) -TimeoutSeconds 30
            if ($result.exitCode -ne 0) { throw 'Owned RG delete request failed; provider output suppressed.' }
            do {
                if ([DateTimeOffset]::UtcNow.AddSeconds(45) -ge $cleanupStop) {
                    throw 'Cleanup recovery window exhausted; RG absence remains unverified.'
                }
                Start-Sleep -Seconds 10
                $exists = Invoke-SpikeAz @('group', 'exists', '--subscription', $script:subscription, '--name', $script:group, '-o', 'json')
                if ($exists -isnot [bool]) { throw 'RG existence response was not boolean.' }
            } while ($exists)
        }
        $Manifest.phase = 'closed'
        $Manifest.cleanup = 'absent-verified'
        Write-SpikeManifest -Manifest $Manifest -Path $Path
    } catch {
        $Manifest.cleanup = 'failed'
        Write-SpikeManifest -Manifest $Manifest -Path $Path
        throw
    }
}

Export-ModuleMember -Function New-SpikeManifest, Assert-SpikeManifest, Write-SpikeManifest,
    Start-SpikeClock, Reserve-SpikeAttempt, Assert-OwnedSpikeGroup, Remove-OwnedSpike
