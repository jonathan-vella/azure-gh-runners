$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -or
    [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)) {
    throw 'GitHub Actions did not provide the OIDC token request context.'
}

$token = $null
try {
    $separator = if ($env:ACTIONS_ID_TOKEN_REQUEST_URL.Contains('?')) { '&' } else { '?' }
    $requestUri = $env:ACTIONS_ID_TOKEN_REQUEST_URL + $separator + 'audience=api%3A%2F%2FAzureADTokenExchange'
    $tokenResponse = Invoke-RestMethod -Method Get -Uri $requestUri -Headers @{
        Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN"
    }
    $token = [string]$tokenResponse.value
    $segments = $token.Split('.')
    if ($segments.Count -ne 3) {
        throw 'GitHub Actions returned an invalid OIDC token.'
    }

    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'GitHub Actions returned an invalid OIDC token payload.' }
    }
    $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

    $issuer = [string]$claims.iss
    $audience = [string]$claims.aud
    $subject = [string]$claims.sub
    $expectedSubject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod'
    if ($issuer -cne 'https://token.actions.githubusercontent.com' -or
        $audience -cne 'api://AzureADTokenExchange' -or
        $subject -cne $expectedSubject) {
        throw 'OIDC claims did not match the bounded issue #8 repository, environment, issuer, and audience allowlist.'
    }

    Write-Output "issuer=$issuer"
    Write-Output "audience=$audience"
    Write-Output "subject=$subject"
} finally {
    $token = $null
    $segments = $null
    $payload = $null
    $requestUri = $null
    $tokenResponse = $null
    $claims = $null
    $subject = $null
    $issuer = $null
    $audience = $null
    Remove-Item Env:\ACTIONS_ID_TOKEN_REQUEST_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\ACTIONS_ID_TOKEN_REQUEST_URL -ErrorAction SilentlyContinue
}
