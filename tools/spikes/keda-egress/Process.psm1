function Invoke-BoundedProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 2700)][int]$TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Could not start a bounded spike subprocess.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            } catch {
                throw "Spike subprocess exceeded its $TimeoutSeconds-second limit; process-tree termination could not be requested."
            }
            if (-not $process.WaitForExit(5000)) {
                throw 'Spike subprocess exceeded its time limit; process-tree termination was not confirmed within 5 seconds.'
            }
            if (-not [System.Threading.Tasks.Task]::WaitAll(
                    [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000
                )) {
                throw 'Spike subprocess was terminated, but its redirected output streams did not close within 5 seconds.'
            }
            throw "Spike subprocess exceeded its $TimeoutSeconds-second limit and was terminated."
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000
            )) {
            throw 'Spike subprocess exited, but its redirected output streams did not close within 5 seconds.'
        }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-BoundedAzureCli {
    param(
        [object[]]$Candidates = @(Get-Command az -CommandType Application -All -ErrorAction Stop),
        [bool]$OnWindows = $IsWindows
    )

    $sources = @($Candidates | ForEach-Object { [string]$_.Source } | Where-Object { $_ })
    $azPath = if ($OnWindows) {
        @($sources | Where-Object { $_ -match '(?i)\.cmd$' }) + @($sources | Where-Object { $_ -match '(?i)\.exe$' }) |
            Select-Object -First 1
    } else {
        $sources | Select-Object -First 1
    }
    if (-not $azPath) {
        throw 'Could not resolve a supported Azure CLI executable.'
    }

    if ($azPath -match '(?i)\.cmd$') {
        $pythonPaths = @(
            (Join-Path (Split-Path $azPath) 'python.exe'),
            (Join-Path (Split-Path (Split-Path $azPath)) 'python.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        if (@($pythonPaths).Count -ne 1) {
            throw 'Could not resolve a single managed Python runtime for the installed Azure CLI.'
        }
        return [pscustomobject]@{
            fileName = [string]@($pythonPaths)[0]
            prefix = @('-IBm', 'azure.cli')
        }
    }
    return [pscustomobject]@{
        fileName = [string]$azPath
        prefix = @()
    }
}

Export-ModuleMember -Function Invoke-BoundedProcess, Get-BoundedAzureCli
