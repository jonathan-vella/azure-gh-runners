$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\infra\spike7\Comparison.psm1') -Force

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

function Invoke-MockedComparison {
    param(
        [string[]] $Statuses,
        [bool] $ExpectSuccess
    )

    $script:bypassChanges = [System.Collections.Generic.List[string]]::new()
    $script:caseIndex = 0
    $setBypass = {
        param($Value)
        $script:bypassChanges.Add([string]$Value)
    }
    $runCase = {
        param($Value)
        $status = $Statuses[$script:caseIndex]
        $script:caseIndex++
        return $status
    }

    $caughtExpectedFailure = $false
    try {
        $result = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runCase
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
    $null = Invoke-SpikeBypassComparison -SetBypass $setBypass -RunCase $runOperationalFailure
    throw 'Expected operational failure to abort the comparison.'
} catch {
    if ($_.Exception.Message -notlike '*could not complete*') {
        throw
    }
}
Assert-Equal -Actual $script:operationalCaseCount -Expected 1 -Name 'Operational failure stops follow-up case'
Assert-Equal -Actual ($script:bypassChanges -join ',') -Expected 'None,None' -Name 'Operational failure restores bypass'

Write-Output 'Issue-7 comparison mocked-status tests passed.'
