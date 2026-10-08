import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mockCoordination } from './recovery-fixture.mjs';
import { newIdentityEnvelope, writeIdentityEnvelope, updateIdentityEnvelope, scope, tenant, operationIntent,
  transitionIdentityEnvelope, inspectIdentityLock, validateProviderReceipt } from '../temporary-identity.mjs';
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
  return { path, coordination: mockCoordination(path), close: () => rmSync(directory, { recursive: true }) };
}

function fakeTransport(failure = null) {
  const cloud = { group: null, app: null, sp: null, fic: null, owner: null, env: null, policies: [] };
  const writes = [];
  let created = 0;
  const transport = async (operation, payload = {}) => {
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
  const invoke = async (operation, payload = {}) => {
    const value = await transport(operation, payload);
    if (operation !== 'request') return value;
    return { value, receipt: { operationId: payload.operationId, provider: payload.url.includes('graph.microsoft.com') ? 'graph' :
      payload.url.includes('api.github.com') ? 'github' : 'arm', state: 'succeeded', operationUrl: null } };
  };
  return { invoke, cloud, writes };
}
const options = { now: () => now, pricing, claims, sleep: async () => {}, readiness: {
  independentRecoveryReady: true, scopedKeyToolReady: true, sshPublicKeyApproved: true, dependencyResolved: true,
} };

test('authenticated default is hard disabled and never launches a CLI', async () => {
  assert.throws(() => authenticatedTransport('account'), /disabled/);
  const f = fixture();
  try { await assert.rejects(bootstrapTemporaryIdentity(f.path, undefined, { ...options, coordination: f.coordination }), /disabled/); }
  finally { f.close(); }
});

test('bounded adapter creates exact reserved objects, waits owner, then pays cleanup before credential revoke', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    const result = await bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
    assert.equal(result.status, 'waiting-approved-coordinator-spike-key');
    const state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.startedUtc, now);
    assert.equal(state.runs[0].steps.seedConfirmation, 'reserved');
    updateIdentityEnvelope(f.path, 'record-key-fingerprint', { fingerprint: Buffer.alloc(32, 1).toString('base64') }, f.coordination.session);
    const cleaned = await cleanupTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
    assert.deepEqual(cleaned, { status: 'credential-revocation', credentialRevocationPending: true });
    assert.equal(mock.cloud.group, null);
    assert.equal(mock.cloud.app, null);
    assert.equal(mock.cloud.sp, null);
    assert.equal(mock.cloud.env, null);
    const deletes = mock.writes.filter(write => write.method === 'DELETE');
    assert.ok(deletes[0].url.startsWith(`https://management.azure.com${scope}?`));
    assert.ok(deletes.at(-1).url.endsWith('/spike-vmss'));
    assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, 7);
    await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /retry/);
  } finally { f.close(); }
});

test('every failed create ends cleanup without reissuing a step', async () => {
  for (let failure = 1; failure <= 7; failure++) {
    const f = fixture();
    const mock = fakeTransport(failure);
    try {
      await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /Bootstrap failed/);
      assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, failure);
      const run = JSON.parse(readFileSync(f.path, 'utf8')).runs[0];
      assert.equal(run.phase, 'cleanup');
      assert.equal(run.cleanup.resourceGroup, failure === 1 ? 'pending' : 'absent');
      assert.equal(mock.cloud.group, null);
    } finally { f.close(); }
  }
});

test('unexpected inventory prevents identity deletion but cannot skip exact paid RG cleanup', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    await bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
    mock.cloud.app.passwordCredentials.push({ keyId: 'unexpected' });
    await assert.rejects(cleanupTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /unowned/);
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
      ...options, coordination: f.coordination, readiness: { ...options.readiness, independentRecoveryReady: false },
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
    await bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
    const invoke = async (operation, payload) => {
      if (operation === 'request' && payload.method === 'DELETE' && payload.step === 'resourceGroup') {
        notify();
        await blocked;
      }
      return mock.invoke(operation, payload);
    };
    const first = cleanupTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination });
    await deleting;
    await assert.rejects(cleanupTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination }), /EEXIST/);
    release();
    await first;
    assert.equal(mock.writes.filter(write => write.method === 'DELETE' && write.step === 'resourceGroup').length, 1);
    writeFileSync(`${f.path}.cleanup.lock`, 'crashed operator');
    const count = mock.writes.length;
    await assert.rejects(cleanupTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination }), /EEXIST/);
    assert.equal(mock.writes.length, count);
  } finally { release?.(); f.close(); }
});

test('late ambiguous RG create remains unresolved until materialized, never false full cleanup', async () => {
  const f = fixture();
  const mock = fakeTransport(1);
  try {
    await assert.rejects(bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /cleanup is unverified/);
    let state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].cleanup.resourceGroup, 'pending');
    assert.equal(state.runs[0].phase, 'cleanup');
    const create = mock.writes.find(write => write.step === 'resourceGroup');
    mock.cloud.group = { id: scope, ...create.body };
    await assert.rejects(cleanupTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /receipt/);
    state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].phase, 'cleanup');
    assert.equal(mock.writes.filter(write => write.method !== 'DELETE').length, 1);
  } finally { f.close(); }
});

test('lost delete response or crash after intent cannot certify early ARM absence or retry', async () => {
  const f = fixture();
  const mock = fakeTransport();
  try {
    await bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
    const uncertain = async (operation, payload) => {
      const result = await mock.invoke(operation, payload);
      if (operation === 'request' && payload.method === 'DELETE' && payload.step === 'resourceGroup') {
        throw new Error('response lost after server accepted asynchronous deletion');
      }
      return result;
    };
    await assert.rejects(cleanupTemporaryIdentity(f.path, uncertain, { ...options, coordination: f.coordination }), /response lost/);
    await assert.rejects(cleanupTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination }), /terminal acknowledgement/);
    const state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(state.runs[0].cleanup.resourceGroup, 'reserved');
    assert.equal(state.runs[0].phase, 'cleanup');
    assert.equal(mock.writes.filter(write => write.method === 'DELETE' && write.step === 'resourceGroup').length, 1);
  } finally { f.close(); }
});

test('no coordination adapter fails closed before authentication or mutation', async () => {
  const f = fixture();
  let calls = 0;
  try {
    await assert.rejects(bootstrapTemporaryIdentity(f.path, () => { calls++; }, options), /coordination unavailable/);
    await assert.rejects(cleanupTemporaryIdentity(f.path, () => { calls++; }), /coordination unavailable/);
    assert.equal(calls, 0);
    assert.equal(JSON.parse(readFileSync(f.path, 'utf8')).revision, 0);
  } finally { f.close(); }
});

test('shared mock serializes isolated snapshots; stale copies and cleanup intent fence late writes', async () => {
  const f = fixture();
  const mock = fakeTransport();
  const copy = `${f.path}.copy`;
  writeFileSync(copy, readFileSync(f.path));
  let release;
  const wait = new Promise(resolve => { release = resolve; });
  let notify;
  const sending = new Promise(resolve => { notify = resolve; });
  const invoke = async (operation, payload) => {
    if (operation === 'request' && payload.step === 'resourceGroup') {
      notify();
      await wait;
    }
    return mock.invoke(operation, payload);
  };
  try {
    const first = bootstrapTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination });
    await sending;
    await assert.rejects(bootstrapTemporaryIdentity(copy, invoke, { ...options, coordination: f.coordination }), /EEXIST/);
    release();
    await first;
    await assert.rejects(bootstrapTemporaryIdentity(copy, invoke, { ...options, coordination: f.coordination }), /Stale canonical snapshot/);
    assert.equal(mock.writes.filter(write => write.step === 'resourceGroup').length, 1);
    const snapshot = JSON.parse(readFileSync(f.path, 'utf8'));
    updateIdentityEnvelope(f.path, 'cleanup', {}, f.coordination.session);
    writeFileSync(copy, JSON.stringify(snapshot));
    assert.throws(() => updateIdentityEnvelope(copy, 'record-key-fingerprint', {
      fingerprint: Buffer.alloc(32, 1).toString('base64'),
    }, f.coordination.session), /Stale canonical revision/);
    const cleaning = JSON.parse(readFileSync(f.path, 'utf8'));
    for (const step of ['foundation', 'worker', 'resourceGroup']) {
      assert.throws(() => transitionIdentityEnvelope(cleaning, 'reserve', { step, now }), /cleanup/);
    }
    assert.equal(operationIntent(cleaning, 'cleanup', null).revision, cleaning.revision);
  } finally { release?.(); f.close(); }
});

const operationUrl = `https://management.azure.com/subscriptions/${scope.split('/')[2]}/providers/Microsoft.Resources/locations/swedencentral/operations/${uid(9)}?api-version=2024-03-01`;
test('late Owner creation during terminal settling is freshly inventoried and exactly deleted', async () => {
  const f = fixture();
  const mock = fakeTransport();
  let lateOwner;
  let settled = false;
  try {
    const invoke = async (operation, payload) => {
      if (operation === 'operation-status') {
        mock.cloud.owner = lateOwner;
        settled = true;
        return { state: 'succeeded' };
      }
      if (operation === 'assignments' && lateOwner) assert.equal(settled, true);
      const result = await mock.invoke(operation, payload);
      if (operation === 'request' && payload.step === 'owner' && payload.method === 'PUT') {
        lateOwner = mock.cloud.owner;
        mock.cloud.owner = null;
        return { ...result, receipt: { ...result.receipt, state: 'accepted', operationUrl } };
      }
      return result;
    };
    await assert.rejects(bootstrapTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination }),
      /exact cloud cleanup completed/);
    const deletes = mock.writes.filter(write => write.step === 'owner' && write.method === 'DELETE');
    assert.equal(deletes.length, 1);
    assert.equal(deletes[0].url.split('?')[0], `https://management.azure.com${lateOwner.id}`);
    assert.equal(mock.cloud.owner, null);
    assert.equal(JSON.parse(readFileSync(f.path, 'utf8')).runs[0].phase, 'closed');
  } finally { f.close(); }
});

test('terminal failed RG PUT plus fresh authoritative absence closes without resending and permits run two', async () => {
  const f = fixture();
  const mock = fakeTransport();
  let terminalFailed = false;
  let absentReads = 0;
  try {
    const invoke = async (operation, payload) => {
      if (operation === 'operation-status') {
        terminalFailed = true;
        return { state: 'failed' };
      }
      if (operation === 'group-exists' && terminalFailed) absentReads++;
      const result = await mock.invoke(operation, payload);
      if (operation === 'request' && payload.step === 'resourceGroup' && payload.method === 'PUT') {
        mock.cloud.group = null;
        return { ...result, receipt: { ...result.receipt, state: 'accepted', operationUrl } };
      }
      return result;
    };
    await assert.rejects(bootstrapTemporaryIdentity(f.path, invoke, { ...options, coordination: f.coordination }),
      /exact cloud cleanup completed/);
    const state = JSON.parse(readFileSync(f.path, 'utf8'));
    assert.equal(operationIntent(state, 'mutation', 'resourceGroup').receipt.state, 'failed');
    assert.equal(state.runs[0].phase, 'closed');
    assert.ok(absentReads >= 3);
    assert.equal(mock.writes.length, 1);
    assert.equal(mock.writes[0].method, 'PUT');
    const second = updateIdentityEnvelope(f.path, 'begin', { now, pricing }, f.coordination.session);
    assert.equal(second.runOrdinal, 2);
    assert.equal(second.startedUtc, state.startedUtc);
    assert.equal(mock.writes.length, 1);
  } finally { f.close(); }
});

test('accepted delete settles provider first; early absence and late visibility cannot certify success', async () => {
  for (const outcome of ['unknown', 'failed', 'timeout', 'running', 'succeeded']) {
    const f = fixture();
    const mock = fakeTransport();
    let millis = 0;
    let statusReads = 0;
    let absenceReads = 0;
    try {
      await bootstrapTemporaryIdentity(f.path, mock.invoke, { ...options, coordination: f.coordination });
      const invoke = async (operation, payload) => {
        if (operation === 'operation-status') {
          statusReads++;
          if (outcome === 'timeout') throw new Error('provider timeout/403');
          return { state: outcome };
        }
        if (operation === 'group-exists') {
          absenceReads++;
          // Pre-delete present, early absent, then visible, then finally absent.
          return absenceReads === 1 || absenceReads === 3;
        }
        const response = await mock.invoke(operation, payload);
        if (operation === 'request' && payload.step === 'resourceGroup' && payload.method === 'DELETE') {
          return { ...response, receipt: { ...response.receipt, state: 'accepted', operationUrl } };
        }
        return response;
      };
      const cleaning = cleanupTemporaryIdentity(f.path, invoke, {
        coordination: f.coordination, clock: () => millis, sleep: async () => { millis += 10000; },
      });
      if (outcome === 'succeeded') {
        await cleaning;
        assert.equal(operationIntent(JSON.parse(readFileSync(f.path, 'utf8')), 'delete', 'resourceGroup').receipt.state, 'succeeded');
      } else {
        await assert.rejects(cleaning, /terminal proof|failed|timeout|exhausted/);
        const state = JSON.parse(readFileSync(f.path, 'utf8'));
        assert.equal(state.runs[0].phase, 'cleanup');
        assert.equal(state.runs[0].cleanup.resourceGroup, 'reserved');
        assert.equal(absenceReads, 1);
      }
      assert.ok(statusReads > 0);
      assert.equal(mock.writes.filter(write => write.step === 'resourceGroup' && write.method === 'DELETE').length, 1);
    } finally { f.close(); }
  }
});

test('booleans, arbitrary handles and extra provider/secret fields are not receipts', () => {
  let state = newIdentityEnvelope('a'.repeat(40));
  state = transitionIdentityEnvelope(state, 'begin', { now, pricing });
  state = transitionIdentityEnvelope(state, 'cleanup');
  state = transitionIdentityEnvelope(state, 'reserve-delete', { step: 'resourceGroup' });
  assert.throws(() => transitionIdentityEnvelope(state, 'acknowledge-delete', { step: 'resourceGroup', accepted: true }), /provider receipt/);
  const good = { operationId: operationIntent(state, 'delete', 'resourceGroup').operationId,
    provider: 'arm', state: 'accepted', operationUrl };
  validateProviderReceipt(good, good.operationId);
  for (const bad of [
    { accepted: true }, { ...good, token: 'synthetic' }, { ...good, operationUrl: null },
    { ...good, operationUrl: operationUrl.replace('management.azure.com', 'example.com') },
    { ...good, operationUrl: `${operationUrl}&token=synthetic` },
    { ...good, operationUrl: operationUrl.replace('swedencentral', 'westus') },
  ]) assert.throws(() => validateProviderReceipt(bad, good.operationId));
});

test('actual child-process loss at reservation/send/receipt/rename never reissues; stale lock is read-only', async () => {
  for (const boundary of ['reserve', 'send', 'receipt', 'rename', 'cleanup-lock']) {
    const f = fixture();
    let child;
    try {
      const state = updateIdentityEnvelope(f.path, 'begin', { now, pricing }, f.coordination.session);
      writeFileSync(`${f.path}.canonical`, JSON.stringify(state));
      child = fork(new URL('./fixtures/crash-worker.mjs', import.meta.url), [f.path, boundary], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
      let diagnostics = '';
      child.stderr.on('data', data => { diagnostics += data; });
      const observed = await Promise.race([
        once(child, 'message'),
        once(child, 'exit').then(() => { throw new Error(`Crash worker exited before boundary: ${diagnostics}`); }),
      ]);
      assert.equal(observed[0].stage, boundary);
      const exited = once(child, 'exit');
      child.kill();
      await exited;
      const local = JSON.parse(readFileSync(f.path, 'utf8'));
      const canonical = JSON.parse(readFileSync(`${f.path}.canonical`, 'utf8'));
      assert.equal(local.runs[0].phase, 'active');
      assert.equal(existsSync(`${f.path}.sent`), ['send', 'receipt', 'rename'].includes(boundary));
      if (boundary === 'rename') {
        assert.equal(canonical.revision, local.revision + 1);
        assert.equal(operationIntent(canonical, 'mutation', 'resourceGroup').receipt.state, 'succeeded');
        const inspected = inspectIdentityLock(`${f.path}.lock`);
        assert.equal(inspected.mayUnlock, false);
        assert.equal(inspected.metadata.pid, child.pid);
        assert.throws(() => updateIdentityEnvelope(f.path, 'cleanup'), /EEXIST/);
      } else if (boundary === 'cleanup-lock') {
        const inspected = inspectIdentityLock(`${f.path}.cleanup.lock`);
        assert.equal(inspected.mayUnlock, false);
        // Reusing a currently live PID never makes the stale owner the current process.
        writeFileSync(`${f.path}.cleanup.lock`, JSON.stringify({ ...inspected.metadata, pid: process.pid }));
        assert.equal(inspectIdentityLock(`${f.path}.cleanup.lock`).mayUnlock, false);
        await assert.rejects(cleanupTemporaryIdentity(f.path, () => { throw new Error('must not call'); }, {
          coordination: mockCoordination(f.path),
        }), /EEXIST/);
      } else {
        await assert.rejects(bootstrapTemporaryIdentity(f.path, () => { throw new Error('must not call'); }, {
          ...options, coordination: mockCoordination(f.path),
        }), /must not call/);
        assert.equal(operationIntent(local, 'mutation', 'resourceGroup').receipt?.state ?? null,
          boundary === 'receipt' ? 'succeeded' : null);
        assert.throws(() => updateIdentityEnvelope(f.path, 'reserve', { step: 'resourceGroup', now }), /retry/);
      }
    } finally { if (child?.exitCode === null) child.kill(); f.close(); }
  }
});
