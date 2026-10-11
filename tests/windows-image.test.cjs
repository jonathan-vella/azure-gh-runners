'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (...parts) => fs.readFileSync(path.join(root, ...parts), 'utf8');
const versions = JSON.parse(read('image', 'windows', 'versions.json'));
const install = read('image', 'windows', 'install-tools.ps1');
const verify = read('image', 'windows', 'verify-tools.ps1');
const workflow = read('.github', 'workflows', 'build-windows-image.yml');

const tools = ['azureCli', 'bicep', 'git', 'node', 'pwsh', 'python', 'terraform'];

test('manifest pins the Windows base image and every tool', () => {
  assert.equal(versions.platform, 'windows/amd64');
  assert.deepEqual(versions.baseImage, {
    publisher: 'MicrosoftWindowsServer',
    offer: 'WindowsServer',
    sku: '2025-datacenter-azure-edition',
    hyperVGeneration: 'V2',
  });
  assert.deepEqual(Object.keys(versions.downloads).sort(), tools);
  for (const [name, tool] of [['runner', versions.runner], ...Object.entries(versions.downloads)]) {
    assert.match(tool.version, /^\d+\.\d+\.\d+$/, name);
    assert.match(tool.sha256, /^[0-9a-f]{64}$/, name);
    assert.match(tool.url, /^https:\/\//, name);
    assert.ok(tool.url.includes(tool.version), `${name} url must contain its version`);
    assert.ok(['zip', 'msi', 'exe', 'binary'].includes(tool.kind), name);
  }
  assert.match(versions.runner.url, /actions-runner-win-x64-\d+\.\d+\.\d+\.zip$/);
  assert.ok(!/latest/i.test(JSON.stringify(versions)));
});

test('installer verifies checksums before use and installs every manifest entry', () => {
  for (const tool of [...tools, 'runner']) {
    assert.ok(install.includes(tool === 'runner' ? '$manifest.runner' : `$downloads.${tool}`), `${tool} is not installed`);
    assert.ok(verify.includes(tool === 'runner' ? 'manifest.runner.version' : `downloads.${tool}.version`), `${tool} is not verified`);
  }
  assert.ok(install.indexOf('Get-FileHash') < install.indexOf('Invoke-Installer -File "$env:SystemRoot'));
  assert.match(install, /checksum mismatch/);
  assert.match(install, /\^https:\/\//);
  assert.match(install, /non-HTTPS/);
});

test('image scripts bake in no identity, credential or Azure login', () => {
  for (const text of [install, verify]) {
    assert.doesNotMatch(text, /az login|Connect-AzAccount|Invoke-RestMethod|169\.254\.169\.254/);
  }
  assert.match(verify, /az account show/);
  assert.match(verify, /ghr-runner/);
});

test('workflow is manual, pinned, OIDC-based and scoped as specified', () => {
  assert.match(workflow, /^on:\r?\n  workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s+(pull_request|pull_request_target|push|schedule|workflow_run):/m);
  assert.match(workflow, /^permissions:\r?\n  id-token: write\r?\n  contents: read\r?\n/m);
  assert.match(workflow, /environment: platform-prod/);
  assert.match(workflow, /client-id: \$\{\{ vars\.WINDOWS_AZURE_CLIENT_ID \}\}/);
  assert.match(workflow, /tenant-id: \$\{\{ secrets\.AZURE_TENANT_ID \}\}/);
  assert.match(workflow, /subscription-id: \$\{\{ secrets\.AZURE_SUBSCRIPTION_ID \}\}/);
  for (const [, reference] of workflow.matchAll(/^\s*- uses: (\S+)/gm)) {
    assert.match(reference, /^[\w.-]+\/[\w.-]+@[0-9a-f]{40}$/, reference);
  }
  for (const expected of [
    'default: rg-ghrunners-win-swc',
    'default: gal_ghrunners_win_swc',
    'default: ghr-windows-2025',
    'IMAGE_VERSION: 1.0.${{ github.run_number }}',
    '.baseImage',
    'az vm generalize',
    'Sysprep.exe',
    '--hyper-v-generation V2',
    '--target-regions "$LOCATION"',
    '--replica-count 1',
    'if: always()',
  ]) {
    assert.ok(workflow.includes(expected), `workflow is missing ${expected}`);
  }
});

test('workflow takes an optional build subnet id and resolves the windows-foundation output when empty', () => {
  assert.match(workflow, /build-subnet-id:\r?\n(.*\r?\n)*?\s+required: false/);
  assert.doesNotMatch(workflow, /vnet-name|subnet-name/);
  for (const expected of ['az deployment group show', '--name windows-foundation', 'buildSubnetResourceId', 'No build subnet']) {
    assert.ok(workflow.includes(expected), `workflow is missing ${expected}`);
  }
});

test('workflow never gives build or test VMs an identity or a public IP', () => {
  assert.doesNotMatch(workflow, /--assign-identity|--identity|--user-assigned/);
  assert.equal((workflow.match(/--public-ip-address ""/g) || []).length, 1);
  assert.doesNotMatch(workflow, /az login|--password \$|echo "\$VM_PASSWORD"/);
});

test('workflow deletes the build VM, test VM, NICs and disks on every outcome', () => {
  const cleanup = workflow.slice(workflow.indexOf('Delete temporary resources'));
  for (const expected of ['az vm delete', 'az network nic delete', 'az disk delete', '"${TEST_VM:-}" "${BUILD_VM:-}"', 'az sig image-version delete']) {
    assert.ok(cleanup.includes(expected), `cleanup is missing ${expected}`);
  }
});
