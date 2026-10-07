function Invoke-BoundedNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [datetime]$Deadline = [datetime]::MinValue,
        [scriptblock]$CommandRunner
    )

    if ($Deadline -and $Deadline -ne [datetime]::MinValue) {
        $remainingMilliseconds = ($Deadline - [datetime]::UtcNow).TotalMilliseconds
        if ($remainingMilliseconds -le 0) {
            throw "Command deadline expired before '$Command' could run."
        }
        $TimeoutMilliseconds = [int][Math]::Min(
            $TimeoutSeconds * 1000,
            [Math]::Ceiling($remainingMilliseconds)
        )
    } else {
        $TimeoutMilliseconds = $TimeoutSeconds * 1000
    }
    $effectiveTimeoutSeconds = [Math]::Ceiling($TimeoutMilliseconds / 1000)
    if ($CommandRunner) {
        return & $CommandRunner $Command $Arguments $effectiveTimeoutSeconds
    }

    $payload = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes(
            (@{ command = $Command; arguments = $Arguments } | ConvertTo-Json -Compress)
        )
    )
    $helper = @'
$spec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$output = & $spec.command @($spec.arguments) 2>$null
$exitCode = $LASTEXITCODE
[Console]::Out.Write(($output | Out-String -Width 4096))
exit $exitCode
'@.Replace('__PAYLOAD__', $payload)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [Environment]::ProcessPath
    if (-not $startInfo.FileName -or -not (Test-Path -LiteralPath $startInfo.FileName -PathType Leaf)) {
        throw 'Unable to resolve the current PowerShell executable for bounded command execution.'
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Unable to start bounded '$Command' command."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) {
                throw "Command '$Command' did not exit after its process tree was terminated."
            }
            throw "Command '$Command' exceeded its $([Math]::Round($TimeoutMilliseconds / 1000, 2))-second timeout."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Command '$Command' failed with exit code $($process.ExitCode)."
        }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-BoundedNativeCommand
