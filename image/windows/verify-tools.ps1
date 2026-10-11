# Verifies a Windows runner image (or the build VM before generalization) against versions.json.
# Exits non-zero on the first mismatch. Runs under Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [string]$ManifestPath = 'C:\ghr\versions.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A fresh process may not have the machine-level PATH or variables that the installers set.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = [Environment]::GetEnvironmentVariable('AZURE_BICEP_USE_BINARY_FROM_PATH', 'Machine')

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ne $Actual) {
        throw "${Name}: expected $Expected, got $Actual"
    }
    Write-Host "${Name}: $Actual"
}

function Assert-True {
    param([string]$Name, $Condition)
    if (-not $Condition) { throw "${Name}: check failed" }
    Write-Host "${Name}: ok"
}

function Get-FirstVersion {
    param([string]$Text)
    $match = [regex]::Match($Text, '\d+\.\d+\.\d+')
    if (-not $match.Success) { throw "no version in: $Text" }
    return $match.Value
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$downloads = $manifest.downloads
$runnerListener = 'C:\actions-runner\bin\Runner.Listener.exe'

Assert-True 'runner executable' (Test-Path -LiteralPath $runnerListener)
Assert-True 'runner run.cmd' (Test-Path -LiteralPath 'C:\actions-runner\run.cmd')
Assert-Equal 'runner' $manifest.runner.version ((& $runnerListener --version) | Select-Object -First 1).Trim()
Assert-Equal 'node' $downloads.node.version ((& node --version) -replace '^v', '').Trim()
Assert-Equal 'git' $downloads.git.version (Get-FirstVersion (& git --version))
Assert-Equal 'python' $downloads.python.version (Get-FirstVersion (& python --version))
Assert-Equal 'pwsh' $downloads.pwsh.version ((& pwsh -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()') | Select-Object -First 1).Trim()
Assert-Equal 'azureCli' $downloads.azureCli.version ((& az version --output json) -join '' | ConvertFrom-Json).'azure-cli'
Assert-Equal 'bicep' $downloads.bicep.version (Get-FirstVersion (& bicep --version))
Assert-Equal 'azureCliBicep' $downloads.bicep.version (Get-FirstVersion (& az bicep version))
Assert-Equal 'terraform' $downloads.terraform.version ((& terraform version -json) -join '' | ConvertFrom-Json).terraform_version

# Worker files and boot task.
foreach ($file in 'C:\ghr\start-runner.ps1', 'C:\ghr\hooks\job-started.ps1', 'C:\ghr\versions.json') {
    Assert-True "worker file $file" (Test-Path -LiteralPath $file -PathType Leaf)
}
$task = Get-ScheduledTask -TaskName 'ghr-start-runner'
Assert-Equal 'boot task principal' 'SYSTEM' $task.Principal.UserId
Assert-True 'boot task starts at boot' (@($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -eq 1)

# Only SYSTEM and Administrators may change the hook, the startup script or the policy directory.
$writeRights = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
$trusted = 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'NT SERVICE\TrustedInstaller'
foreach ($path in 'C:\ghr', 'C:\ghr\start-runner.ps1', 'C:\ghr\hooks\job-started.ps1') {
    foreach ($rule in (Get-Acl -LiteralPath $path).Access) {
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeRights) -and $trusted -notcontains $rule.IdentityReference.Value) {
            throw "$path is writable by $($rule.IdentityReference.Value)"
        }
    }
}
Write-Host 'worker file ACLs: ok'

# Nothing identity- or job-specific may be baked in.
Assert-True 'job account absent' ($null -eq (Get-LocalUser -Name 'ghr-runner' -ErrorAction SilentlyContinue))
Assert-True 'custom data absent' (-not (Test-Path -LiteralPath 'C:\AzureData\CustomData.bin'))
Assert-True 'runner not registered' (-not (Test-Path -LiteralPath 'C:\actions-runner\.runner'))
& cmd.exe /c 'az account show >nul 2>nul'
Assert-True 'no Azure login baked in' ($LASTEXITCODE -ne 0)
Write-Host 'verify-tools: complete'
