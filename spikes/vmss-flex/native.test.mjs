import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = name => readFileSync(new URL(name, import.meta.url), 'utf8');
const native = JSON.parse(read('native-image.json'));
const manifest = JSON.parse(read('../../image/versions.json'));

test('native inputs are immutable and runner archive matches shared manifest', () => {
  assert.equal(native.runnerArchive.version, manifest.base.version);
  for (const artifact of [native.vhd, native.testRootfs, native.runnerArchive]) {
    assert.match(artifact.url, /^https:\/\//);
    assert.match(artifact.sha256, /^[a-f0-9]{64}$/);
    assert.ok(!artifact.url.includes('/current/'));
    assert.ok(!artifact.url.includes('/latest/'));
  }
  assert.match(native.gitPpaFingerprint, /^[A-F0-9]{40}$/);
  assert.ok(read('native-test.Dockerfile').includes(`--checksum=sha256:${native.testRootfs.sha256}`));
});

test('native bootstrap stays bounded, reuses full verifier and never starts jobs', () => {
  const script = read('native-bootstrap.sh');
  assert.ok(!script.includes('\r'));
  assert.match(script, /--kill-after=10s 900s/);
  assert.match(script, /APT::Update::Error-Mode=any/);
  assert.match(script, /install "\$\{packages\[@\]\}"/);
  assert.match(script, /inherited\[\]/);
  assert.match(script, /runuser --user runner -- env -i/);
  assert.match(script, /\/opt\/runner-image\/verify-tools.sh/);
  assert.doesNotMatch(script, /--jitconfig|encodedJITConfig|identity\/oauth2|role assignment/);
  assert.match(script, /worker-ready/);
  assert.match(script, /pre-job-spike\.sh/);
  assert.match(read('pre-job-spike.sh'), /exec \/opt\/runner-image\/pre-job-policy\.sh/);
  assert.match(read('run-one-job.sh'), /ACTIONS_RUNNER_HOOK_JOB_STARTED:-.*\/opt\/ghr-vmss\/pre-job-spike\.sh/);
});

test('guest bootstrap bounds traffic, DNS, compiler and service without starting it', () => {
  const script = read('guest-bootstrap.sh');
  assert.ok(!script.includes('\r'));
  assert.match(script, /--kill-after=30s 1200s/);
  assert.equal((script.match(/--quota 2147483648/g) ?? []).length, 2);
  assert.match(script, /--limit 2\/second --limit-burst 20/);
  assert.match(script, /ip6tables -w 5 -P OUTPUT DROP/);
  assert.match(script, /go1\.25\.3\.linux-amd64\.tar\.gz/);
  assert.match(script, /0335f314b6e7bfe08c3d0cfaa7c19db961b7b99fb20be62b0a826c992ad14e0f/);
  assert.match(script, /CGO_ENABLED=0/);
  assert.match(script, /Restart=no/);
  assert.match(script, /TimeoutStopSec=180/);
  assert.doesNotMatch(script, /systemctl (start|enable)|GH_APP_PRIVATE_KEY|latest|generate-ssh-keys/);
});

test('runtime verifier uses actual spike hook and strict readonly privilege assertions', () => {
  const script = read('verify-spike-worker.sh');
  assert.match(script, /ACTIONS_RUNNER_HOOK_JOB_STARTED:-.*\/opt\/ghr-vmss\/pre-job-spike\.sh/);
  assert.match(script, /0:0:555/);
  assert.match(script, /! -L \$file/);
  assert.match(script, /command -v sudo/);
  assert.doesNotMatch(script, /sudo -n|sudo true|ACTIONS_RUNNER_HOOK_JOB_STARTED=/);
  assert.match(script, /IDENTITY_ENDPOINT/);
  assert.match(script, /-perm -4000/);
  assert.match(script, /inherited\[\]/);
  assert.match(read('native-test.Dockerfile'), /ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=\/opt\/ghr-vmss\/pre-job-spike\.sh/);
  assert.match(read('test-spike-verifier.sh'), /chmod 0777/);
  assert.match(read('test-spike-verifier.sh'), /mv "\$file" "\$file.disabled"/);
});

test('both guests adapt exact minimal packages after traffic quotas without assuming image patch parity', () => {
  const script = read('guest-bootstrap.sh');
  const install = read('install-minimal-tools.sh');
  assert.ok(script.indexOf('--quota 2147483648') < script.indexOf('install-minimal-tools.sh'));
  const reloadPosition = script.indexOf('systemctl daemon-reload');
  const markerPosition = script.indexOf('mv -T -- "$marker_tmp" "$marker"');
  assert.ok(reloadPosition >= 0 && markerPosition > reloadPosition);
  assert.match(script, /marker_tmp=\$\(mktemp \/var\/lib\/ghr-spike60\/\.initial-boot-id\.XXXXXX\)/);
  assert.match(script, /cat \/proc\/sys\/kernel\/random\/boot_id > "\$marker_tmp"/);
  assert.match(script, /chmod 0444 "\$marker_tmp"/);
  assert.match(script, /\[\[ ! -e \$marker && ! -L \$marker \]\]/);
  assert.ok(script.indexOf('for unit in systemd-networkd.service NetworkManager.service') < reloadPosition);
  const guard = read('reboot-guard.sh');
  assert.match(guard, /initial_boot_id == "\$current_boot_id" \]\] && exit 0/);
  assert.match(guard, /iptables -w 5 -P OUTPUT DROP/);
  assert.match(guard, /ip6tables -w 5 -P INPUT DROP/);
  assert.match(guard, /\[\[ -s \$marker \]\] \|\| exit 1/);
  assert.match(script, /FailureAction=poweroff/);
  assert.match(script, /for unit in systemd-networkd\.service NetworkManager\.service/);
  assert.match(script, /unit_id=\$\(systemctl show --property=Id --value "\$unit"\)/);
  assert.match(script, /systemctl is-active --quiet "\$unit"/);
  assert.match(script, /Requires=ghr-spike60-reboot-guard\.service/);
  assert.match(script, /After=ghr-spike60-reboot-guard\.service/);
  assert.match(script, /if \[\[ \$network_units -eq 0 \|\| \$active_network_units -eq 0 \]\]; then\s+fail_closed 'No supported active systemd network manager; refusing to continue.'/);
  assert.match(script, /trap 'fail_closed /);
  assert.match(script, /trap 'fail_closed .*' TERM INT HUP/);
  assert.match(script, /--kill-after=30s 1200s/);
  assert.match(script, /fail_closed\(\)[\s\S]*?iptables -w 5 -P OUTPUT DROP[\s\S]*?ip6tables -w 5 -P INPUT DROP[\s\S]*?systemctl poweroff --no-block/);
  assert.match(script, /require_free_controller_uid\(\)[\s\S]*?getent passwd 1002[\s\S]*?fail_closed/);
  assert.match(script, /\[\[ \$config =~[\s\S]*?require_free_controller_uid/);
  const workerBranch = script.slice(script.indexOf('if [[ $mode == worker ]]'), script.indexOf('[[ $config =~'));
  assert.match(workerBranch, /native-bootstrap\.sh \|\|[\s\S]*?fail_closed 'Native worker bootstrap failed/);
  assert.match(workerBranch, /exit 0/);
  assert.doesNotMatch(script, /network-pre\.target/);
  assert.ok(script.indexOf('install-minimal-tools.sh') < script.indexOf('if [[ $mode == worker ]]'));
  assert.match(install, /install "\$\{minimal_packages\[@\]\}"/);
  assert.match(install, /Acquire::Retries=0/);
  assert.ok(install.indexOf('install "${minimal_packages[@]}"') < install.indexOf('dpkg-query'));
  assert.match(read('test-minimal-tools.sh'), /older-image-baseline/);
  assert.match(read('test-minimal-tools.sh'), /SIMULATE_FAILURE=true/);
});
