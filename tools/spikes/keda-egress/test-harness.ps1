$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'Lifecycle.psm1') -Force
. (Join-Path $scriptRoot 'run.ps1') -Mode Validate

function Assert-Equal {
    param(
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Actual -cne $Expected) {
        throw "$Name expected '$Expected' but received '$Actual'."
    }
}

$apiPrefixes = @('192.0.2.0/24')
$rules = @(Get-NsgOutboundRules -ApiPrefixes $apiPrefixes)
Assert-Equal (@($rules | Select-Object -ExpandProperty priority | Where-Object { $_ -lt 100 -or $_ -gt 4096 }).Count) 0 'Valid NSG priority range'
Assert-Equal (@($rules | Group-Object name | Where-Object Count -ne 1).Count) 0 'Unique NSG rule names'
$acaAllow = @($rules | Where-Object name -eq 'AllowAcaSubnetDependencies')
Assert-Equal $acaAllow.Count 1 'Same-subnet platform dependency allow'
Assert-Equal $acaAllow[0].source $acaAllow[0].destination[0] 'Same-subnet allow is source/destination restricted'
$apiAllow = @($rules | Where-Object name -eq 'AllowGitHubApiHttps')[0]
$apiDeny = Get-GitHubApiDenyRule -ApiPrefixes $apiPrefixes
Assert-Equal ($apiDeny.priority -ge 100) $true 'API deny priority minimum'
Assert-Equal ($apiDeny.priority -lt $apiAllow.priority) $true 'API deny precedes API allow'
Assert-Equal $apiAllow.destination[0] $apiPrefixes[0] 'GitHub API allow CIDR'

$partialResources = @(
    [pscustomobject]@{ name = 'nsg-spike8-egress-swc'; id = '/nsg'; tags = @{ 'spike-id' = '8' } },
    [pscustomobject]@{ name = 'caj-spike8-keda'; id = '/job'; tags = @{ 'spike-id' = '8' } },
    [pscustomobject]@{ name = 'vnet-spike8-egress-swc'; id = '/vnet'; tags = @{ 'spike-id' = '8' } }
)
$plan = @(Get-CleanupResourcePlan -Resources $partialResources)
Assert-Equal ($plan.id -join ',') '/job,/vnet,/nsg' 'Dependency-aware partial cleanup order'
$remainingAfterPartialDelete = @($partialResources | Where-Object id -notin @('/job', '/vnet'))
$retryPlan = @(Get-CleanupResourcePlan -Resources $remainingAfterPartialDelete)
Assert-Equal ($retryPlan.id -join ',') '/nsg' 'Retry plans only the undeleted resource'
Assert-Equal @(Get-CleanupResourcePlan -Resources @()).Count 0 'Repeated cleanup is an empty no-op'
$unknownRejected = $false
try {
    $null = Get-CleanupResourcePlan -Resources @([pscustomobject]@{ name = 'unowned-resource'; id = '/other'; tags = @{ 'spike-id' = '8' } })
} catch {
    $unknownRejected = $_.Exception.Message -like '*Unexpected resources*'
}
Assert-Equal $unknownRejected $true 'Cleanup refuses an unowned resource'

$workflowPrincipal = '11111111-1111-4111-8111-111111111111'
$workloadPrincipal = '22222222-2222-4222-8222-222222222222'
$vaultScope = '/subscriptions/shared/resourceGroups/spike/providers/Microsoft.KeyVault/vaults/test'
$allowedVaultRoles = @{
    '4633458b-17de-408a-b874-0445c86b69e6' = $workloadPrincipal
    'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' = $workflowPrincipal
}
$emptyAssignments = @(Get-ValidatedScopedAssignments -Assignments @() -Scope $vaultScope -AllowedRolePrincipals $allowedVaultRoles)
Assert-Equal $emptyAssignments.Count 0 'Zero role assignment partial preparation'
$oneAssignment = @([pscustomobject]@{
    scope = $vaultScope
    principalId = $workloadPrincipal
    roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
    id = '/assignment'
})
$oneValidatedAssignment = @(Get-ValidatedScopedAssignments -Assignments $oneAssignment -Scope $vaultScope -AllowedRolePrincipals $allowedVaultRoles)
Assert-Equal $oneValidatedAssignment.Count 1 'Single role assignment partial preparation'
$missingPrincipalRejected = $false
try {
    $null = Get-ValidatedScopedAssignments -Assignments $oneAssignment -Scope $vaultScope -AllowedRolePrincipals @{
        '4633458b-17de-408a-b874-0445c86b69e6' = $null
        'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' = $workflowPrincipal
    }
} catch {
    $missingPrincipalRejected = $_.Exception.Message -like '*exact recorded principal*'
}
Assert-Equal $missingPrincipalRejected $true 'Cleanup requires exact recorded principal for present assignments'
$repeatedCleanupAssignments = @(Get-ValidatedScopedAssignments -Assignments @() -Scope $vaultScope -AllowedRolePrincipals $allowedVaultRoles)
Assert-Equal $repeatedCleanupAssignments.Count 0 'Repeated role cleanup is an empty no-op'

$script:environment = 'acaenv-spike8-egress-swc'
$script:scalerJob = 'caj-spike8-keda'
$script:mockLogs = @(
    [pscustomobject]@{
        TimeGenerated = '2026-10-07T18:00:00Z'
        properties = @{ source = 'KEDA'; scalerName = 'github-runner'; jobName = 'caj-spike8-keda'; severity = 'Error' }
    },
    [pscustomobject]@{
        TimeGenerated = '2026-10-07T18:00:01Z'
        properties = @{ source = 'KEDA'; scalerName = 'other-rule'; jobName = 'caj-spike8-keda'; severity = 'Error' }
    },
    [pscustomobject]@{ message = 'KEDA unrelated free-text log must not count' }
) | ConvertTo-Json -Depth 8 -Compress
function Invoke-Az {
    param([string[]]$Arguments)
    [void]$script:capturedAzArguments.Add(@($Arguments))
    return $script:mockLogs
}
$script:capturedAzArguments = [System.Collections.Generic.List[object]]::new()
Set-NsgOutboundRules -ApiPrefixes $apiPrefixes
$emittedRules = @($script:capturedAzArguments | Where-Object {
    $_[0] -eq 'network' -and $_[1] -eq 'nsg' -and $_[2] -eq 'rule' -and $_[3] -eq 'create'
})
Assert-Equal $emittedRules.Count $rules.Count 'Runtime emits every shared NSG rule'
$emittedPriorities = @()
foreach ($arguments in $emittedRules) {
    $sourceIndex = [Array]::IndexOf([string[]]$arguments, '--source-address-prefixes')
    $priorityIndex = [Array]::IndexOf([string[]]$arguments, '--priority')
    $destinationIndex = [Array]::IndexOf([string[]]$arguments, '--destination-address-prefixes')
    Assert-Equal ($sourceIndex -ge 0) $true 'Runtime NSG rule source argument exists'
    Assert-Equal ($priorityIndex -ge 0) $true 'Runtime NSG rule priority argument exists'
    Assert-Equal ($destinationIndex -ge 0) $true 'Runtime NSG rule destination argument exists'
    Assert-Equal $arguments[$sourceIndex + 1] '10.252.8.0/27' 'Runtime NSG rule includes its source subnet'
    $emittedPriorities += [int]$arguments[$priorityIndex + 1]
}
Assert-Equal (@($emittedPriorities | Where-Object { $_ -lt 100 -or $_ -gt 4096 }).Count) 0 'Runtime NSG priorities are Azure-valid'
$runtimeApiDeny = @($emittedRules | Where-Object {
    $nameIndex = [Array]::IndexOf([string[]]$_, '--name')
    $_[$nameIndex + 1] -eq 'DenyGitHubApiForSpike8'
})
Assert-Equal $runtimeApiDeny.Count 0 'Separate deny-test rule is not installed in the baseline'
$runtimeApiAllow = @($emittedRules | Where-Object {
    $nameIndex = [Array]::IndexOf([string[]]$_, '--name')
    $_[$nameIndex + 1] -eq 'AllowGitHubApiHttps'
})
Assert-Equal $runtimeApiAllow.Count 1 'Runtime emits GitHub API allow rule'
$runtimeAllowDestinationIndex = [Array]::IndexOf([string[]]$runtimeApiAllow[0], '--destination-address-prefixes')
Assert-Equal $runtimeApiAllow[0][$runtimeAllowDestinationIndex + 1] $apiPrefixes[0] 'Runtime API allow contains fetched prefixes'
$start = [DateTime]::Parse('2026-10-07T17:59:00Z')
$end = [DateTime]::Parse('2026-10-07T18:01:00Z')
$events = Get-KedaEvents -StartTime $start -EndTime $end
Assert-Equal $events.sampleCount 1 'Only exact rule and job events count'
Assert-Equal $events.errorCount 1 'Error count includes only attributed events'
Assert-Equal $events.unattributedKedaRecordCount 1 'Unrelated structured KEDA events are reported separately'
$script:mockLogs = @([pscustomobject]@{
    TimeGenerated = '2026-10-07T18:00:01Z'
    properties = @{ source = 'KEDA'; scalerName = 'another-rule'; jobName = 'another-job'; severity = 'Error' }
}) | ConvertTo-Json -Depth 5 -Compress
$unrelatedOnly = Get-KedaEvents -StartTime $start -EndTime $end
Assert-Equal $unrelatedOnly.sampleCount 0 'Unrelated KEDA logs do not yield successful evidence'

$pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timeoutRejected = $false
try {
    $null = Invoke-BoundedProcess -FileName $pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -TimeoutSeconds 1
} catch {
    $timeoutRejected = $_.Exception.Message -like '*exceeded its 1-second limit*'
}
$stopwatch.Stop()
Assert-Equal $timeoutRejected $true 'A hung child process is terminated'
Assert-Equal ($stopwatch.Elapsed.TotalSeconds -lt 5) $true 'Subprocess timeout is enforced inside the caller'

$cliRoot = Join-Path ([System.IO.Path]::GetTempPath()) "keda-az-$([guid]::NewGuid().ToString('N'))"
$cliBin = Join-Path $cliRoot 'wbin'
try {
    $null = New-Item -ItemType Directory -Path $cliBin
    $azCmd = Join-Path $cliBin 'az.cmd'
    $azBare = Join-Path $cliBin 'az'
    $bundledPython = Join-Path $cliRoot 'python.exe'
    foreach ($file in @($azCmd, $azBare, $bundledPython)) { $null = New-Item -ItemType File -Path $file }
    $multipleCommands = @([pscustomobject]@{ Source = $azBare }, [pscustomobject]@{ Source = $azCmd })

    $windowsCli = Get-BoundedAzureCli -Candidates $multipleCommands -OnWindows $true
    Assert-Equal ($windowsCli.fileName -is [string]) $true 'Windows Azure CLI resolves one Python path'
    Assert-Equal $windowsCli.fileName $bundledPython 'Windows prefers az.cmd and its bundled Python'
    Assert-Equal ($windowsCli.prefix -join ' ') '-IBm azure.cli' 'Windows Azure CLI module prefix'

    $linuxCli = Get-BoundedAzureCli -Candidates $multipleCommands -OnWindows $false
    Assert-Equal $linuxCli.fileName $azBare 'Non-Windows keeps the first executable'
    Assert-Equal @($linuxCli.prefix).Count 0 'Non-Windows executable has no prefix'

    $null = New-Item -ItemType File -Path (Join-Path $cliBin 'python.exe')
    $ambiguousPythonRejected = $false
    try {
        $null = Get-BoundedAzureCli -Candidates $multipleCommands -OnWindows $true
    } catch {
        $ambiguousPythonRejected = $_.Exception.Message -like '*single managed Python*'
    }
    Assert-Equal $ambiguousPythonRejected $true 'Ambiguous bundled Python fails closed'

    $unsupportedRejected = $false
    try {
        $null = Get-BoundedAzureCli -Candidates @([pscustomobject]@{ Source = $azBare }) -OnWindows $true
    } catch {
        $unsupportedRejected = $_.Exception.Message -like '*supported Azure CLI*'
    }
    Assert-Equal $unsupportedRejected $true 'Windows rejects extensionless-only Azure CLI'
} finally {
    Remove-Item -LiteralPath $cliRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) {
    $installedCli = Get-BoundedAzureCli
    Assert-Equal ($installedCli.fileName -is [string]) $true 'Installed Azure CLI resolves one path'
    Assert-Equal (Test-Path -LiteralPath $installedCli.fileName -PathType Leaf) $true 'Installed Azure CLI path exists'
}

Write-Output 'KEDA spike functional harness tests passed.'
