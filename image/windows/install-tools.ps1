# Installs the pinned toolset, the GitHub Actions runner and the worker startup files on a Windows Server 2025 build VM.
# Runs under Windows PowerShell 5.1 (az vm run-command) as SYSTEM, before PowerShell 7 exists, so keep it 5.1-compatible.
# Every download is verified against the SHA-256 in versions.json BEFORE it is extracted or executed; a mismatch fails the build.
# No identity, secret or credential is read or written. The runner is only extracted here; it is registered per job.
[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'versions.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$toolsRoot = 'C:\Tools'
$runnerRoot = 'C:\actions-runner'
$ghrRoot = 'C:\ghr'
$work = Join-Path $env:TEMP ('ghr-install-' + [guid]::NewGuid().ToString('N'))

function Get-VerifiedDownload {
    param($Tool, [string]$Name)
    if ($Tool.url -notmatch '^https://' -or $Tool.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "$Name has an invalid manifest entry"
    }
    $destination = Join-Path $work ([IO.Path]::GetFileName(([Uri]$Tool.url).LocalPath))
    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Tool.url -OutFile $destination -UseBasicParsing -MaximumRedirection 5 -PassThru
            $finalUri = if ($response.BaseResponse.PSObject.Properties['ResponseUri']) { $response.BaseResponse.ResponseUri } else { $response.BaseResponse.RequestMessage.RequestUri }
            if ($finalUri.Scheme -ne 'https') { throw "$Name redirected to a non-HTTPS location" }
            break
        }
        catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Tool.sha256) {
        Remove-Item -LiteralPath $destination -Force
        throw "$Name checksum mismatch: expected $($Tool.sha256), got $actual"
    }
    Write-Host "$Name $($Tool.version): checksum verified"
    return $destination
}

function Invoke-Installer {
    param([string]$File, [string[]]$Arguments)
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "$([IO.Path]::GetFileName($File)) failed with exit code $($process.ExitCode)" }
}

function Install-Msi {
    param([string]$File, [string[]]$Properties = @())
    Invoke-Installer -File "$env:SystemRoot\System32\msiexec.exe" -Arguments (@('/i', "`"$File`"", '/qn', '/norestart') + $Properties)
}

function Expand-Tool {
    param([string]$Archive, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

function Add-MachinePath {
    param([string]$Directory)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($current -split ';') -notcontains $Directory) {
        [Environment]::SetEnvironmentVariable('Path', ($current.TrimEnd(';') + ';' + $Directory), 'Machine')
    }
}

function Set-DirectoryAcl {
    param([string]$Path)
    # SYSTEM and Administrators may change the files; the dedicated job account reads and executes.
    # The ACL is rebuilt explicitly with well-known SIDs: icacls /inheritance:r left explicit Authenticated Users
    # entries on the first live image build.
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($acl.Access | ForEach-Object { $_.IdentityReference } | Sort-Object -Property Value -Unique)) {
        $acl.PurgeAccessRules($identity)
    }
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($entry[0])
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, $entry[1], $inherit, $propagation, 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    # Children created before this ACL existed keep stale inherited entries; reset them to inherit from the parent.
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        & icacls.exe $child.FullName /reset | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed for $($child.FullName)" }
    }
    Write-Host "ACL for ${Path}:"
    & icacls.exe $Path | Write-Host
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'x64 Windows is required' }
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'run as Administrator or SYSTEM'
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
    $downloads = $manifest.downloads

    Install-Msi -File (Get-VerifiedDownload $downloads.pwsh 'pwsh') -Properties @('ADD_PATH=1', 'DISABLE_TELEMETRY=1', 'ENABLE_MU=0', 'USE_MU=0', 'ENABLE_PSREMOTING=0', 'REGISTER_MANIFEST=0')
    Install-Msi -File (Get-VerifiedDownload $downloads.azureCli 'azureCli')

    Invoke-Installer -File (Get-VerifiedDownload $downloads.git 'git') -Arguments @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES')
    Invoke-Installer -File (Get-VerifiedDownload $downloads.python 'python') -Arguments @('/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0', 'Include_launcher=0', 'Include_doc=0')

    $nodeZip = Get-VerifiedDownload $downloads.node 'node'
    Expand-Tool -Archive $nodeZip -Destination (Join-Path $work 'node')
    $nodeDir = Join-Path $toolsRoot 'node'
    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
    Copy-Item -Path (Join-Path $work 'node\*\*') -Destination $nodeDir -Recurse -Force
    Add-MachinePath $nodeDir

    $bicepDir = Join-Path $toolsRoot 'bicep'
    New-Item -ItemType Directory -Path $bicepDir -Force | Out-Null
    Copy-Item -LiteralPath (Get-VerifiedDownload $downloads.bicep 'bicep') -Destination (Join-Path $bicepDir 'bicep.exe') -Force
    Add-MachinePath $bicepDir
    # Make "az bicep" use the pinned binary instead of downloading one at job time.
    [Environment]::SetEnvironmentVariable('AZURE_BICEP_USE_BINARY_FROM_PATH', 'true', 'Machine')

    $terraformDir = Join-Path $toolsRoot 'terraform'
    Expand-Tool -Archive (Get-VerifiedDownload $downloads.terraform 'terraform') -Destination $terraformDir
    Add-MachinePath $terraformDir

    # Runner: extracted only. Registration happens per job through the JIT config.
    if (Test-Path -LiteralPath $runnerRoot) { Remove-Item -LiteralPath $runnerRoot -Recurse -Force }
    Expand-Tool -Archive (Get-VerifiedDownload $manifest.runner 'runner') -Destination $runnerRoot

    # Worker files, root-owned and not writable by the job account.
    New-Item -ItemType Directory -Path (Join-Path $ghrRoot 'hooks') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir 'start-runner.ps1') -Destination (Join-Path $ghrRoot 'start-runner.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $SourceDir 'hooks\job-started.ps1') -Destination (Join-Path $ghrRoot 'hooks\job-started.ps1') -Force
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $ghrRoot 'versions.json') -Force
    # Kept on the image so a booted VM can be re-verified (the image build's test boot does exactly that).
    Copy-Item -LiteralPath (Join-Path $SourceDir 'verify-tools.ps1') -Destination (Join-Path $ghrRoot 'verify-tools.ps1') -Force
    Set-DirectoryAcl $ghrRoot

    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) { throw 'PowerShell 7 was not installed' }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ghr\start-runner.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'ghr-start-runner' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host 'install-tools: complete'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'C:\AzureData\CustomData.bin' -Force -ErrorAction SilentlyContinue
}
