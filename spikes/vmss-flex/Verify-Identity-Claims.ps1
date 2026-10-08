$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'jonathan-vella/azure-gh-runners' -or
    $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_RUN_ATTEMPT -cne '1' -or
    $env:GHR_SPIKE_ENVIRONMENT -cne 'spike-vmss') {
    throw 'Actual OIDC claim verification is hosted spike-vmss/main-only; never retrieve tokens locally.'
}
$uri = [uri]$env:ACTIONS_ID_TOKEN_REQUEST_URL
if ($uri.Scheme -cne 'https' -or -not $uri.Host.EndsWith('.actions.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase) -or
    -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) { throw 'Hosted GitHub OIDC request context unavailable.' }
$response = $null
$token = $null
$claims = $null
try {
    $separator = if ($uri.Query) { '&' } else { '?' }
    try {
        $response = Invoke-RestMethod -Method Get -Uri ($uri.AbsoluteUri + $separator + 'audience=api%3A%2F%2FAzureADTokenExchange') `
            -Headers @{ Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" } -TimeoutSec 20 -MaximumRedirection 0
    } catch { throw 'Bounded hosted OIDC request failed; token/provider output suppressed.' }
    $token = [string]$response.value
    $segments = $token.Split('.')
    if ($segments.Count -ne 3 -or $token.Length -gt 16384 -or $segments[1] -cnotmatch '^[A-Za-z0-9_-]+$') {
        throw 'Invalid hosted OIDC response; no token output.'
    }
    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'Invalid hosted OIDC payload; no token output.' }
    }
    try { $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable }
    catch { throw 'Invalid hosted OIDC claims; provider output suppressed.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($claims.iss -cne 'https://token.actions.githubusercontent.com' -or
        $claims.aud -cne 'api://AzureADTokenExchange' -or
        $claims.sub -cne 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss' -or
        $claims.repository_id -cne '1408821667' -or $claims.repository_owner_id -cne '25802147' -or
        ($claims.exp -isnot [long] -and $claims.exp -isnot [int]) -or
        ($claims.nbf -isnot [long] -and $claims.nbf -isnot [int]) -or
        $claims.exp -le $now -or $claims.nbf -gt $now) {
        throw 'Actual sanitized claims differ from approved GA environment trust or token is stale.'
    }
    @{ iss = $claims.iss; aud = $claims.aud; sub = $claims.sub
        repository_id = $claims.repository_id; repository_owner_id = $claims.repository_owner_id } |
        ConvertTo-Json -Compress
} finally {
    $response = $null
    $token = $null
    $claims = $null
    $segments = $null
    $payload = $null
}
