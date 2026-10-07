$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'spike-acr-agentpool.ps1') -Action Setup

function Assert-Equal {
    param([string]$Name, [object]$Expected, [object]$Actual)
    if ($Expected -cne $Actual) { throw "Failed: $Name" }
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
    } catch {
        return
    }
    throw "Failed: $Name did not reject invalid input."
}

$metadata = [pscustomobject]@{
    full_name = 'jonathan-vella/azure-gh-runners'
    name = 'azure-gh-runners'
    owner_login = 'jonathan-vella'
    owner_id = '25802147'
    repository_id = '1408821667'
}
$customization = [pscustomobject]@{
    use_default = $true
    use_immutable_subject = $true
    sub_claim_prefix = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667'
}
$expectedSubject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:ref:refs/heads/main'

Assert-Equal 'metadata-derived subject' $expectedSubject `
    (Get-SpikeFederatedSubjectFromMetadata -Metadata $metadata -Customization $customization)

$wrongOwnerId = $metadata.PSObject.Copy()
$wrongOwnerId.owner_id = '25802148'
Assert-Throws 'unexpected owner ID' {
    Get-SpikeFederatedSubjectFromMetadata -Metadata $wrongOwnerId -Customization $customization
}

$wrongRepositoryId = $metadata.PSObject.Copy()
$wrongRepositoryId.repository_id = '1408821668'
Assert-Throws 'unexpected repository ID' {
    Get-SpikeFederatedSubjectFromMetadata -Metadata $wrongRepositoryId -Customization $customization
}

$wrongCustomization = $customization.PSObject.Copy()
$wrongCustomization.use_immutable_subject = $false
Assert-Throws 'disabled immutable subjects' {
    Get-SpikeFederatedSubjectFromMetadata -Metadata $metadata -Customization $wrongCustomization
}

$wrongCustomization = $customization.PSObject.Copy()
$wrongCustomization.sub_claim_prefix += '-unexpected'
Assert-Throws 'unexpected OIDC prefix' {
    Get-SpikeFederatedSubjectFromMetadata -Metadata $metadata -Customization $wrongCustomization
}

function gh {
    throw 'GitHub CLI is unavailable during cleanup.'
}
$script:cleanupAppDeleted = $false
$script:cleanupServicePrincipalDeleted = $false
$script:cleanupGroupRemoved = $false

function Remove-SpikeGroup {
    $script:cleanupGroupRemoved = $true
}

function Get-AzJson {
    param([string[]]$Arguments)
    $command = $Arguments -join ' '
    if ($command -like 'ad app list *') {
        if ($script:cleanupAppDeleted) { return @() }
        return @([pscustomobject]@{
            appId = '11111111-1111-1111-1111-111111111111'
            displayName = 'sp-ghrunners-spike6-20261007'
            passwordCredentials = @()
            keyCredentials = @()
        })
    }
    if ($command -like 'ad app federated-credential list *') {
        return @([pscustomobject]@{
            name = 'ghrunners-spike6-main'
            subject = $expectedSubject
            issuer = 'https://token.actions.githubusercontent.com'
            audiences = @('api://AzureADTokenExchange')
        })
    }
    if ($command -like 'ad sp list *') {
        if ($script:cleanupServicePrincipalDeleted) { return @() }
        return @([pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222' })
    }
    if ($command -like 'role assignment list *') { return @() }
    throw "Unexpected Azure read during cleanup test: $command"
}

function Invoke-Az {
    param([string[]]$Arguments)
    if ($Arguments -contains 'sp' -and $Arguments -contains 'delete') {
        $script:cleanupServicePrincipalDeleted = $true
        return
    }
    if ($Arguments -contains 'app' -and $Arguments -contains 'delete') {
        $script:cleanupAppDeleted = $true
        return
    }
    throw "Unexpected Azure write during cleanup test: $($Arguments -join ' ')"
}

function az {
    $global:LASTEXITCODE = 0
    return 'false'
}

Invoke-SpikeCleanup -ClientId '11111111-1111-1111-1111-111111111111' | Out-Null
Assert-Equal 'cleanup removed the resource group' $true $script:cleanupGroupRemoved
Assert-Equal 'cleanup removed the service principal' $true $script:cleanupServicePrincipalDeleted
Assert-Equal 'cleanup removed the app' $true $script:cleanupAppDeleted

Write-Output 'Spike 6 OIDC helper tests passed.'
