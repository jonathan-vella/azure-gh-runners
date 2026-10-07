function Get-ValidatedScopedAssignments {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Assignments,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][hashtable]$AllowedRolePrincipals
    )

    $exactScope = @($Assignments | Where-Object { $_.scope -ceq $Scope })
    if ($exactScope.Count -gt $AllowedRolePrincipals.Count) {
        throw 'More scoped role assignments exist than this cleanup explicitly owns.'
    }
    $seenRoles = @{}
    foreach ($assignment in $exactScope) {
        $roleId = ($assignment.roleDefinitionId -split '/')[-1].ToLowerInvariant()
        if (-not $AllowedRolePrincipals.ContainsKey($roleId) -or
            [string]::IsNullOrWhiteSpace([string]$AllowedRolePrincipals[$roleId]) -or
            $assignment.principalId -cne $AllowedRolePrincipals[$roleId] -or
            $seenRoles.ContainsKey($roleId)) {
            throw 'A scoped role assignment does not match an exact recorded principal and role.'
        }
        $seenRoles[$roleId] = $true
    }
    return $exactScope
}

Export-ModuleMember -Function Get-ValidatedScopedAssignments
