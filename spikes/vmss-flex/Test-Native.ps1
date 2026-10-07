$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
$docker = Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$tag = "ghr-vmss60-native-$([guid]::NewGuid().ToString('N'))"
try {
    $result = Invoke-BoundedProcess -FileName $docker -Arguments @(
        'build', '--tag', $tag, '--file', (Join-Path $PSScriptRoot 'native-test.Dockerfile'), $root
    ) -TimeoutSeconds 1200
    if ($result.exitCode -ne 0) {
        # These are secret-free package/build diagnostics, never cloud/JIT logs.
        $result.stderr -split "`n" | Select-Object -Last 40 | Write-Output
        throw "Native toolset bootstrap failed (exit $($result.exitCode))."
    }
    Write-Output 'Checksum-pinned native Ubuntu rootfs bootstrap and exact nonroot tool verification passed.'
} finally {
    $inspect = Invoke-BoundedProcess -FileName $docker -Arguments @('image', 'inspect', $tag) -TimeoutSeconds 30
    if ($inspect.exitCode -eq 0) {
        $cleanup = Invoke-BoundedProcess -FileName $docker -Arguments @('image', 'rm', $tag) -TimeoutSeconds 30
        if ($cleanup.exitCode -ne 0) { throw 'Exact native test image cleanup failed.' }
    }
}
