Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1')
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1')

function Read-SpikeIdentityEnvelope {
    param([Parameter(Mandatory)][string]$Path)
    $node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
    $result = Invoke-BoundedProcess -FileName $node -Arguments @(
        (Join-Path $PSScriptRoot 'identity-cli.mjs'), 'inspect', [IO.Path]::GetFullPath($Path)
    ) -TimeoutSeconds 15
    if ($result.exitCode -ne 0) { throw 'Original identity envelope invalid; no workflow handoff.' }
    return ConvertFrom-Json $result.stdout -AsHashtable -DateKind String
}

function ConvertTo-SpikeRuntimeManifest {
    param([Parameter(Mandatory)][hashtable]$IdentityEnvelope)
    $state = $IdentityEnvelope
    if ($state.runOrdinal -notin @(1, 2) -or $state.runs.Count -ne $state.runOrdinal) { throw 'Invalid original full-run ordinal.' }
    $run = $state.runs[-1]
    if ($run.phase -cne 'active' -or $run.steps.seedConfirmation -cne 'verified' -or
        $run.steps.foundation -cne 'reserved' -or $run.credential.revocation -cne 'pending' -or
        $run.credential.fingerprint -cnotmatch '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$' -or
        $run.ids.client -cnotmatch '^[a-f0-9-]{36}$' -or $run.ids.servicePrincipal -cnotmatch '^[a-f0-9-]{36}$') {
        throw 'Actual scoped coordinator seed evidence and durably reserved original foundation handoff required.'
    }
    $manifest = New-SpikeManifest -Head $state.head -RunId $state.runId -RunOrdinal $state.runOrdinal
    $manifest.startedUtc = [DateTimeOffset]::Parse($state.startedUtc).ToUniversalTime().ToString('o')
    $manifest.workDeadlineUtc = [DateTimeOffset]::Parse($state.workDeadlineUtc).ToUniversalTime().ToString('o')
    $manifest.hardDeadlineUtc = [DateTimeOffset]::Parse($state.hardDeadlineUtc).ToUniversalTime().ToString('o')
    $manifest.phase = 'active'
    $manifest.appKeyFingerprint = $run.credential.fingerprint
    $manifest.temporaryIdentityClientId = $run.ids.client
    $manifest.temporaryIdentitySpId = $run.ids.servicePrincipal
    Assert-SpikeManifest $manifest
    return $manifest
}

function Get-SpikeCombinedPrice {
    param([Parameter(Mandatory)][hashtable]$Pricing, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
    $result = Invoke-BoundedProcess -FileName $node -Arguments @(
        (Join-Path $PSScriptRoot 'price-envelope.mjs'),
        ($Pricing | ConvertTo-Json -Depth 4 -Compress), $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    ) -TimeoutSeconds 15
    if ($result.exitCode -ne 0) { throw 'Complete conservative original-envelope quote unavailable or exceeds cap.' }
    $value = ConvertFrom-Json $result.stdout
    if (-not [double]::IsFinite([double]$value) -or $value -ge 10 -or $value -le 0) { throw 'Invalid combined quote.' }
    return $value
}

Export-ModuleMember -Function Read-SpikeIdentityEnvelope, ConvertTo-SpikeRuntimeManifest, Get-SpikeCombinedPrice
