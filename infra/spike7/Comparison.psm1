function Invoke-SpikeBypassComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $SetBypass,

        [Parameter(Mandatory)]
        [scriptblock] $RunCase,

        [Parameter(Mandatory)]
        [scriptblock] $RecordResult
    )

    $results = [ordered]@{}
    try {
        foreach ($bypass in @('None', 'AzureServices')) {
            try {
                & $SetBypass $bypass
                $result = & $RunCase $bypass
                if ($result.Status -notin @('Succeeded', 'Failed') -or
                    $result.Stage -notin @('provisioning', 'execution')) {
                    throw 'The diagnostic callback returned a non-terminal status.'
                }
                & $RecordResult $bypass $result
                $results[$bypass] = $result.Status
                Write-Host "Comparison result ($bypass): $($result.Status), stage=$($result.Stage), code=$($result.Code)"
            } catch {
                $errorType = $_.Exception.GetType().Name
                $failure = $_.Exception.Data['Evidence']
                if (-not $failure) {
                    $failure = [pscustomobject]@{
                        Status = 'OperationalError'; Stage = 'configuration'; Code = $errorType
                        JobName = $null; ExecutionName = $null; DeploymentName = $null
                    }
                }
                & $RecordResult $bypass $failure
                Write-Host "Comparison operational error ($bypass): $errorType"
                throw "The $bypass comparison could not complete; inspect the sanitized Azure diagnostic before retrying."
            }
        }
    } finally {
        try {
            & $SetBypass 'None'
        } catch {
            $errorType = $_.Exception.GetType().Name
            Write-Host "Comparison restore error (None): $errorType"
            throw 'Could not restore the Key Vault trusted-services bypass to None.'
        }
    }

    if ($results.Values -notcontains 'Succeeded') {
        throw "Neither trusted-services configuration resolved the probe (None=$($results.None), AzureServices=$($results.AzureServices))."
    }
    return [pscustomobject]@{
        None = $results.None
        AzureServices = $results.AzureServices
    }
}

function Get-SpikeErrorNodes {
    param([Parameter(Mandatory)][object] $ErrorDetail)

    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($ErrorDetail)
    while ($pending.Count -gt 0) {
        $node = $pending.Dequeue()
        $node
        foreach ($detail in @($node.details)) {
            if ($null -ne $detail) { $pending.Enqueue($detail) }
        }
        if ($node.innererror) { $pending.Enqueue($node.innererror) }
    }
}

function Test-SpikeKeyVaultNetworkDenial {
    param([Parameter(Mandatory)][object] $ErrorDetail)

    # Only structured codes are inspected; messages can contain sensitive values.
    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @(Get-SpikeErrorNodes -ErrorDetail $ErrorDetail)) {
        if (-not $node.code) { return $false }
        $codes.Add([string]$node.code)
        $children = @($node.details | Where-Object { $null -ne $_ })
        if ($node.innererror) { $children += $node.innererror }
        if ($children.Count -eq 0 -and $node.code -cne 'ForbiddenByFirewall') { return $false }
    }
    $allowed = @('DeploymentFailed', 'ResourceDeploymentFailure', 'Forbidden', 'ForbiddenByFirewall')
    return $codes.Contains('ForbiddenByFirewall') -and
        @($codes | Where-Object { $_ -cnotin $allowed }).Count -eq 0
}

function Get-SpikeSanitizedErrorCode {
    param([Parameter(Mandatory)][object] $ErrorDetail)

    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @(Get-SpikeErrorNodes -ErrorDetail $ErrorDetail)) {
        if ([string]$node.code -cmatch '^[A-Za-z][A-Za-z0-9._-]{0,127}$') {
            $codes.Add([string]$node.code)
        } else {
            $codes.Add('UnclassifiedDeploymentFailure')
        }
    }
    return ($codes | Select-Object -Unique) -join ','
}

function Write-SpikeComparisonEvidence {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Records,
        [Parameter(Mandatory)][string] $Bypass,
        [Parameter(Mandatory)][object] $Result
    )

    $Records.Add([ordered]@{
        bypass = $Bypass; utc = [DateTimeOffset]::UtcNow.ToString('o')
        jobName = $Result.JobName; executionName = $Result.ExecutionName
        deploymentName = $Result.DeploymentName; status = $Result.Status
        stage = $Result.Stage; code = $Result.Code
    })
    [System.IO.File]::WriteAllText(
        $Path, (ConvertTo-Json -InputObject @($Records.ToArray()) -Depth 4)
    )
}

Export-ModuleMember -Function Invoke-SpikeBypassComparison, Test-SpikeKeyVaultNetworkDenial, Get-SpikeSanitizedErrorCode, Write-SpikeComparisonEvidence
