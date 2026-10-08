$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Identity-Bridge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
function Reject([scriptblock]$Operation) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    if (-not $failed) { throw 'Unsafe identity bridge input accepted.' }
}
$pricing = @{
    schemaVersion = 1; source = 'azure-retail-prices-api'; sourceUrl = 'https://prices.azure.com/api/retail/prices'
    retrievedUtc = '2026-10-08T05:00:00.000Z'; currencyCode = 'USD'; region = 'swedencentral'
    b2sHourly = 0.0432; d2lsHourly = 0.091; p4MonthlyUsd = 5.8072
    natHourly = 0.045; natProcessedGb = 0.045; standardIpv4Hourly = 0.005
    privateEndpointHourly = 0.01; privateEndpointIngressGb = 0.01; privateEndpointEgressGb = 0.01
    internetEgressGb = 0.12; privateDnsZoneMonthly = 0.5; privateDnsQueriesPerMillion = 0.4
    keyVaultOperationsPer10k = 0.03
}
$now = [DateTimeOffset]::Parse('2026-10-08T05:00:00.000Z')
$price = Get-SpikeCombinedPrice -Pricing $pricing -Now $now
if ($price -le 4 -or $price -ge 10) { throw 'Sourced two-run retail planning projection was not preserved.' }
$badPrice = $pricing.Clone()
$badPrice.b2sHourly = 3
Reject { Get-SpikeCombinedPrice -Pricing $badPrice -Now $now }

$directory = Join-Path ([IO.Path]::GetTempPath()) "identity-bridge-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$path = Join-Path $directory 'identity.json'
$node = Get-Command node -CommandType Application | Select-Object -First 1 -ExpandProperty Source
$source = @'
const { pathToFileURL } = await import('node:url');
const m = await import(pathToFileURL(process.argv[1]));
const pricing = JSON.parse(process.argv[2]);
const now = pricing.retrievedUtc;
let state = m.newIdentityEnvelope('a'.repeat(40));
state = m.transitionIdentityEnvelope(state, 'begin', { now, pricing });
const claims = {
  iss:'https://token.actions.githubusercontent.com', aud:'api://AzureADTokenExchange',
  sub:'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss',
  repository_id:'1408821667', repository_owner_id:'25802147'
};
const ids = {
  application:'11111111-1111-1111-1111-111111111111',
  client:'22222222-2222-2222-2222-222222222222',
  servicePrincipal:'33333333-3333-3333-3333-333333333333',
  federation:'44444444-4444-4444-4444-444444444444',
  environment:100, environmentPolicy:200
};
for (const step of Object.keys(state.runs[0].steps)) {
  if (step === 'foundation') break;
  state = m.transitionIdentityEnvelope(state, 'reserve', { step, now });
  if (Object.hasOwn(ids,step)) state = m.transitionIdentityEnvelope(state,'capture',
    { step, id:ids[step], clientId:ids.client });
  if (step === 'seedConfirmation') state = m.transitionIdentityEnvelope(state,'record-key-fingerprint',
    { fingerprint:Buffer.alloc(32, 1).toString('base64') });
  state = m.transitionIdentityEnvelope(state, 'verify', { step, claims, seedConfirmed:true });
}
state = m.transitionIdentityEnvelope(state, 'reserve', { step:'foundation', now });
console.log(JSON.stringify(state));
'@
try {
    $result = Invoke-BoundedProcess -FileName $node -Arguments @(
        '--input-type=module', '-e', $source, (Join-Path $PSScriptRoot 'temporary-identity.mjs'),
        ($pricing | ConvertTo-Json -Compress)
    ) -TimeoutSeconds 15
    if ($result.exitCode -ne 0) { throw 'Offline identity fixture generation failed.' }
    [IO.File]::WriteAllText($path, $result.stdout, [Text.UTF8Encoding]::new($false))
    $state = Read-SpikeIdentityEnvelope $path
    $manifest = ConvertTo-SpikeRuntimeManifest $state
    if ($manifest.runId -cne $state.runId -or $manifest.runOrdinal -ne 1 -or
        [DateTimeOffset]::Parse($manifest.startedUtc) -ne $now -or
        [DateTimeOffset]::Parse($manifest.hardDeadlineUtc) -ne $now.AddHours(4) -or
        $manifest.temporaryIdentityClientId -cne $state.runs[0].ids.client -or
        $manifest.appKeyFingerprint -cne [Convert]::ToBase64String([byte[]](1..32 | ForEach-Object { 1 }))) {
        throw 'Runtime bridge reset original envelope or lost exact temporary identity.'
    }
    $state.runs[0].steps.seedConfirmation = 'reserved'
    Reject { ConvertTo-SpikeRuntimeManifest $state }
    $state.runs[0].steps.seedConfirmation = 'verified'
    $state.runs[0].steps.foundation = 'pending'
    Reject { ConvertTo-SpikeRuntimeManifest $state }
    $state.runs[0].steps.foundation = 'reserved'
    $state.runOrdinal = 3
    [IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 12))
    Reject { Read-SpikeIdentityEnvelope $path }
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    Remove-Item -LiteralPath $directory
}
Write-Output 'Original envelope, exact temporary SP/clock, owner confirmation and complete cost bridge passed offline.'
