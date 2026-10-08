import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { newIdentityEnvelope, writeIdentityEnvelope, updateIdentityEnvelope, scope, tenant } from '../temporary-identity.mjs';
import { bootstrapTemporaryIdentity, cleanupTemporaryIdentity, authenticatedTransport } from '../identity-adapter.mjs';

const now = '2026-10-08T05:00:00.000Z';
const pricing = {
  refreshedUtc: now, b2sHourly: 0.0432, d2lsHourly: 0.091, p4Hourly: 5.8072 / 672,
  natHourly: 0.045, pipHourly: 0.005, peHourly: 0.01, dnsZonePerRun: 0.5,
  natGb: 0.045, egressGb: 0.12, peIngressGb: 0.01, peEgressGb: 0.01, dnsMillionQueries: 0.5,
  kvPerRunCeilingUsd: 0.1, logsCombinedCeilingUsd: 0.5, imageCombinedCeilingUsd: 1,
  cleanupReserveUsd: 2, miscCombinedCeilingUsd: 0.5,
};
const claims = { iss: 'https://token.actions.githubusercontent.com', aud: 'api://AzureADTokenExchange',
  sub: 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss',
  repository_id: '1408821667', repository_owner_id: '25802147' };
const uid = number => `${String(number).repeat(8)}-${String(number).repeat(4)}-${String(number).repeat(4)}-${String(number).repeat(4)}-${String(number).repeat(12)}`;

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'adapter81-'));
  const path = join(directory, 'state.json');
  writeIdentityEnvelope(path, newIdentityEnvelope('a'.repeat(40)));
  return { path, close: () => rmSync(directory, { recursive: true }) };
}

function fakeTransport(failure = null) {
  const cloud = { group: null, app: null, sp: null, fic: null, owner: null, env: null, policies: [] };
  const writes = [];
  let created = 0;
  const invoke = async (operation, payload = {}) => {
    if (operation === 'account') return { id: scope.split('/')[2], tenantId: tenant, name: 'shared', user: { type: 'user' } };
    if (operation === 'group-exists') return cloud.group !== null;
    if (operation === 'group-read') return cloud.group;
    if (operation === 'apps') return { value: cloud.app ? [cloud.app] : [] };
    if (operation === 'sps') return { value: cloud.sp ? [cloud.sp] : [] };
    if (operation === 'fics') return { value: cloud.fic ? [cloud.fic] : [] };
    if (operation === 'assignments') return cloud.owner ? [cloud.owner] : [];
    if (operation === 'environments') return [{ environments: cloud.env ? [cloud.env] : [] }];
    if (operation === 'policies') return [{ branch_policies: cloud.policies }];
    assert.equal(operation, 'request');
    writes.push(payload);
    if (payload.method !== 'DELETE') {
      created++;
      if (failure === created) throw new Error('simulated provider failure');
      if (payload.url.includes('management.azure.com') && !payload.url.includes('roleAssignments')) {
        return cloud.group = { id: scope, ...payload.body };
      }
      if (payload.url.endsWith('/applications')) return cloud.app = { id: uid(1), appId: uid(2), ...payload.body };
      if (payload.url.endsWith('/servicePrincipals')) return cloud.sp = { id: uid(3), ...payload.body, passwordCredentials: [], keyCredentials: [] };
      if (payload.url.endsWith('/federatedIdentityCredentials')) return cloud.fic = { id: uid(4), ...payload.body };
      if (payload.url.includes('roleAssignments')) return cloud.owner = {
        id: payload.url.split('?')[0].replace('https://management.azure.com', ''),
        scope, ...payload.body.properties, condition: null,
      };
      if (payload.url.endsWith('/deployment-branch-policies')) {
        const policy = { id: 200, ...payload.body };
        cloud.policies.push(policy);
        return policy;
      }
      if (payload.url.endsWith('/spike-vmss')) return cloud.env = {
        id: 100, name: 'spike-vmss', deployment_branch_policy: payload.body.deployment_branch_policy,
        protection_rules: [{ type: 'branch_policy' }],
      };
    } else {
      if (payload.url.includes('management.azure.com') && !payload.url.includes('roleAssignments')) { cloud.group = null; cloud.owner = null; }
      else if (payload.url.includes('roleAssignments')) cloud.owner = null;
      else if (payload.url.includes('federatedIdentityCredentials')) cloud.fic = null;
      else if (payload.url.includes('/applications/')) { cloud.app = null; cloud.fic = null; }
      else if (payload.url.includes('/servicePrincipals/')) cloud.sp = null;
      else if (payload.url.endsWith('/spike-vmss')) { cloud.env = null; cloud.policies = []; }
      else throw new Error('Unexpected deletion target.');
      return {};
    }
    throw new Error('Unexpected request target.');
  };
  return { invoke, cloud, writes };
}
const options = { now: () => now, pricing, claims, readiness: {
  independentRecoveryReady: true, scopedKeyToolReady: true, sshPublicKeyApproved: true, dependencyResolved: true,
} };

test('authenticated default is hard disabled and never launches a CLI', async () => {
  assert.throws(() => authenticatedTransport('account'), /disabled/);
  const f = fixture();
  try { await assert.rejects(bootstrapTemporaryIdentity(f.path, undefined, options), /disabled/); }
  finally { f.close(); }
});

test('bounded adapter creates exact reserved objects, waits owner, then pays cleanup before credential revoke', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    const result = await bootstrapTemporaryIdentity(f.path, mock.invoke, options);
    assert.equal(result.status, 'waiting-approved-coordinator-spike-key');
    const state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.startedUtc, now);
    assert.equal(state.runs[0].steps.seedConfirmation, 'reserved');
    updateIdentityEnvelope(f.path, 'record-key-fingerprint', { fingerprint: Buffer.alloc(32, 1).toString('base64') });
    const cleaned = await cleanupTemporaryIdentity(f.path, mock.invoke);
    assert.deepEqual(cleaned, { status: 'credential-revocation', credentialRevocationPending: true });
    assert.equal(mock.cloud.group, null);
    assert.equal(mock.cloud.app, null);
    assert.equal(mock.cloud.sp, null);
    assert.equal(mock.cloud.env, null);
    const deletes = mock.writes.filter(write => write.method === 'DELETE');
    assert.ok(deletes[0].url.startsWith(`https://management.azure.com${scope}?`));
    assert.ok(deletes.at(-1).url.endsWith('/spike-vmss'));
    assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, 7);
    await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, options), /retry/);
  } finally { f.close(); }
});

test('every failed create ends cleanup without reissuing a step', async () => {
  for (let failure = 1; failure <= 7; failure++) {
    const f = fixture();
    const mock = fakeTransport(failure);
    try {
      await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, options), /Bootstrap failed/);
      assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, failure);
      const run = JSON.parse(readFileSync(f.path, 'utf8')).runs[0];
      assert.equal(run.phase, failure === 5 || failure === 7 ? 'closed' : 'cleanup');
      assert.equal(run.cleanup.resourceGroup, failure === 1 ? 'pending' : 'absent');
      assert.equal(mock.cloud.group, null);
      if (run.phase === 'closed') {
        assert.equal(mock.cloud.app, null);
        assert.equal(mock.cloud.sp, null);
        assert.equal(mock.cloud.env, null);
      }
    } finally { f.close(); }
  }
});

test('unexpected inventory prevents identity deletion but cannot skip exact paid RG cleanup', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    await bootstrapTemporaryIdentity(f.path, mock.invoke, options);
    mock.cloud.app.passwordCredentials.push({ keyId: 'unexpected' });
    await assert.rejects(cleanupTemporaryIdentity(f.path, mock.invoke), /unowned/);
    assert.equal(mock.cloud.group, null);
    assert.notEqual(mock.cloud.app, null);
    assert.equal(JSON.parse(readFileSync(f.path, 'utf8')).runs[0].cleanup.resourceGroup, 'absent');
  } finally { f.close(); }
});

test('missing independent recovery/tooling stops before authentication, clock or bootstrap', async () => {
  const f = fixture();
  let calls = 0;
  try {
    await assert.rejects(bootstrapTemporaryIdentity(f.path, async () => { calls++; }, {
      ...options, readiness: { ...options.readiness, independentRecoveryReady: false },
    }), /readiness/);
    assert.equal(calls, 0);
    assert.equal(JSON.parse(readFileSync(f.path, 'utf8')).startedUtc, null);
  } finally { f.close(); }
});

test('concurrent cleanup caller and crash-stale lock never issue duplicate requests', async () => {
  const f = fixture();
  const mock = fakeTransport();
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  let notify;
  const deleting = new Promise(resolve => { notify = resolve; });
  try {
    await bootstrapTemporaryIdentity(f.path, mock.invoke, options);
    const invoke = async (operation, payload) => {
      if (operation === 'request' && payload.method === 'DELETE' && payload.step === 'resourceGroup') {
        notify();
        await blocked;
      }
      return mock.invoke(operation, payload);
    };
    const first = cleanupTemporaryIdentity(f.path, invoke);
    await deleting;
    await assert.rejects(cleanupTemporaryIdentity(f.path, invoke), /EEXIST/);
    release();
    await first;
    assert.equal(mock.writes.filter(write => write.method === 'DELETE' && write.step === 'resourceGroup').length, 1);
    writeFileSync(`${f.path}.cleanup.lock`, 'crashed operator');
    const count = mock.writes.length;
    await assert.rejects(cleanupTemporaryIdentity(f.path, invoke), /EEXIST/);
    assert.equal(mock.writes.length, count);
  } finally { release?.(); f.close(); }
});

test('late ambiguous RG create remains unresolved until materialized, never false full cleanup', async () => {
  const f = fixture();
  const mock = fakeTransport(1);
  try {
    await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, options), /cleanup is unverified/);
    let state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].cleanup.resourceGroup, 'pending');
    assert.equal(state.runs[0].phase, 'cleanup');
    const create = mock.writes.find(write => write.step === 'resourceGroup');
    mock.cloud.group = { id: scope, ...create.body };
    await cleanupTemporaryIdentity(f.path, mock.invoke);
    state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].phase, 'closed');
    assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, 1);
  } finally { f.close(); }
});

test('lost delete response or crash after intent cannot certify early ARM absence or retry', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    await bootstrapTemporaryIdentity(f.path, mock.invoke, options);
    const uncertain = async (operation, payload) => {
      const result = await mock.invoke(operation, payload);
      if (operation === 'request' && payload.method === 'DELETE' && payload.step === 'resourceGroup') {
        throw new Error('response lost after server accepted asynchronous deletion');
      }
      return result;
    };
    await assert.rejects(cleanupTemporaryIdentity(f.path, uncertain), /response lost/);
    await assert.rejects(cleanupTemporaryIdentity(f.path, mock.invoke), /terminal acknowledgement/);
    const state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].cleanup.resourceGroup, 'reserved');
    assert.equal(state.runs[0].phase, 'cleanup');
    assert.equal(mock.writes.filter(write => write.method === 'DELETE' && write.step === 'resourceGroup').length, 1);
  } finally { f.close(); }
});
