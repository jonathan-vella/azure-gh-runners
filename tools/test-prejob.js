'use strict';

const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ghr-bats-'));
const version = '1.14.0';
const sha256 = 'bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177';
const archive = path.join(temporary, 'bats.tar.gz');
const generatedPolicy = path.join(temporary, 'generated-policy.json');
const execute = (command, args, options = {}) => execFileSync(command, args, {
  stdio: 'inherit', timeout: 180_000, ...options,
});

try {
  const { buildParameters } = require('./generate-consumers.js');
  const sample = JSON.parse(fs.readFileSync(path.join(root, 'config', 'consumers', 'example.json.sample')));
  fs.writeFileSync(generatedPolicy, buildParameters([{ consumer: sample }]).parameters.consumers.value[0].policyJson);
  execute(process.platform === 'win32' ? 'curl.exe' : 'curl', [
    '--silent', '--show-error', '--fail', '--location',
    '--proto', '=https', '--proto-redir', '=https', '--max-time', '120', '--retry', '2',
    `https://codeload.github.com/bats-core/bats-core/tar.gz/refs/tags/v${version}`,
    '--output', archive,
  ]);
  if (createHash('sha256').update(fs.readFileSync(archive)).digest('hex') !== sha256) {
    throw new Error('Bats release checksum mismatch.');
  }
  // Linux CI runs natively; Windows uses the pinned runner base, never a floating test image.
  if (process.platform === 'win32' || process.argv[2]) {
    const { base } = require('../image/versions.json');
    const image = process.argv[2] || `${base.image}@${base.digest}`;
    execute('docker', [
      'run', '--rm', '--network', 'none', '--cap-drop', 'ALL',
      '--security-opt', 'no-new-privileges',
      '--mount', `type=bind,source=${root},target=/workspace,readonly`,
      '--mount', `type=bind,source=${archive},target=/bats.tar.gz,readonly`,
      '--mount', `type=bind,source=${generatedPolicy},target=/generated-policy.json,readonly`,
      '--env', 'GENERATED_POLICY_PATH=/generated-policy.json',
      '--env', `HOOK_PATH=${process.argv[2] ? '/opt/runner-image' : '/workspace/image'}/pre-job-policy.sh`,
      '--entrypoint', '/bin/bash', image, '-euo', 'pipefail', '-c',
      `tar --no-same-owner -xzf /bats.tar.gz -C /tmp; exec /tmp/bats-core-${version}/bin/bats /workspace/tests/pre-job-policy.bats`,
    ]);
  } else {
    execute('tar', ['-xzf', archive, '-C', temporary]);
    execute('bash', [
      path.join(temporary, `bats-core-${version}`, 'bin', 'bats'),
      path.join(root, 'tests', 'pre-job-policy.bats'),
    ], { env: { ...process.env, GENERATED_POLICY_PATH: generatedPolicy } });
  }
} catch (error) {
  console.error(`Pre-job hook validation failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
