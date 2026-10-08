'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, 'image', name), 'utf8');
const versions = JSON.parse(read('versions.json'));
const dockerfile = read('Dockerfile');
const installer = read('install-tools.sh');
const verifier = read('verify-tools.sh');

test('runner base and lint image have full digest pins', () => {
  assert.match(versions.base.digest, /^sha256:[a-f0-9]{64}$/);
  assert.ok(dockerfile.startsWith(`FROM ${versions.base.image}@${versions.base.digest} AS base\n`));
  assert.match(versions.hadolint.image, /^hadolint\/hadolint@sha256:[a-f0-9]{64}$/);
  assert.equal(versions.platform, 'linux/amd64');
});

test('every required tool has an exact inherited package or verified official release', () => {
  assert.deepEqual(Object.keys(versions.inherited).sort(), ['curl', 'git', 'jq', 'python']);
  assert.deepEqual(Object.keys(versions.downloads).sort(), ['azureCli', 'bicep', 'node', 'pwsh', 'terraform']);
  for (const tool of Object.values(versions.inherited)) {
    assert.match(tool.version, /^\d+\.\d+(?:\.\d+)?$/);
    assert.ok(tool.packageVersion.includes(tool.version));
  }
  const prefixes = {
    bicep: 'https://github.com/Azure/bicep/releases/download/v',
    node: 'https://nodejs.org/dist/v',
    pwsh: 'https://github.com/PowerShell/PowerShell/releases/download/v',
    terraform: 'https://releases.hashicorp.com/terraform/'
  };
  for (const [name, tool] of Object.entries(versions.downloads)) {
    assert.match(tool.version, /^\d+\.\d+\.\d+$/);
    if (name === 'azureCli') {
      assert.equal(decodeURI(tool.url), `https://packages.microsoft.com/repos/azure-cli/pool/main/a/azure-cli/azure-cli_${tool.packageVersion}_amd64.deb`);
      assert.equal(tool.packageVersion, `${tool.version}-1~noble`);
    } else {
      assert.ok(tool.url.startsWith(`${prefixes[name]}${tool.version}/`));
    }
    assert.match(tool.sha256, /^[a-f0-9]{64}$/);
    assert.match(installer, new RegExp(`download ${name} `));
    assert.ok(verifier.includes(`.downloads.${name}.version`));
  }
  assert.match(installer, /sha256sum --check --strict/);
  assert.match(installer, /--proto '=https' --proto-redir '=https'/);
  assert.doesNotMatch(installer, /apt(-get)? |pip install|curl[^\n]*\|.*(sh|bash)/);
});

test('runner is unprivileged with an explicit JIT entrypoint', () => {
  const runnerStage = dockerfile.slice(dockerfile.indexOf('FROM base AS runner'));
  assert.match(
    runnerStage,
    /USER runner\nRUN --network=none bash \/opt\/runner-image\/verify-tools\.sh\nENTRYPOINT \["\/opt\/runner-image\/runner-entrypoint\.sh"\]\nCMD \[\]\n$/,
  );
  assert.doesNotMatch(dockerfile, /^(WORKDIR|EXPOSE|ARG)\b/m);
  assert.match(installer, /id -u runner/);
  assert.match(installer, /id -g runner/);
  assert.match(installer, /usermod --groups users runner/);
  assert.match(installer, /rm -f \/usr\/bin\/dockerd/);
  assert.match(verifier, /sudo -n true/);
  assert.match(verifier, /\/var\/run\/docker\.sock/);
  assert.match(verifier, /\/home\/runner\/bin\/Runner\.Listener --version/);
  assert.match(verifier, /az bicep version/);
  assert.match(dockerfile, /ACTIONS_RUNNER_HOOK_JOB_STARTED=\/opt\/runner-image\/pre-job-policy.sh/);
  assert.match(dockerfile, /chmod 0555 \/opt\/runner-image\/pre-job-policy.sh \/opt\/runner-image\/pre-job-policy.py \\\n\s+\/opt\/runner-image\/runner-entrypoint\.sh/);
  assert.doesNotMatch(dockerfile + installer, /IDENTITY_ENDPOINT|registration-token|GH_APP_PRIVATE_KEY/);
});

test('jit-init stage runs as root with an explicit entrypoint and only the JIT script', () => {
  const initStage = dockerfile.slice(dockerfile.indexOf('FROM base AS jit-init'), dockerfile.indexOf('FROM base AS runner'));
  assert.match(initStage, /^FROM base AS jit-init\nUSER root\nCOPY image\/jit-init\.mjs \/opt\/runner-image\/jit-init\.mjs\n/);
  assert.match(initStage, /ENTRYPOINT \["\/home\/runner\/externals\/node20\/bin\/node", "\/opt\/runner-image\/jit-init\.mjs"\]\nCMD \[\]/);
  assert.equal((dockerfile.match(/^FROM /gm) || []).length, 3);
});

test('Linux build inputs use LF line endings', () => {
  for (const name of ['Dockerfile', 'install-tools.sh', 'verify-tools.sh', 'pre-job-policy.sh', 'pre-job-policy.py',
    'jit-init.mjs', 'runner-entrypoint.sh']) {
    assert.ok(!read(name).includes('\r'), `${name} must use LF`);
  }
});
