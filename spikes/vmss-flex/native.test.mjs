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
  assert.match(script, /install "git=\$git_version" "git-man=\$git_version"/);
  assert.match(script, /inherited\[\]/);
  assert.match(script, /runuser --user runner -- env -i/);
  assert.match(script, /\/opt\/runner-image\/verify-tools.sh/);
  assert.doesNotMatch(script, /--jitconfig|encodedJITConfig|identity\/oauth2|role assignment/);
});
