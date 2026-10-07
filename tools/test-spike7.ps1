$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\infra\spike7\Invoke-Spike.ps1') -Action Validate

function Assert-Equal {
    param(
        [Parameter(Mandatory)][object] $Actual,
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][string] $Name
    )
    if ($Actual -cne $Expected) {
        throw "$Name expected '$Expected' but got '$Actual'."
    }
}

$d4Environment = [pscustomobject]@{
    properties = [pscustomobject]@{
        provisioningState = 'Succeeded'
        zoneRedundant = $false
        workloadProfiles = @(
            [pscustomobject]@{ name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1 },
            [pscustomobject]@{ name = 'D4'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 3 }
        )
    }
}
$d4Profile = Assert-EnvironmentProfile -EnvironmentState $d4Environment -ExpectedProfile D4
Assert-Equal $d4Profile.minimumCount 0 'D4 minimumCount readback'
Assert-Equal $d4Profile.maximumCount 3 'D4 maximumCount readback'
$consumptionEnvironment = [pscustomobject]@{
    properties = [pscustomobject]@{
        provisioningState = 'Succeeded'
        zoneRedundant = $false
        workloadProfiles = @([pscustomobject]@{
            name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1
        })
    }
}
$consumptionProfile = Assert-EnvironmentProfile -EnvironmentState $consumptionEnvironment -ExpectedProfile Consumption
Assert-Equal $consumptionProfile.maximumCount 1 'Consumption default remains unchanged'
Assert-Equal $consumptionEnvironment.properties.zoneRedundant $false 'Consumption remains non-zonal'

foreach ($invalidEnvironment in @(
    [pscustomobject]@{
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; zoneRedundant = $false
            workloadProfiles = @(
                [pscustomobject]@{ name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1 },
                [pscustomobject]@{ name = 'D4'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 2 }
            )
        }
    },
    [pscustomobject]@{
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; zoneRedundant = $true
            workloadProfiles = @(
                [pscustomobject]@{ name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1 },
                [pscustomobject]@{ name = 'D4'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 3 }
            )
        }
    },
    [pscustomobject]@{
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; zoneRedundant = $true
            workloadProfiles = @([pscustomobject]@{
                name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1
            })
        }
    },
    [pscustomobject]@{
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; zoneRedundant = $false
            workloadProfiles = @(
                [pscustomobject]@{ name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1 },
                [pscustomobject]@{ name = 'D4'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 3; zones = @('1') }
            )
        }
    },
    [pscustomobject]@{
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; zoneRedundant = $false; zones = @('1')
            workloadProfiles = @(
                [pscustomobject]@{ name = 'Consumption'; workloadProfileType = 'Consumption'; minimumCount = 0; maximumCount = 1 },
                [pscustomobject]@{ name = 'D4'; workloadProfileType = 'D4'; minimumCount = 0; maximumCount = 3 }
            )
        }
    }
)) {
    $rejected = $false
    try {
        $null = Assert-EnvironmentProfile -EnvironmentState $invalidEnvironment -ExpectedProfile D4
    } catch {
        $rejected = $true
    }
    Assert-Equal $rejected $true 'Invalid D4 profile readback rejected'
}

function Invoke-MockedComparison {
    param(
        [string[]] $Statuses,
        [bool] $ExpectSuccess
    )

    $script:bypassChanges = [System.Collections.Generic.List[string]]::new()
    $script:caseIndex = 0
    $script:recordedResults = [System.Collections.Generic.List[object]]::new()
    $recordResult = {
        param($Bypass, $Result)
        $script:recordedResults.Add($Result)
    }
    $setBypass = {
        param($Value)
        $script:bypassChanges.Add([string]$Value)
    }
    $runCase = {
        param($Value)
        $status = $Statuses[$script:caseIndex]
        $script:caseIndex++
        return [pscustomobject]@{
            Status = $status; Stage = 'execution'; Code = $null
            JobName = 'mock-job'; ExecutionName = 'mock-execution'; DeploymentName = 'mock-deployment'
        }
    }

    $caughtExpectedFailure = $false
    try {
        $result = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runCase -RecordResult $recordResult
        Assert-Equal -Actual $result.None -Expected $Statuses[0] -Name 'None result'
        Assert-Equal -Actual $result.AzureServices -Expected $Statuses[1] -Name 'AzureServices result'
    } catch {
        if ($ExpectSuccess) {
            throw
        }
        if ($_.Exception.Message -notlike '*Neither trusted-services configuration*') {
            throw
        }
        $caughtExpectedFailure = $true
    }
    if (-not $ExpectSuccess -and -not $caughtExpectedFailure) {
        throw 'Expected comparison to reject both unsuccessful cases.'
    }

    Assert-Equal -Actual $script:caseIndex -Expected 2 -Name 'Number of comparison cases'
    Assert-Equal -Actual $script:recordedResults.Count -Expected 2 -Name 'Both terminal results persisted'
    Assert-Equal -Actual ($script:bypassChanges -join ',') -Expected 'None,AzureServices,None' -Name 'Bypass restoration sequence'
}

Invoke-MockedComparison -Statuses @('Failed', 'Succeeded') -ExpectSuccess $true
Invoke-MockedComparison -Statuses @('Succeeded', 'Succeeded') -ExpectSuccess $true
Invoke-MockedComparison -Statuses @('Failed', 'Failed') -ExpectSuccess $false

$script:bypassChanges = [System.Collections.Generic.List[string]]::new()
$script:operationalCaseCount = 0
$setBypass = {
    param($Value)
    $script:bypassChanges.Add([string]$Value)
}
$runOperationalFailure = {
    param($Value)
    $script:operationalCaseCount++
    throw 'Mocked infrastructure error.'
}
try {
    $null = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runOperationalFailure -RecordResult { param($Bypass, $Result) }
    throw 'Expected operational failure to abort the comparison.'
} catch {
    if ($_.Exception.Message -notlike '*could not complete*') {
        throw
    }
}
Assert-Equal -Actual $script:operationalCaseCount -Expected 1 -Name 'Operational failure stops follow-up case'
Assert-Equal -Actual ($script:bypassChanges -join ',') -Expected 'None,None' -Name 'Operational failure restores bypass'

function Get-RemainingTestSeconds { return 60 }
function Invoke-AzBounded { return 1 }
function Invoke-AzJson {
    param([string[]] $Arguments)
    if (($Arguments[0..3] -join ' ') -cne 'deployment operation group list') {
        throw 'Unexpected mocked Azure call.'
    }
    if ($Arguments[-1] -cne 'job-abcdefghijklm') {
        return [pscustomobject]@{
            properties = @{
                provisioningState = 'Failed'
                targetResource = @{
                    id = "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup/providers/Microsoft.Resources/deployments/job-abcdefghijklm"
                }
                statusMessage = @{ error = @{ code = 'DeploymentFailed' } }
            }
        }
    }
    $jobName = $script:legEvidence.JobName
    return [pscustomobject]@{
        properties = @{
            provisioningState = 'Failed'
            targetResource = @{
                id = "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup/providers/Microsoft.App/jobs/$jobName"
            }
            statusMessage = @{
                error = @{
                    code = 'ResourceDeploymentFailure'
                    details = @(@{ code = 'Forbidden'; innererror = @{ code = $script:providerCode } })
                    message = 'SENSITIVE MOCK VALUE MUST NOT BE RECORDED'
                }
            }
        }
    }
}
$script:runSuffix = 'abcdef12'
$script:providerCode = 'ForbiddenByFirewall'
$script:recordedResults = [System.Collections.Generic.List[object]]::new()
$script:bypassChanges = [System.Collections.Generic.List[string]]::new()
$script:provisioningCases = 0
$runProvisioningCase = {
    param($Bypass)
    $script:provisioningCases++
    if ($Bypass -ceq 'AzureServices') {
        return [pscustomobject]@{
            Status = 'Succeeded'; Stage = 'execution'; Code = $null
            JobName = 'fresh-services-job'; ExecutionName = 'fresh-services-execution'; DeploymentName = 'services-deployment'
        }
    }
    Invoke-DiagnosticCase -Bypass $Bypass -EnvironmentId 'mock-env' -IdentityId 'mock-identity' `
        -KeyVaultSecretUrl 'https://mock.vault.azure.net/secrets/probe' -ProbeDigest ('0' * 64)
}
$recordResult = {
    param($Bypass, $Result)
    $script:recordedResults.Add($Result)
}
$result = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runProvisioningCase -RecordResult $recordResult
Assert-Equal $result.None 'Failed' 'Provisioning denial is expected'
Assert-Equal $result.AzureServices 'Succeeded' 'Comparison continues after provisioning denial'
Assert-Equal $script:recordedResults[0].Stage 'job-provisioning' 'Job provisioning stage recorded'
Assert-Equal $script:recordedResults[0].Code 'ForbiddenByFirewall' 'Only documented code recorded'
Assert-Equal ($script:recordedResults[0].JobName -match '^caj-ghr7-abcdef12-none-[a-f0-9]{8}$') $true 'Fresh failed job name recorded'
Assert-Equal ($null -eq $script:recordedResults[0].ExecutionName) $true 'No execution claimed for provisioning denial'
Assert-Equal $script:recordedResults[1].ExecutionName 'fresh-services-execution' 'Execution name recorded'
Assert-Equal ($script:bypassChanges -join ',') 'None,AzureServices,None' 'Provisioning denial restores ACL'
Assert-Equal (($script:recordedResults | ConvertTo-Json -Depth 4) -match 'SENSITIVE') $false 'Provider messages excluded'

foreach ($code in @('AKSCapacityHeavyUsage', 'InvalidTemplate', 'AuthorizationFailed', 'ForbiddenByRbac', 'AccessDenied', 'UnknownCode', 'KeyVaultSecretRefIdentityError')) {
    $script:providerCode = $code
    $script:provisioningCases = 0
    $script:recordedResults.Clear()
    $script:bypassChanges.Clear()
    try {
        $null = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runProvisioningCase -RecordResult $recordResult
        throw 'Expected unrelated provisioning failure to abort.'
    } catch {
        if ($_.Exception.Message -notlike '*could not complete*') { throw }
    }
    Assert-Equal $script:provisioningCases 1 "$code aborts before Services"
    Assert-Equal $script:recordedResults[0].Status 'OperationalError' "$code recorded as operational"
    Assert-Equal ($script:recordedResults[0].Code -split ',' -ccontains $code) $true "$code preserved without provider message"
    Assert-Equal ($script:bypassChanges -join ',') 'None,None' "$code restores ACL"
}
Assert-Equal (Test-SpikeKeyVaultNetworkDenial @{
    code = 'DeploymentFailed'
    details = @(@{ code = 'ForbiddenByFirewall' }, @{ code = 'AuthorizationFailed' })
}) $false 'Mixed network/RBAC failure rejected'
Assert-Equal (Test-SpikeKeyVaultNetworkDenial @{ code = 'Forbidden'; message = 'ForbiddenByFirewall' }) $false 'Message-only code rejected'
Assert-Equal (Test-SpikeKeyVaultNetworkDenial @{
    code = 'DeploymentFailed'; details = @(@{ code = 'ForbiddenByFirewall' }, @{ code = 'Forbidden' })
}) $false 'Unexplained Forbidden leaf rejected'
Assert-Equal (Get-SpikeSanitizedErrorCode @{ code = "invalid`ncode"; message = 'SENSITIVE' }) 'UnclassifiedDeploymentFailure' 'Invalid code excluded'

$evidencePath = Join-Path ([System.IO.Path]::GetTempPath()) "issue7-mock-$([guid]::NewGuid().ToString('N')).json"
$records = [System.Collections.Generic.List[object]]::new()
$script:bypassChanges.Clear()
try {
    try {
        $null = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase {
            param($Bypass)
            [pscustomobject]@{
                JobName = "fresh-$Bypass"; ExecutionName = "execution-$Bypass"
                DeploymentName = "deployment-$Bypass"; Status = 'Failed'; Stage = 'execution'
                Code = $null; Message = 'SENSITIVE MOCK VALUE'
            }
        } -RecordResult {
            param($Bypass, $Result)
            Write-SpikeComparisonEvidence -Path $evidencePath -Records $records -Bypass $Bypass -Result $Result
        }
        throw 'Expected both failed cases to reject acceptance.'
    } catch {
        if ($_.Exception.Message -notlike '*Neither trusted-services configuration*') { throw }
    }
    $json = [System.IO.File]::ReadAllText($evidencePath)
    $saved = @($json | ConvertFrom-Json)
    Assert-Equal $saved.Count 2 'Both failed legs survive acceptance rejection on disk'
    Assert-Equal $saved[1].executionName 'execution-AzureServices' 'Execution evidence persists on disk'
    Assert-Equal ($json -match 'SENSITIVE|Message') $false 'Evidence uses explicit safe field projection'
    Assert-Equal ($script:bypassChanges -join ',') 'None,AzureServices,None' 'Persisted failures restore ACL'
} finally {
    if (Test-Path -LiteralPath $evidencePath) { Remove-Item -LiteralPath $evidencePath }
}

Write-Output 'Issue-7 comparison mocked-status and provisioning callback tests passed.'
