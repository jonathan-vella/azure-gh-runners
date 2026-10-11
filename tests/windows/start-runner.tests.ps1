# Offline tests for the pure parts of image/windows/start-runner.ps1 (config parsing and validation).
# Usage: pwsh -NoProfile -File tests/windows/start-runner.tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '../../image/windows/start-runner.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ghr-start-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:failures = [System.Collections.Generic.List[string]]::new()
$script:count = 0

# Dot-sourcing loads the functions without running the boot sequence.
. $scriptPath

$canary = 'SECRETJITCANARY0123456789abcdefABCDEF'
$now = [DateTimeOffset]::Parse('2026-10-11T12:00:00Z')
$policy = '{"repository":"example/service","visibility":"public","allowedEvents":["workflow_dispatch"],"allowedRefs":["refs/heads/main"],"allowedWorkflows":["example/service/.github/workflows/ci.yml@refs/heads/main"]}'

function New-ConfigText {
    param($Json = $null, [hashtable]$Replace = @{})
    if ($null -eq $Json) {
        $Json = '{"version":1,"jitConfig":"' + $canary + '","policy":' + $policy + ',"expiresUtc":"2026-10-11T12:30:00Z"}'
    }
    foreach ($key in $Replace.Keys) { $Json = $Json.Replace($key, $Replace[$key]) }
    return $Json
}

function Read-Config {
    param([string]$Text, $Bytes = $null)
    $path = Join-Path $work 'CustomData.bin'
    if ($null -eq $Bytes) { $Bytes = $utf8.GetBytes($Text) }
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    try {
        return Read-WorkerConfig -Path $path -Now $now
    }
    finally {
        if (Test-Path -LiteralPath $path) { throw 'custom data file was not deleted' }
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:count++
    try {
        & $Body
        Write-Host "ok - $Name"
    }
    catch {
        $script:failures.Add($Name)
        Write-Host "not ok - $Name`n  $($_.Exception.Message)"
    }
}

function Assert-Refused {
    param([scriptblock]$Action, [string]$Pattern)
    try {
        & $Action | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "unexpected error: $($_.Exception.Message)" }
        if ($_.Exception.Message.Contains($canary) -or $_.Exception.Message.Contains('example/service')) { throw 'error leaks config content' }
        return
    }
    throw 'expected the config to be refused'
}

try {
    Test-Case 'accepts a valid config, deletes the file and returns the policy unchanged' {
        $config = Read-Config (New-ConfigText)
        if ($config.JitConfig -ne $canary) { throw 'JIT config mismatch' }
        if ($config.PolicyJson -ne $policy) { throw 'policy was altered' }
    }
    Test-Case 'accepts offset timestamps and fractional seconds in the future' {
        [void](Read-Config (New-ConfigText -Replace @{ '2026-10-11T12:30:00Z' = '2026-10-11T14:30:00.5+02:00' }))
    }
    Test-Case 'refuses an expired config' {
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '2026-10-11T12:30:00Z' = '2026-10-11T11:59:59Z' }) } 'expired'
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '2026-10-11T12:30:00Z' = '2026-10-11T12:00:00Z' }) } 'expired'
    }
    Test-Case 'refuses malformed timestamps' {
        foreach ($bad in '2026-10-11 12:30:00', '2026-10-11T12:30:00', 'tomorrow', '') {
            Assert-Refused { Read-Config (New-ConfigText -Replace @{ '2026-10-11T12:30:00Z' = $bad }) } 'expiresUtc'
        }
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"expiresUtc":"2026-10-11T12:30:00Z"' = '"expiresUtc":20261011' }) } 'expiresUtc'
    }
    Test-Case 'refuses unsupported versions' {
        foreach ($bad in '2', '0', '"1"', '1.5', 'true') {
            Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"version":1' = "`"version`":$bad" }) } 'version'
        }
    }
    Test-Case 'refuses missing, extra and renamed fields' {
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"version":1,' = '' }) } 'unexpected fields'
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"version":1,' = '"version":1,"extra":true,' }) } 'unexpected fields'
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ 'jitConfig' = 'JitConfig' }) } 'unexpected fields'
    }
    Test-Case 'refuses malformed JSON, non-objects and empty files without echoing content' {
        Assert-Refused { Read-Config ('{"jitConfig":"' + $canary) } 'not valid JSON'
        Assert-Refused { Read-Config '[]' } 'not a JSON object'
        Assert-Refused { Read-Config '' } 'invalid size'
        Assert-Refused { Read-Config -Text '' -Bytes ([byte[]](0xff, 0xfe, 0x00)) } '.'
    }
    Test-Case 'refuses oversized files' {
        Assert-Refused { Read-Config -Text '' -Bytes ([byte[]]::new(131073)) } 'invalid size'
    }
    Test-Case 'refuses JIT configs that are not plain base64' {
        foreach ($bad in 'short', 'abcdefghijklmnop&calc', 'abcdefghijklmnop calc', 'abcdefghijklmnop"x', 'abcdefghijklmnop%PATH%', 'abcdefghijklmnop^x', "abcdefghijklmnop`ncalc") {
            $escaped = ($bad | ConvertTo-Json -Compress).Trim('"')
            Assert-Refused { Read-Config (New-ConfigText -Replace @{ $canary = $escaped }) } 'jitConfig'
        }
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ ('"' + $canary + '"') = '123' }) } 'jitConfig'
    }
    Test-Case 'accepts padded and URL-safe base64' {
        foreach ($good in 'abcdefghijklmnopqrstuv==', 'abc-_def+/ghijklmnopq') {
            if ((Read-Config (New-ConfigText -Replace @{ $canary = $good })).JitConfig -ne $good) { throw 'value changed' }
        }
    }
    Test-Case 'refuses a malformed policy' {
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ $policy = '"x"' }) } 'policy is invalid'
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"visibility":"public",' = '' }) } 'policy has unexpected fields'
        Assert-Refused { Read-Config (New-ConfigText -Replace @{ '"visibility":"public",' = '"visibility":"public","extra":1,' }) } 'policy has unexpected fields'
    }
    Test-Case 'waits for custom data and gives up after the timeout' {
        $path = Join-Path $work 'late.bin'
        if (Wait-CustomData -Path $path -TimeoutSeconds 0) { throw 'expected a timeout' }
        [System.IO.File]::WriteAllText($path, 'x')
        if (-not (Wait-CustomData -Path $path -TimeoutSeconds 0)) { throw 'expected the file to be found' }
    }
    Test-Case 'script never uses Azure identity, IMDS or console logging of secrets' {
        $text = Get-Content -Raw $scriptPath
        foreach ($forbidden in '169.254.169.254', 'Connect-AzAccount', 'az login', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Start-Transcript', 'Write-Host', 'Write-Output') {
            if ($text.Contains($forbidden)) { throw "script contains $forbidden" }
        }
        if (-not $text.Contains('shutdown.exe /s /t 0')) { throw 'script must power off with shutdown /s /t 0' }
        if ($text -notmatch '(?s)finally \{\s+Invoke-Shutdown') { throw 'shutdown must run in a finally block' }
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "`n$($script:count - $script:failures.Count) of $($script:count) start-runner tests passed."
if ($script:failures.Count -gt 0) {
    Write-Host "Failed: $($script:failures -join '; ')"
    exit 1
}
exit 0
