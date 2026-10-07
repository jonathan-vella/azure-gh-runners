$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\SpikeIdentity-Cleanup.psm1') -Force

$expected = @{
    ExpectedDisplayName = 'sp-ghrunners-spike10-test1'
    ExpectedResourceGroup = '/subscriptions/sub/resourceGroups/rg-ghrunners-spike10-swc'
    ExpectedPullIdentity = '/subscriptions/sub/resourceGroups/rg-ghrunners-spike10-swc/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test'
    ExpectedCredentialName = 'spike10-platform-prod'
    ExpectedIssuer = 'https://token.actions.githubusercontent.com'
    ExpectedSubject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod'
    ExpectedAudience = 'api://AzureADTokenExchange'
}
$app = [pscustomobject]@{
    appId = '00000000-0000-0000-0000-000000000001'
    displayName = $expected.ExpectedDisplayName
    passwordCredentials = @()
    keyCredentials = @()
}
$servicePrincipal = [pscustomobject]@{
    appId = $app.appId
    id = '00000000-0000-0000-0000-000000000002'
    displayName = $expected.ExpectedDisplayName
}
$expectedAssignment = [pscustomobject]@{
    roleDefinitionName = 'Contributor'
    scope = $expected.ExpectedResourceGroup
}
$expectedCredential = [pscustomobject]@{
    name = $expected.ExpectedCredentialName
    issuer = $expected.ExpectedIssuer
    subject = $expected.ExpectedSubject
    audiences = @($expected.ExpectedAudience)
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    try { & $Action } catch { return }
    throw $Message
}

if (-not (Assert-SpikeIdentityCleanupState @expected -App $app -ServicePrincipal $servicePrincipal `
    -Assignments @() -FederatedCredentials @())) {
    throw 'Cleanup should remain safe when the resource group, pull identity, and partial app grants are already absent.'
}
if (-not (Assert-SpikeIdentityCleanupState @expected -App $app -ServicePrincipal $servicePrincipal `
    -Assignments @($expectedAssignment) -FederatedCredentials @($expectedCredential))) {
    throw 'Cleanup should accept a partial bootstrap with one expected assignment and FIC.'
}
if (Assert-SpikeIdentityCleanupState @expected -App $null -ServicePrincipal $null `
    -Assignments @() -FederatedCredentials @()) {
    throw 'Repeated cleanup should treat an already absent app/service principal as complete.'
}
Assert-Throws -Action {
    Assert-SpikeIdentityCleanupState @expected -App $app -ServicePrincipal $servicePrincipal `
        -Assignments @([pscustomobject]@{ roleDefinitionName = 'Contributor'; scope = '/subscriptions/other' }) `
        -FederatedCredentials @()
} -Message 'Cleanup must reject grants outside the exact spike scope.'
Assert-Throws -Action {
    Assert-SpikeIdentityCleanupState @expected -App $app -ServicePrincipal $servicePrincipal `
        -Assignments @() `
        -FederatedCredentials @([pscustomobject]@{ name = 'unexpected'; issuer = $expected.ExpectedIssuer; subject = $expected.ExpectedSubject; audiences = @($expected.ExpectedAudience) })
} -Message 'Cleanup must reject an unexpected FIC.'
Assert-Throws -Action {
    Assert-SpikeIdentityCleanupState @expected -App $app -ServicePrincipal $servicePrincipal `
        -Assignments @() `
        -FederatedCredentials @([pscustomobject]@{
            name = $expected.ExpectedCredentialName
            issuer = $expected.ExpectedIssuer
            subject = $expected.ExpectedSubject
            audiences = @($expected.ExpectedAudience, 'https://unexpected.example')
        })
} -Message 'Cleanup must reject an expected FIC with an unexpected additional audience.'
Assert-Throws -Action {
    Assert-SpikeIdentityCleanupState @expected `
        -App ([pscustomobject]@{ displayName = $expected.ExpectedDisplayName; passwordCredentials = @(@{ keyId = 'unexpected' }); keyCredentials = @() }) `
        -ServicePrincipal $servicePrincipal -Assignments @() -FederatedCredentials @()
} -Message 'Cleanup must reject an app with reusable password credentials.'

Write-Output 'Temporary identity cleanup mock assertions passed.'
