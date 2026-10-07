[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [string] $ResourceGroupName = 'rg-ghrunners-spike7-swc',
    [ValidateSet('Consumption', 'D4')][string] $Profile = 'Consumption',
    [ValidateRange(1, 45)][int] $TimeoutMinutes = 45,
    [switch] $ConfirmCapacityRecovered,
    [switch] $ConfirmD4ProfileAttempt,
    [Parameter(Mandatory)][string] $EvidencePath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lifecycle.psm1') -Force
$runner = Join-Path $PSScriptRoot 'Invoke-Spike.ps1'
$scope = @{
    SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName
    TimeoutMinutes = $TimeoutMinutes
}
$attempt = @{
    Profile = $Profile; ConfirmCapacityRecovered = $ConfirmCapacityRecovered
    ConfirmD4ProfileAttempt = $ConfirmD4ProfileAttempt
}
. $runner -Action Validate @scope @attempt -EvidencePath $EvidencePath
$script:actionDeadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
Assert-ApprovedScope
Assert-ProfileAuthorization
if (Get-ResourceGroupExists) {
    throw 'Lifecycle requires the exact absent spike resource group; no existing group was changed.'
}
Invoke-SpikeLifecycle `
    -Deploy { & $runner -Action Deploy @scope @attempt } `
    -Test { & $runner -Action Test @scope @attempt -EvidencePath $EvidencePath } `
    -Diagnose { & $runner -Action Diagnose @scope } `
    -Cleanup { & $runner -Action Cleanup @scope }
