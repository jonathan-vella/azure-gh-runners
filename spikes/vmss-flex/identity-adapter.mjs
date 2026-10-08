import { spawnSync } from 'node:child_process';
import { readFileSync, openSync, closeSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleepDefault } from 'node:timers/promises';
import {
  scope, tenant, identityNames, bootstrapPlan, cleanupPlan, assertOwnedIdentityInventory,
  validateIdentityEnvelope, updateIdentityEnvelope,
} from './temporary-identity.mjs';

function check(condition, message) { if (!condition) throw new Error(message); }
function read(path) {
  const state = JSON.parse(readFileSync(path, 'utf8'));
  validateIdentityEnvelope(state);
  return state;
}
function collection(value) {
  check(value && Array.isArray(value.value) && !value['@odata.nextLink'], 'Complete Graph inventory required.');
  return value.value;
}
function pages(value, key) {
  check(Array.isArray(value) && value.every(page => Array.isArray(page[key])), 'Complete GitHub paginated inventory required.');
  return value.flatMap(page => page[key]);
}

export function authenticatedTransport(operation, payload = {}) {
  // The PowerShell transport has a second unconditional source gate. No tokens leave the installed CLI.
  const executionEnabled = false;
  check(executionEnabled, 'Authenticated identity adapter is disabled pending exact-head execution direction.');
  const result = spawnSync('pwsh', ['-NoProfile', '-File', fileURLToPath(new URL('Identity-Transport.ps1', import.meta.url))], {
    input: JSON.stringify({ operation, payload }), encoding: 'utf8',
    timeout: operation === 'request' && payload.step === 'resourceGroup' && payload.method === 'DELETE' ? 910000 : 40000,
    maxBuffer: 1024 * 1024, windowsHide: true,
  });
  check(!result.error && result.status === 0, 'Bounded identity transport failed; output suppressed.');
  return JSON.parse(result.stdout);
}

async function account(invoke) {
  const value = await invoke('account');
  check(value.id === scope.split('/')[2] && value.tenantId === tenant && value.name === 'shared' &&
    value.user?.type === 'user', 'Existing authenticated workstation user in exact shared tenant/subscription required.');
}

function ownedApp(state, item) {
  const name = identityNames(state.runId, state.runOrdinal).displayName;
  const expected = ['spike-id=60', `spike-run-id=${state.runId}`, `spike-head=${state.head}`, `spike-run-ordinal=${state.runOrdinal}`];
  check(item.displayName === name && Array.isArray(item.tags) && item.tags.length === expected.length &&
    expected.every(tag => item.tags.includes(tag)) &&
    item.passwordCredentials?.length === 0 && item.keyCredentials?.length === 0 &&
    item.requiredResourceAccess?.length === 0, 'Ambiguous or unowned app creation; no adoption/deletion.');
}

async function reconcile(path, invoke) {
  let state = read(path);
  const run = state.runs.at(-1);
  const applications = collection(await invoke('apps', { name: identityNames(state.runId, state.runOrdinal).displayName }));
  check(applications.length <= 1, 'Ambiguous app name; stop exact identity cleanup.');
  if (applications.length) {
    check(run.steps.application !== 'pending', 'Unreserved app; no adoption.');
    ownedApp(state, applications[0]);
    if (run.ids.application === null) {
      state = updateIdentityEnvelope(path, 'capture', { step: 'application', id: applications[0].id, clientId: applications[0].appId });
    }
  }
  check(!(run.steps.application === 'reserved' && run.ids.application === null && applications.length === 0),
    'Ambiguous app creation has no terminal evidence; early absence cannot certify cleanup.');
  const ids = state.runs.at(-1).ids;
  const servicePrincipals = ids.client === null ? [] : collection(await invoke('sps', { clientId: ids.client }));
  check(servicePrincipals.length <= 1, 'Ambiguous SP inventory.');
  check(!(run.steps.servicePrincipal === 'reserved' && ids.servicePrincipal === null && servicePrincipals.length === 0),
    'Ambiguous SP creation has no terminal evidence; early absence cannot certify cleanup.');
  if (servicePrincipals.length && ids.servicePrincipal === null) {
    check(run.steps.servicePrincipal !== 'pending', 'Unreserved service principal.');
    const sp = servicePrincipals[0];
    ownedApp(state, { ...sp, requiredResourceAccess: [] });
    check(sp.appId === ids.client, 'SP/client linkage mismatch.');
    state = updateIdentityEnvelope(path, 'capture', { step: 'servicePrincipal', id: sp.id });
  }
  const fics = applications.length ? collection(await invoke('fics', { application: state.runs.at(-1).ids.application })) : [];
  check(fics.length <= 1, 'Unexpected FIC inventory.');
  check(!(applications.length && run.steps.federation === 'reserved' && ids.federation === null && fics.length === 0),
    'Ambiguous FIC creation has no terminal evidence; early absence cannot certify cleanup.');
  if (fics.length && state.runs.at(-1).ids.federation === null) {
    check(run.steps.federation !== 'pending', 'Unreserved FIC.');
    const expected = bootstrapPlanForCleanup(state).federation.body;
    check(Object.entries(expected).every(([key, value]) => JSON.stringify(fics[0][key]) === JSON.stringify(value)), 'Unexpected FIC; no adoption.');
    state = updateIdentityEnvelope(path, 'capture', { step: 'federation', id: fics[0].id });
  }
  const environments = pages(await invoke('environments'), 'environments').filter(env => env.name === 'spike-vmss');
  check(environments.length <= 1, 'Ambiguous environment inventory.');
  check(!(run.steps.environment === 'reserved' && ids.environment === null && environments.length === 0),
    'Ambiguous environment creation has no terminal evidence; early absence cannot certify cleanup.');
  if (environments.length && state.runs.at(-1).ids.environment === null) {
    check(run.steps.environment !== 'pending', 'Unreserved environment; no adoption.');
    // GitHub environments have no ownership tags. A missing response ID is not sufficient to adopt one by name.
    throw new Error('Ambiguous environment create requires operator reconciliation of captured environment ID; no name-only deletion.');
  }
  const env = environments[0] ?? null;
  if (env) env.branchPolicies = pages(await invoke('policies'), 'branch_policies');
  const assignments = state.runs.at(-1).ids.servicePrincipal === null ? [] :
    await invoke('assignments', { servicePrincipal: state.runs.at(-1).ids.servicePrincipal });
  check(Array.isArray(assignments), 'Authoritative role assignment inventory required.');
  const inventory = {
    applications, servicePrincipals,
    federatedCredentials: fics.map(fic => ({ id: fic.id, name: fic.name, issuer: fic.issuer, audiences: fic.audiences, subject: fic.subject })),
    assignments: assignments.map(item => ({ id: item.id, scope: item.scope, roleDefinitionId: item.roleDefinitionId,
      principalId: item.principalId, principalType: item.principalType, condition: item.condition ?? null })),
    environment: env,
  };
  assertOwnedIdentityInventory(state, inventory);
  return { state, inventory };
}

function bootstrapPlanForCleanup(state) {
  const copy = structuredClone(state);
  copy.runs.at(-1).phase = 'active';
  copy.runs.at(-1).cleanup = Object.fromEntries(Object.keys(copy.runs.at(-1).cleanup).map(key => [key, 'pending']));
  return bootstrapPlan(copy);
}

export async function bootstrapTemporaryIdentity(path, invoke = authenticatedTransport, {
  now = () => new Date().toISOString(), pricing, claims, additionalKeyEvidence, readiness,
} = {}) {
  check(readiness && Object.keys(readiness).length === 4 &&
    ['independentRecoveryReady', 'scopedKeyToolReady', 'sshPublicKeyApproved', 'dependencyResolved']
      .every(key => readiness[key] === true),
  'Actual independent recovery, scoped key tooling, approved public key and dependency readiness required before clock/bootstrap.');
  await account(invoke);
  let state = read(path);
  check(state.runOrdinal === 0 || state.runs.at(-1).phase === 'closed', 'No resumed provisioning or individual step retry.');
  // Preflight occurs before begin, but the clock is durable before the first mutation.
  const ordinal = state.runOrdinal + 1;
  check(ordinal <= 2, 'Full-run cap exhausted.');
  const name = identityNames(state.runId, ordinal).displayName;
  check(await invoke('group-exists') === false, 'Exact spike RG must be absent.');
  check(collection(await invoke('apps', { name })).length === 0, 'Never reuse an app name.');
  check(!pages(await invoke('environments'), 'environments').some(env => env.name === 'spike-vmss'), 'Never adopt an existing environment.');
  updateIdentityEnvelope(path, 'begin', { now: now(), pricing, additionalKeyEvidence });
  return provisionReservedBootstrap(path, invoke, { now, claims });
}

export async function provisionReservedBootstrap(path, invoke, { now = () => new Date().toISOString(), claims } = {}) {
  // Testable bounded adapter for an already-started original envelope; production transport remains disabled.
  try {
    await account(invoke);
    for (const step of ['resourceGroup', 'application', 'servicePrincipal', 'environment', 'environmentPolicy', 'federation', 'owner']) {
      let state = read(path);
      updateIdentityEnvelope(path, 'reserve', { step, now: now() });
      state = read(path);
      const plan = bootstrapPlan(state)[step];
      check(plan, 'Missing captured predecessor ID.');
      const value = await invoke('request', { ...plan, statePath: path, step });
      if (['application', 'servicePrincipal', 'federation', 'environment', 'environmentPolicy'].includes(step)) {
        updateIdentityEnvelope(path, 'capture', { step, id: value.id, clientId: value.appId });
      }
      if (step === 'resourceGroup') {
        const group = await invoke('group-read');
        check(group.id === scope && group.location === 'swedencentral' &&
          Object.entries(plan.body.tags).every(([key, tag]) => group.tags?.[key] === tag), 'RG ownership readback mismatch.');
      }
      if (step === 'owner') await reconcile(path, invoke);
      updateIdentityEnvelope(path, 'verify', { step, claims });
    }
    updateIdentityEnvelope(path, 'reserve', { step: 'seedConfirmation', now: now() });
    return { status: 'waiting-approved-coordinator-spike-key', environment: 'spike-vmss', secret: 'GH_APP_PRIVATE_KEY' };
  } catch (error) {
    const state = read(path);
    if (state.runs.at(-1).phase === 'active') updateIdentityEnvelope(path, 'cleanup');
    try { await cleanupTemporaryIdentity(path, invoke); }
    catch { throw new Error('Bootstrap failed and cleanup is unverified; durable state requires bounded operator reconciliation.'); }
    throw new Error('Bootstrap failed; exact cloud cleanup completed. Scoped key revocation may still be pending.');
  }
}

export async function cleanupTemporaryIdentity(path, invoke = authenticatedTransport, {
  clock = () => Date.now(), sleep = sleepDefault,
} = {}) {
  const lockPath = `${path}.cleanup.lock`;
  const lock = openSync(lockPath, 'wx', 0o600);
  try { return await performIdentityCleanup(path, invoke, { clock, sleep }); }
  finally { closeSync(lock); unlinkSync(lockPath); }
}

async function performIdentityCleanup(path, invoke, { clock, sleep }) {
  await account(invoke);
  const recoveryStop = clock() + 45 * 60 * 1000;
  async function pollAbsent(query) {
    while (!await query()) {
      check(clock() + 40000 < recoveryStop, 'Bounded cleanup recovery exhausted; surviving resources may accrue postdeadline charges.');
      await sleep(10000);
    }
  }
  let state = read(path);
  if (state.runs.at(-1)?.phase === 'active') state = updateIdentityEnvelope(path, 'cleanup');
  check(state.runs.at(-1)?.phase === 'cleanup', 'No pending paid cleanup run.');
  const run = state.runs.at(-1);
  // Paid cleanup is first and does not depend on Graph/GitHub availability or owner key revocation.
  if (run.cleanup.resourceGroup !== 'absent') {
    const exists = await invoke('group-exists');
    check(typeof exists === 'boolean', 'RG absence is unverified.');
    if (run.cleanup.resourceGroup === 'pending') {
      check(exists || run.steps.resourceGroup !== 'reserved',
        'Ambiguous RG creation has no terminal evidence; early absence cannot certify cleanup.');
      if (exists) {
        const group = await invoke('group-read');
        const plan = bootstrapPlanForCleanup(state).resourceGroup;
        check(run.steps.resourceGroup !== 'pending' && group.id === scope && group.location === 'swedencentral' &&
          Object.entries(plan.body.tags).every(([key, value]) => group.tags?.[key] === value), 'Unowned RG; no deletion.');
      }
      updateIdentityEnvelope(path, 'reserve-delete', { step: 'resourceGroup' });
      if (exists) await invoke('request', { method: 'DELETE', url: `https://management.azure.com${scope}?api-version=2024-03-01`, statePath: path, step: 'resourceGroup' });
      updateIdentityEnvelope(path, 'acknowledge-delete', { step: 'resourceGroup', accepted: true });
    }
    check(read(path).runs.at(-1).cleanup.resourceGroup === 'accepted',
      'Interrupted RG delete has no terminal acknowledgement; reconcile without reissuing or certifying early absence.');
    await pollAbsent(async () => {
      const present = await invoke('group-exists');
      check(typeof present === 'boolean', 'Authoritative RG existence required.');
      return !present;
    });
    updateIdentityEnvelope(path, 'verify-absent', { step: 'resourceGroup', absent: true });
  }
  for (const step of ['owner', 'federation', 'application', 'servicePrincipal', 'environment']) {
    state = read(path);
    if (state.runs.at(-1).cleanup[step] === 'absent') continue;
    const reconciled = await reconcile(path, invoke);
    state = reconciled.state;
    let { inventory } = reconciled;
    const plan = cleanupPlan(state, { ...inventory, resourceGroup: null });
    const key = { owner: 'assignments', federation: 'federatedCredentials', application: 'applications', servicePrincipal: 'servicePrincipals' }[step];
    const exists = step === 'environment' ? inventory.environment !== null : inventory[key].length !== 0;
    if (state.runs.at(-1).cleanup[step] === 'pending') {
      updateIdentityEnvelope(path, 'reserve-delete', { step });
      if (exists) {
        check(plan[step], 'Exact captured cleanup ID required.');
        await invoke('request', { method: 'DELETE', url: plan[step], statePath: path, step });
      }
      updateIdentityEnvelope(path, 'acknowledge-delete', { step, accepted: true });
    }
    check(read(path).runs.at(-1).cleanup[step] === 'accepted',
      'Interrupted identity delete has no acknowledgement; reconcile without retry or false full cleanup.');
    await pollAbsent(async () => {
      ({ inventory } = await reconcile(path, invoke));
      return step === 'environment' ? inventory.environment === null : inventory[key].length === 0;
    });
    updateIdentityEnvelope(path, 'verify-absent', { step, absent: true });
  }
  const final = read(path).runs.at(-1);
  return { status: final.phase, credentialRevocationPending: final.credential.revocation === 'pending' };
}
