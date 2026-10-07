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
});

test('guest bootstrap bounds traffic, DNS, compiler and service without starting it', () => {
  const script = read('guest-bootstrap.sh');
  assert.ok(!script.includes('\r'));
  assert.match(script, /--kill-after=10s 1200s/);
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
