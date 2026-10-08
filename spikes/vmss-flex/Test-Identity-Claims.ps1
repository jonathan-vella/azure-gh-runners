$ErrorActionPreference = 'Stop'
function Reject([scriptblock]$Operation) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    if (-not $failed) { throw 'Unsafe identity claims fixture accepted.' }
}
$names = @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REF', 'GITHUB_RUN_ATTEMPT',
    'GHR_SPIKE_ENVIRONMENT', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$fixtureClaims = @{
    iss = 'https://token.actions.githubusercontent.com'; aud = 'api://AzureADTokenExchange'
    sub = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss'
    repository_id = '1408821667'; repository_owner_id = '25802147'
    exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 600
    nbf = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10
    arbitrary_claim = 'must-not-be-output'
}
$global:spikeIdentityClaimFixture = $fixtureClaims
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)
    if ($Headers.Authorization -cne 'Bearer synthetic-request' -or $TimeoutSec -ne 20 -or $MaximumRedirection -ne 0 -or
        $Uri -notlike '*audience=api%3A%2F%2FAzureADTokenExchange') { throw 'Unbounded mocked request.' }
    $json = $global:spikeIdentityClaimFixture | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ value = "synthetic.$payload.synthetic" }
}
try {
    $env:GITHUB_ACTIONS = 'false'
    Reject { & (Join-Path $PSScriptRoot 'Verify-Identity-Claims.ps1') }
    $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_REPOSITORY = 'jonathan-vella/azure-gh-runners'
    $env:GITHUB_REF = 'refs/heads/main'; $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GHR_SPIKE_ENVIRONMENT = 'spike-vmss'
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://fixture.actions.githubusercontent.com/token'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'synthetic-request'
    $output = & (Join-Path $PSScriptRoot 'Verify-Identity-Claims.ps1')
    $sanitized = $output | ConvertFrom-Json -AsHashtable
    if ($sanitized.Count -ne 5 -or $sanitized.sub -cne $fixtureClaims.sub -or $output -match 'synthetic|arbitrary_claim|must-not-be-output') {
        throw 'OIDC sanitization exposed nonallowlisted data.'
    }
    $fixtureClaims.sub = $fixtureClaims.sub.Replace('spike-vmss', 'platform-prod')
    Reject { & (Join-Path $PSScriptRoot 'Verify-Identity-Claims.ps1') }
    $fixtureClaims.sub = $fixtureClaims.sub.Replace('platform-prod', 'spike-vmss')
    $fixtureClaims.exp = 1
    Reject { & (Join-Path $PSScriptRoot 'Verify-Identity-Claims.ps1') }
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://untrusted.invalid/token'
    Reject { & (Join-Path $PSScriptRoot 'Verify-Identity-Claims.ps1') }
} finally {
    Remove-Variable -Name spikeIdentityClaimFixture -Scope Global
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
Write-Output 'Hosted-only GA issuer/audience/immutable subject, freshness and sanitized output passed with synthetic tokens.'
