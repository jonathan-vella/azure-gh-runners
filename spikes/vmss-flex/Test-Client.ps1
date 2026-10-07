param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
$docker = Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$builder = 'golang@sha256:414a753c2f67d0efccb01b5f58b3d3a8a2cbb7c012ce9e535418b5b3492b2c24'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$name = "ghr-vmss60-test-$([guid]::NewGuid().ToString('N'))"
try {
    $result = Invoke-BoundedProcess -FileName $docker -Arguments @(
        'run', '--name', $name, '--platform', 'linux/amd64', '--cpus', '2', '--memory', '2g',
        '--mount', "type=bind,source=$root,target=/src,readonly",
        '--workdir', '/src/spikes/vmss-flex', '--env', 'GOTOOLCHAIN=local',
        $builder, 'sh', '-ec',
        'bash -n guest-bootstrap.sh native-bootstrap.sh run-one-job.sh; mkdir /tmp/client; cp *.go go.mod go.sum /tmp/client/; cd /tmp/client; go test -race -mod=readonly ./...; go vet -mod=readonly ./...; CGO_ENABLED=0 go build -C /tmp/client -mod=readonly -o /tmp/vmss-spike-controller .'
    ) -TimeoutSeconds 600
    if ($result.exitCode -ne 0) {
        throw "Pinned Go client build/tests failed (exit $($result.exitCode)); no cloud operation was performed."
    }
} finally {
    # Killing the Docker CLI alone does not stop its server-side container.
    $cleanup = Invoke-BoundedProcess -FileName $docker -Arguments @('rm', '--force', $name) -TimeoutSeconds 30
    if ($cleanup.exitCode -ne 0) { throw 'Exact Go test container cleanup failed; inspect Docker before continuing.' }
}
Write-Output 'Pinned v0.4.0 client build, vet and offline lifecycle tests passed.'
