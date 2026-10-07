function Invoke-SpikeLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Deploy,
        [Parameter(Mandatory)][scriptblock] $Test,
        [Parameter(Mandatory)][scriptblock] $Diagnose,
        [Parameter(Mandatory)][scriptblock] $Cleanup
    )

    $failures = [System.Collections.Generic.List[System.Exception]]::new()
    try {
        & $Deploy
        & $Test
    } catch {
        $failures.Add($_.Exception)
    } finally {
        try { & $Diagnose } catch { $failures.Add($_.Exception) }
        try { & $Cleanup } catch { $failures.Add($_.Exception) }
    }
    if ($failures.Count) {
        throw [System.AggregateException]::new(
            'Issue-7 lifecycle failed; original, diagnostic, and cleanup errors are retained in order.',
            $failures.ToArray()
        )
    }
}

Export-ModuleMember -Function Invoke-SpikeLifecycle
