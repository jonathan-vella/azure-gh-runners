# Parses every PowerShell file under image/windows and tests/windows; fails on any syntax error.
# Usage: pwsh -NoProfile -File tests/windows/syntax.tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$files = @(Get-ChildItem -Path (Join-Path $root 'image/windows'), (Join-Path $root 'tests/windows') -Filter '*.ps1' -Recurse)
$failed = 0
foreach ($file in $files) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed++
        Write-Host "not ok - $($file.Name): $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))"
    }
    elseif ((Get-Content -Raw -LiteralPath $file.FullName) -match '[^\x00-\x7F]') {
        # Windows PowerShell 5.1 reads BOM-less files as ANSI, so keep the image scripts ASCII.
        $failed++
        Write-Host "not ok - $($file.Name): contains non-ASCII characters"
    }
    else {
        Write-Host "ok - $($file.Name) parses"
    }
}
if ($files.Count -lt 5) { Write-Host 'not ok - expected at least five PowerShell files'; $failed++ }
exit ([int]($failed -gt 0))
