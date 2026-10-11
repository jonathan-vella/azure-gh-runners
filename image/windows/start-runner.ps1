# Worker startup for the isolated Windows runner backend (ADR-0007). Installed as C:\ghr\start-runner.ps1 and
# run by the "ghr-start-runner" scheduled task (SYSTEM, at boot).
#
# Contract with the orchestrator: the VM is created with customData, which Windows drops at
# C:\AzureData\CustomData.bin as UTF-8 JSON:
#   {"version":1,"jitConfig":"<base64 from generate-jitconfig>","policy":{...},"expiresUtc":"<ISO-8601>"}
#
# Boot mode (default, SYSTEM): read and delete the file, validate it, write the policy to an ACL-restricted file
# for the pre-job hook, hand the JIT config to a dedicated non-admin local account, run the runner as that
# account, then power off. Every outcome ends in "shutdown /s /t 0" (fail closed).
# Job mode (-Mode Job, runs as the dedicated account): read and delete the JIT config file, then run
# C:\actions-runner\run.cmd --jitconfig with the policy hook registered.
#
# No Azure identity and no IMDS token are used. The JIT config and policy contents are never logged.
[CmdletBinding()]
param(
    [ValidateSet('Boot', 'Job')]
    [string]$Mode = 'Boot'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = 'C:\ghr'
$script:CustomDataPath = 'C:\AzureData\CustomData.bin'
$script:RunnerRoot = 'C:\actions-runner'
$script:PolicyPath = 'C:\ghr\policy.json'
$script:JitPath = 'C:\ghr\work\jit.cfg'
$script:HookPath = 'C:\ghr\hooks\job-started.ps1'
$script:LogPath = 'C:\ghr\logs\start-runner.log'
$script:JobLogPath = 'C:\ghr\logs\job.log'
$script:RunnerUser = 'ghr-runner'
$script:TaskName = 'ghr-runner-job'
$script:MaxConfigBytes = 131072
$script:MaxPolicyBytes = 65536
$script:CustomDataWaitSeconds = 900
# Longest allowed job (360 minutes) plus margin; the orchestrator enforces the per-consumer timeout.
$script:MaxRunMinutes = 390

function Write-Log {
    param([string]$Message)
    try {
        $directory = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogPath -Value ('{0:o} {1}' -f [DateTime]::UtcNow, $Message)
    }
    catch {
        # Logging must never block shutdown.
        $null = $_
    }
}

function Wait-CustomData {
    param([string]$Path = $script:CustomDataPath, [int]$TimeoutSeconds = $script:CustomDataWaitSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            return $false
        }
        Start-Sleep -Seconds 2
    }
    return $true
}

# Reads and deletes the file before parsing, then validates it. Error messages never include file content.
function Read-WorkerConfig {
    param([string]$Path = $script:CustomDataPath, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Remove-Item -LiteralPath $Path -Force
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $script:MaxConfigBytes) {
        throw 'worker config has an invalid size'
    }
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = $null
    try {
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($text)
        }
        catch {
            throw 'worker config is not valid JSON'
        }
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'worker config is not a JSON object'
        }
        $names = @($root.EnumerateObject() | ForEach-Object { $_.Name })
        if ($names.Count -ne 4 -or (@('version', 'jitConfig', 'policy', 'expiresUtc') | Where-Object { $names -cnotcontains $_ })) {
            throw 'worker config has unexpected fields'
        }
        $version = $root.GetProperty('version')
        $versionNumber = 0
        if ($version.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or -not $version.TryGetInt32([ref]$versionNumber) -or $versionNumber -ne 1) {
            throw 'worker config version is not supported'
        }
        $jit = $root.GetProperty('jitConfig')
        if ($jit.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
            throw 'worker config jitConfig is invalid'
        }
        $jitConfig = $jit.GetString()
        # Base64 (standard or URL-safe) only: the value is later passed on a command line.
        if ($jitConfig.Length -lt 16 -or $jitConfig.Length -gt 65536 -or -not [regex]::IsMatch($jitConfig, '\A[A-Za-z0-9+/_-]+={0,2}\z')) {
            throw 'worker config jitConfig is invalid'
        }
        $expiry = $root.GetProperty('expiresUtc')
        $expiryText = if ($expiry.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $expiry.GetString() } else { '' }
        $expiresAt = [DateTimeOffset]::MinValue
        if (-not [regex]::IsMatch($expiryText, '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z') -or
            -not [DateTimeOffset]::TryParse($expiryText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$expiresAt)) {
            throw 'worker config expiresUtc is invalid'
        }
        if ($expiresAt -le $Now) {
            throw 'worker config has expired'
        }
        $policy = $root.GetProperty('policy')
        if ($policy.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'worker config policy is invalid'
        }
        $policyNames = @($policy.EnumerateObject() | ForEach-Object { $_.Name })
        $expectedPolicy = @('repository', 'visibility', 'allowedEvents', 'allowedRefs', 'allowedWorkflows')
        if ($policyNames.Count -ne 5 -or ($expectedPolicy | Where-Object { $policyNames -cnotcontains $_ })) {
            throw 'worker config policy has unexpected fields'
        }
        $policyText = $policy.GetRawText()
        if ([System.Text.Encoding]::UTF8.GetByteCount($policyText) -gt $script:MaxPolicyBytes) {
            throw 'worker config policy is too large'
        }
        return [pscustomobject]@{ JitConfig = $jitConfig; PolicyJson = $policyText }
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Write-SecretFile {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Set-FileAcl {
    param([string]$Path, [string]$RunnerRights)
    & icacls.exe $Path /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(F)' 'BUILTIN\Administrators:(F)' "$($env:COMPUTERNAME)\$($script:RunnerUser):($RunnerRights)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'icacls failed' }
}

function New-RunnerAccount {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = 'Aa1!' + [Convert]::ToBase64String($bytes)
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    New-LocalUser -Name $script:RunnerUser -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member $script:RunnerUser
    return $password
}

# Windows Server grants "Log on as a batch job" only to Administrators and a few service groups, so the scheduled task
# for the non-admin runner account would be refused (logon failure 0xC000015B). Add the right for this account only.
function Grant-BatchLogonRight {
    $sid = (Get-LocalUser -Name $script:RunnerUser).SID.Value
    $inf = Join-Path $env:TEMP 'ghr-rights.inf'
    $db = Join-Path $env:TEMP 'ghr-rights.sdb'
    & secedit.exe /export /cfg $inf /areas USER_RIGHTS | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'secedit export failed' }
    $lines = @(Get-Content -LiteralPath $inf)
    $found = $false
    $updated = foreach ($line in $lines) {
        if ($line -match '^SeBatchLogonRight\s*=') { $found = $true; '{0},*{1}' -f $line, $sid } else { $line }
    }
    if (-not $found) {
        $updated = foreach ($line in $lines) {
            $line
            if ($line -match '^\[Privilege Rights\]') { 'SeBatchLogonRight = *{0}' -f $sid }
        }
    }
    Set-Content -LiteralPath $inf -Value $updated -Encoding Unicode
    & secedit.exe /configure /db $db /cfg $inf /areas USER_RIGHTS | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'secedit configure failed' }
    Remove-Item -LiteralPath $inf, $db -Force -ErrorAction SilentlyContinue
}

function Start-RunnerTask {
    param([string]$Password)
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Job' -f (Join-Path $script:Root 'start-runner.ps1')
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Settings $settings `
        -User "$($env:COMPUTERNAME)\$($script:RunnerUser)" -Password $Password -RunLevel Limited | Out-Null
    # The JIT file is deleted as soon as job mode reads it, so a leftover file means the task failed before reaching the runner.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Start-ScheduledTask -TaskName $script:TaskName
        Start-Sleep -Seconds 5
        $deadline = [DateTime]::UtcNow.AddMinutes($script:MaxRunMinutes)
        while ((Get-ScheduledTask -TaskName $script:TaskName).State -eq 'Running') {
            if ([DateTime]::UtcNow -ge $deadline) {
                Write-Log 'runner exceeded the maximum run time'
                Stop-ScheduledTask -TaskName $script:TaskName
                break
            }
            Start-Sleep -Seconds 5
        }
        Write-Log ('runner task attempt {0} finished with result {1}' -f $attempt, (Get-ScheduledTaskInfo -TaskName $script:TaskName).LastTaskResult)
        if (-not (Test-Path -LiteralPath $script:JitPath)) { break }
        Start-Sleep -Seconds 5
    }
}

function Invoke-Shutdown {
    Write-Log 'shutting down'
    & shutdown.exe /s /t 0
}

function Invoke-Boot {
    try {
        Write-Log 'boot: waiting for custom data'
        if (-not (Wait-CustomData)) {
            throw 'custom data did not arrive'
        }
        $config = Read-WorkerConfig
        Write-Log 'boot: worker config accepted'
        $password = New-RunnerAccount
        Grant-BatchLogonRight
        # The runner account cannot write the SYSTEM-owned boot log, so job mode logs to its own file.
        Write-SecretFile -Path $script:JobLogPath -Content ''
        Set-FileAcl -Path $script:JobLogPath -RunnerRights 'M'
        Write-SecretFile -Path $script:PolicyPath -Content $config.PolicyJson
        Set-FileAcl -Path $script:PolicyPath -RunnerRights 'R'
        Write-SecretFile -Path $script:JitPath -Content $config.JitConfig
        Set-FileAcl -Path $script:JitPath -RunnerRights 'R,D'
        & icacls.exe $script:RunnerRoot /grant "$($env:COMPUTERNAME)\$($script:RunnerUser):(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'icacls failed' }
        $config = $null
        Start-RunnerTask -Password $password
    }
    catch {
        # Only the exception type is logged: messages from parsing could echo untrusted content.
        Write-Log ('boot failed: {0}' -f $_.Exception.GetType().Name)
        if ($_.Exception -is [System.Management.Automation.RuntimeException] -and $_.Exception.Message -match '^(worker config|custom data)') {
            Write-Log ('reason: {0}' -f $_.Exception.Message)
        }
    }
    finally {
        Invoke-Shutdown
    }
}

function Invoke-Job {
    $script:LogPath = $script:JobLogPath
    $jit = [System.IO.File]::ReadAllText($script:JitPath).Trim()
    Remove-Item -LiteralPath $script:JitPath -Force
    if (-not [regex]::IsMatch($jit, '\A[A-Za-z0-9+/_-]+={0,2}\z')) {
        throw 'invalid JIT config'
    }
    $env:ACTIONS_RUNNER_HOOK_JOB_STARTED = $script:HookPath
    & (Join-Path $script:RunnerRoot 'run.cmd') --jitconfig $jit
    exit $LASTEXITCODE
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Mode -eq 'Job') {
        try {
            Invoke-Job
        }
        catch {
            Write-Log ('job failed: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
            exit 1
        }
    }
    else {
        Invoke-Boot
    }
}
