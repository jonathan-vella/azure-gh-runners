function Assert-SpikeIdentityCleanupState {
    param(
        $App,
        $ServicePrincipal,
        [object[]]$Assignments = @(),
        [object[]]$FederatedCredentials = @(),
        [Parameter(Mandatory)][string]$ExpectedDisplayName,
        [Parameter(Mandatory)][string]$ExpectedResourceGroup,
        [Parameter(Mandatory)][string]$ExpectedPullIdentity,
        [Parameter(Mandatory)][string]$ExpectedCredentialName,
        [Parameter(Mandatory)][string]$ExpectedIssuer,
        [Parameter(Mandatory)][string]$ExpectedSubject,
        [Parameter(Mandatory)][string]$ExpectedAudience
    )

    if (-not $App -and -not $ServicePrincipal) {
        return $false
    }
    if (($App -and ($App.displayName -cne $ExpectedDisplayName -or
                    @($App.passwordCredentials).Count -gt 0 -or
                    @($App.keyCredentials).Count -gt 0)) -or
        ($ServicePrincipal -and $ServicePrincipal.displayName -cne $ExpectedDisplayName)) {
        throw 'The temporary Entra objects have an unexpected name or credential; refusing cleanup.'
    }
    if ($Assignments.Count -gt 2 -or
        @($Assignments | Where-Object {
            -not (($_.roleDefinitionName -eq 'Contributor' -and $_.scope -ieq $ExpectedResourceGroup) -or
                  ($_.roleDefinitionName -eq 'Managed Identity Operator' -and $_.scope -ieq $ExpectedPullIdentity))
        }).Count -gt 0 -or
        @($Assignments | Group-Object { "$($_.roleDefinitionName)|$($_.scope)" } | Where-Object Count -gt 1).Count -gt 0) {
        throw 'The temporary identity has unexpected RBAC assignments; refusing cleanup.'
    }
    if ($FederatedCredentials.Count -gt 1 -or
        @($FederatedCredentials | Where-Object {
            $_.name -cne $ExpectedCredentialName -or
            $_.issuer -cne $ExpectedIssuer -or
            $_.subject -cne $ExpectedSubject -or
            @($_.audiences | Where-Object { $_ -ceq $ExpectedAudience }).Count -ne 1
        }).Count -gt 0) {
        throw 'The temporary app has unexpected federated credentials; refusing cleanup.'
    }
    return $true
}

Export-ModuleMember -Function Assert-SpikeIdentityCleanupState
