param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
$docker = Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$builder = 'golang@sha256:414a753c2f67d0efccb01b5f58b3d3a8a2cbb7c012ce9e535418b5b3492b2c24'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$name = "ghr-vmss60-test-$([guid]::NewGuid().ToString('N'))"
$workerParametersPath = [IO.Path]::GetTempFileName()
$containerMayExist = $false
try {
    Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Execution.psm1') -Force
    $workerManifest = New-SpikeManifest -Head ('b' * 40) -RunId ('a' * 32) -RunOrdinal 2
    $workerApproval = @{
        canonicalUbuntuVersion = '24.04.202609260'
        adminSshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakefixture'
    }
    & (Get-Module Execution) {
        param($manifest, $approval, $path)
        function script:New-SpikeCustomData { return 'Y2xvdWQtY29uZmln' }
        $parameters = New-SpikeWorkerParameters $manifest $approval
        $parameters.flexScaleSetResourceId = "$($manifest.scope)/providers/Microsoft.Compute/virtualMachineScaleSets/spike60"
        $parameters.workerSubnetResourceId = "$($manifest.scope)/providers/Microsoft.Network/virtualNetworks/spike60/subnets/worker"
        [IO.File]::WriteAllText($path, ($parameters | ConvertTo-Json -Depth 4 -Compress))
    } $workerManifest $workerApproval $workerParametersPath
    Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
    $containerMayExist = $true
    $result = Invoke-BoundedProcess -FileName $docker -Arguments @(
        'run', '--name', $name, '--platform', 'linux/amd64', '--cpus', '2', '--memory', '2g',
        '--mount', "type=bind,source=$root,target=/src,readonly",
        '--mount', "type=bind,source=$workerParametersPath,target=/tmp/worker-parameters.json,readonly",
        '--env', 'GHR_SPIKE_TEST_WORKER_PARAMETERS=/tmp/worker-parameters.json',
        '--workdir', '/src/spikes/vmss-flex', '--env', 'GOTOOLCHAIN=local',
        $builder, 'sh', '-ec',
        'bash -n guest-bootstrap.sh native-bootstrap.sh run-one-job.sh pre-job-spike.sh tests/test-reboot-guard.sh tests/test-bootstrap-failure.sh; bash tests/test-reboot-guard.sh; bash tests/test-bootstrap-failure.sh; mkdir /tmp/client; cp *.go go.mod go.sum /tmp/client/; cd /tmp/client; go test -race -mod=readonly ./...; go vet -mod=readonly ./...; CGO_ENABLED=0 go build -C /tmp/client -mod=readonly -o /tmp/vmss-spike-controller .'
    ) -TimeoutSeconds 600
    if ($result.exitCode -ne 0) {
        $result.stdout -split "`n" | Select-Object -Last 40 | Write-Output
        $result.stderr -split "`n" | Select-Object -Last 40 | Write-Output
        throw "Pinned Go client build/tests failed (exit $($result.exitCode)); no cloud operation was performed."
    }
} finally {
    # Killing the Docker CLI alone does not stop its server-side container.
    if ($containerMayExist) {
        $cleanup = Invoke-BoundedProcess -FileName $docker -Arguments @('rm', '--force', $name) -TimeoutSeconds 30
        if ($cleanup.exitCode -ne 0) { throw 'Exact Go test container cleanup failed; inspect Docker before continuing.' }
    }
    Remove-Item -LiteralPath $workerParametersPath -Force
}
Write-Output 'Pinned v0.4.0 client build, vet, generated-parameter validator and offline lifecycle tests passed.'
