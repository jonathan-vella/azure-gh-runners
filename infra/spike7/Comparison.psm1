function Invoke-SpikeBypassComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $SetBypass,

        [Parameter(Mandatory)]
        [scriptblock] $RunCase
    )

    $results = [ordered]@{}
    try {
        foreach ($bypass in @('None', 'AzureServices')) {
            try {
                & $SetBypass $bypass
                $status = [string](& $RunCase $bypass)
                if ($status -notin @('Succeeded', 'Failed')) {
                    throw 'The diagnostic callback returned a non-terminal status.'
                }
                $results[$bypass] = $status
                Write-Host "Comparison result ($bypass): $status"
            } catch {
                $errorType = $_.Exception.GetType().Name
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

Export-ModuleMember -Function Invoke-SpikeBypassComparison
