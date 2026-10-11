import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { collect, evaluate, main } from './check-public-access.mjs';

const fixture = (name) =>
  fileURLToPath(new URL(`../tests/fixtures/public-access/${name}`, import.meta.url));
const load = (name) => JSON.parse(readFileSync(fixture(name), 'utf8'));
const tool = fileURLToPath(new URL('./check-public-access.mjs', import.meta.url));

function mutated(change) {
  const resources = load('pass.json');
  change(resources);
  return evaluate(resources).violations;
}
const find = (resources, type) => resources.find((r) => r.type === type);

test('compliant inventory passes and records the Log Analytics exception', () => {
  const result = evaluate(load('pass.json'));
  assert.deepEqual(result.violations, []);
  assert.deepEqual(result.warnings, []);
  assert.ok(result.notes.some((n) => n.includes('documented exception')));
});

test('non-compliant inventory reports every violation', () => {
  const { violations } = evaluate(load('fail.json'));
  for (const expected of [
    /storageAccounts stghrsmokeabc12: publicNetworkAccess must be Disabled/,
    /storageAccounts stghrsmokeabc12: allowBlobPublicAccess/,
    /vaults kv-ghr-prod-swc-abc12/,
    /registries crghrunnersprodswcabc12/,
    /managedEnvironments .*publicNetworkAccess must be Disabled/,
    /managedEnvironments .*internal must be true/,
    /workspaces .*disableLocalAuth/,
    /publicIPAddresses pip-extra: public IP must be attached only to a NAT gateway/,
  ]) {
    assert.ok(violations.some((v) => expected.test(v)), `missing ${expected}`);
  }
  assert.equal(violations.some((v) => v.includes('pip-ghrunners-prod-swc-abc12')), false);
});

test('each PaaS type fails closed when public access is not Disabled', () => {
  for (const type of [
    'Microsoft.Storage/storageAccounts',
    'Microsoft.KeyVault/vaults',
    'Microsoft.ContainerRegistry/registries',
    'Microsoft.App/managedEnvironments',
  ]) {
    assert.equal(mutated((r) => { find(r, type).properties.publicNetworkAccess = 'Enabled'; }).length, 1, type);
    assert.equal(mutated((r) => { delete find(r, type).properties.publicNetworkAccess; }).length, 1, type);
  }
});

test('an ACA environment that is not internal fails', () => {
  assert.equal(mutated((r) => { find(r, 'Microsoft.App/managedEnvironments').properties.vnetConfiguration.internal = false; }).length, 1);
});

test('the Log Analytics exception requires local authentication to be disabled', () => {
  assert.equal(mutated((r) => { find(r, 'Microsoft.OperationalInsights/workspaces').properties.features.disableLocalAuth = false; }).length, 1);
});

test('a public IP not attached to a NAT gateway fails, as does a public IP prefix', () => {
  assert.equal(mutated((r) => { delete find(r, 'Microsoft.Network/publicIPAddresses').properties.natGateway; }).length, 1);
  assert.equal(mutated((r) => { find(r, 'Microsoft.Network/publicIPAddresses').properties.ipConfiguration = { id: '/x' }; }).length, 1);
  assert.equal(mutated((r) => { r.push({ name: 'pfx', type: 'Microsoft.Network/publicIPPrefixes', properties: {} }); }).length, 1);
});

test('a missing NAT public IP, missing properties and an empty inventory fail', () => {
  assert.equal(mutated((r) => { r.splice(r.indexOf(find(r, 'Microsoft.Network/publicIPAddresses')), 1); }).length, 1);
  assert.equal(mutated((r) => { delete find(r, 'Microsoft.KeyVault/vaults').properties; }).length, 1);
  assert.equal(evaluate([]).violations.length, 1);
});

test('unreviewed resource types warn without failing', () => {
  const resources = [...load('pass.json'), { name: 'sb', type: 'Microsoft.ServiceBus/namespaces' }];
  const result = evaluate(resources);
  assert.deepEqual(result.violations, []);
  assert.equal(result.warnings.length, 1);
});

test('collect reads properties only for types that need them', () => {
  const calls = [];
  const run = (args) => {
    calls.push(args.join(' '));
    if (args[1] === 'list') {
      return [{ id: '/a', type: 'Microsoft.KeyVault/vaults' }, { id: '/b', type: 'Microsoft.Network/virtualNetworks' }];
    }
    return { id: args[3], type: 'Microsoft.KeyVault/vaults', properties: {} };
  };
  const resources = collect('rg-test', run);
  assert.equal(resources.length, 2);
  assert.deepEqual(calls, ['resource list --resource-group rg-test', 'resource show --ids /a']);
});

test('CLI exit codes: 0 pass, 1 violations, 2 usage', () => {
  const run = (...args) => spawnSync(process.execPath, [tool, ...args], { encoding: 'utf8' });
  assert.equal(run('--input', fixture('pass.json')).status, 0);
  const failed = run('--input', fixture('fail.json'));
  assert.equal(failed.status, 1);
  assert.match(failed.stdout, /FAILED/);
  assert.equal(run().status, 2);
  assert.equal(run('--input', fixture('missing.json')).status, 2);
  assert.equal(main(['--input', fixture('pass.json'), '--resource-group', 'x']), 2);
});
