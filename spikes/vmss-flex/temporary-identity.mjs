import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, unlinkSync, openSync, closeSync } from 'node:fs';
import assert from 'node:assert/strict';

export const scope = '/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike-vmss-swc';
export const tenant = '30bac921-1547-4b1e-8445-72455da783f1';
const issuer = 'https://token.actions.githubusercontent.com';
const audience = 'api://AzureADTokenExchange';
export const environmentName = 'spike-vmss';
const subject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss';
const ownerRole = '/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635';
const protectedIds = new Set([
  '24ebb9cc-0e3b-4956-a333-5665a060f2c7', '4495f30e-3a65-4e94-8d4a-d13dcbe10204',
  '5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0', '70a73ebc-1a9a-4b56-9157-52ec84658ea5',
  '1536c7e0-d4f4-4979-a0b9-702a8fda4f87', '5432b0f4-2bc8-42b6-9c12-1018c9937d9a',
]);
const steps = ['resourceGroup', 'application', 'servicePrincipal', 'environment', 'environmentPolicy', 'federation', 'owner', 'seedConfirmation', 'foundation', 'worker', 'test'];
const cleanupSteps = ['resourceGroup', 'owner', 'federation', 'application', 'servicePrincipal', 'environment'];
const sha = /^[a-f0-9]{40}$/;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const hour = 60 * 60 * 1000;
const perRunTraffic = {
  guests: 2, natBytes: 8589934592, egressBytes: 4294967296,
  peIngressBytes: 4294967296, peEgressBytes: 4294967296, dnsQueries: 57640,
};

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function objectId(value) {
  check(typeof value === 'string' && uuid.test(value) && !protectedIds.has(value), 'Unexpected or protected identity ID.');
  return value;
}

function timestamp(value) {
  check(typeof value === 'string' && Number.isFinite(Date.parse(value)) &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{4})?(?:Z|\+00:00)$/.test(value) &&
    new Date(value).toISOString().slice(0, 23) === value.slice(0, 23), 'Exact UTC timestamp required.');
  return Date.parse(value);
}

function exact(actual, expected, message) {
  try { assert.deepStrictEqual(actual, expected); } catch { throw new Error(message); }
}

export function priceOriginalEnvelope(pricing, now) {
  check(pricing && typeof pricing === 'object' && !Array.isArray(pricing), 'Complete effective USD rate/contingency record required.');
  const rateKeys = ['b2sHourly', 'd2lsHourly', 'p4Hourly', 'natHourly', 'pipHourly', 'peHourly',
    'dnsZonePerRun', 'natGb', 'egressGb', 'peIngressGb', 'peEgressGb', 'dnsMillionQueries',
    'kvPerRunCeilingUsd', 'logsCombinedCeilingUsd', 'imageCombinedCeilingUsd', 'cleanupReserveUsd', 'miscCombinedCeilingUsd'];
  exact(Object.keys(pricing).sort(), [...rateKeys, 'refreshedUtc'].sort(), 'Complete effective USD rate/contingency record required.');
  const age = timestamp(now) - timestamp(pricing.refreshedUtc);
  check(age >= 0 && age <= 24 * hour, 'Price evidence is stale or future dated.');
  for (const key of rateKeys) check(Number.isFinite(pricing[key]) && pricing[key] > 0, 'Positive finite effective USD rates required; no zero fallback.');
  const hourly = pricing.b2sHourly + 2 * pricing.d2lsHourly + 3 * pricing.p4Hourly +
    pricing.natHourly + pricing.pipHourly + 2 * pricing.peHourly;
  const traffic = 2 * (perRunTraffic.natBytes / 1e9 * pricing.natGb +
    perRunTraffic.egressBytes / 1e9 * pricing.egressGb +
    perRunTraffic.peIngressBytes / 1e9 * pricing.peIngressGb +
    perRunTraffic.peEgressBytes / 1e9 * pricing.peEgressGb +
    perRunTraffic.dnsQueries / 1e6 * pricing.dnsMillionQueries);
  const total = 4 * hourly + traffic + 2 * (pricing.dnsZonePerRun + pricing.kvPerRunCeilingUsd) +
    pricing.logsCombinedCeilingUsd + pricing.imageCombinedCeilingUsd +
    pricing.cleanupReserveUsd + pricing.miscCombinedCeilingUsd;
  check(Number.isFinite(total) && total < 10, 'Full two-run original envelope including bootstrap/cleanup does not fit $10.');
  return total;
}

export function identityNames(runId, runOrdinal) {
  check(typeof runId === 'string' && /^[a-f0-9]{32}$/.test(runId) &&
    Number.isInteger(runOrdinal) && runOrdinal >= 1 && runOrdinal <= 2, 'Invalid envelope nonce or ordinal.');
  const name = `sp-ghrunners-spike60-${runId}-${runOrdinal}`;
  const hash = createHash('sha256').update(`${name}:owner`).digest('hex').slice(0, 32);
  return {
    displayName: name, ficName: `spike60-${runId}-${runOrdinal}`,
    assignmentId: `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20)}`,
  };
}

export function newIdentityEnvelope(head) {
  check(sha.test(head), 'Exact reviewed source SHA required.');
  return {
    schemaVersion: 1, issue: 81, runId: randomUUID().replaceAll('-', ''),
    head, startedUtc: null, workDeadlineUtc: null, hardDeadlineUtc: null,
    maxFullRuns: 2, capUsd: 10, runOrdinal: 0, runs: [],
    reservedUsage: Object.fromEntries(Object.keys(perRunTraffic).map(key => [key, 0])),
    reservedCostUsd: 0,
  };
}

function tags(state, ordinal) {
  return { 'spike-id': '60', 'spike-run-id': state.runId, 'spike-head': state.head, 'spike-run-ordinal': String(ordinal) };
}

function appTags(state, ordinal) {
  return Object.entries(tags(state, ordinal)).map(([key, value]) => `${key}=${value}`);
}

export function standardCredential(state) {
  validateIdentityEnvelope(state);
  const names = identityNames(state.runId, state.runOrdinal);
  return {
    name: names.ficName, issuer, audiences: [audience], subject,
  };
}

export function assertSanitizedEnvironmentClaims(claims) {
  exact(claims, { iss: issuer, aud: audience, sub: subject,
    repository_id: '1408821667', repository_owner_id: '25802147' },
  'Sanitized actual environment claims differ; never change repository or production trust to compensate.');
}

export function validateIdentityEnvelope(state) {
  check(state && typeof state === 'object', 'Missing identity envelope.');
  exact(Object.keys(state).sort(), ['schemaVersion', 'issue', 'runId', 'head',
    'startedUtc', 'workDeadlineUtc', 'hardDeadlineUtc', 'maxFullRuns', 'capUsd', 'runOrdinal', 'runs', 'reservedUsage', 'reservedCostUsd'].sort(),
  'Unexpected envelope fields; secrets do not belong in state.');
  check(state.schemaVersion === 1 && state.issue === 81 && sha.test(state.head) &&
    /^[a-f0-9]{32}$/.test(state.runId) &&
    state.maxFullRuns === 2 && state.capUsd === 10 && Number.isInteger(state.runOrdinal) &&
    state.runOrdinal >= 0 && state.runOrdinal <= 2 && Array.isArray(state.runs) &&
    state.runs.length === state.runOrdinal, 'Envelope scope or limits drift.');
  exact(state.reservedUsage, Object.fromEntries(Object.entries(perRunTraffic).map(([key, value]) =>
    [key, value * state.runOrdinal])), 'Cumulative original-envelope traffic/guest/DNS reservation drift.');
  check(state.reservedCostUsd === Math.max(0, ...state.runs.map(run => run.projectedCombinedUsd)),
    'Original cost reservation cannot be refunded or reset.');
  if (state.startedUtc === null) {
    check(state.runOrdinal === 0 && state.workDeadlineUtc === null && state.hardDeadlineUtc === null,
      'Unstarted envelope contains runtime state.');
  } else {
    const start = timestamp(state.startedUtc);
    check(timestamp(state.workDeadlineUtc) === start + 3 * hour &&
      timestamp(state.hardDeadlineUtc) === start + 4 * hour, 'Original envelope clock drift.');
  }
  const allIds = new Set();
  const keyFingerprints = new Set();
  for (const [index, run] of state.runs.entries()) {
    exact(Object.keys(run).sort(), ['ordinal', 'phase', 'steps', 'ids', 'cleanup', 'projectedCombinedUsd', 'pricing', 'pricedUtc', 'credential', 'additionalKeyEvidence'].sort(), 'Unexpected run fields.');
    check(run.ordinal === index + 1 && ['active', 'cleanup', 'credential-revocation', 'closed'].includes(run.phase), 'Invalid run transition.');
    check(Number.isFinite(run.projectedCombinedUsd) && run.projectedCombinedUsd > 0 &&
      run.projectedCombinedUsd < 10, 'Invalid combined cost reservation.');
    check(run.projectedCombinedUsd === priceOriginalEnvelope(run.pricing, run.pricedUtc), 'Combined cost calculation drift.');
    exact(Object.keys(run.steps).sort(), steps.slice().sort(), 'Invalid reserved step list.');
    exact(Object.keys(run.cleanup).sort(), cleanupSteps.slice().sort(), 'Invalid cleanup list.');
    let pending = false;
    for (const step of steps) {
      check(['pending', 'reserved', 'verified'].includes(run.steps[step]), 'Invalid step state.');
      if (pending) check(run.steps[step] === 'pending', 'A later step bypassed a reservation.');
      if (run.steps[step] !== 'verified') pending = true;
    }
    exact(Object.keys(run.ids).sort(), ['application', 'client', 'servicePrincipal', 'federation', 'environment', 'environmentPolicy'].sort(), 'Invalid captured IDs.');
    const ids = ['application', 'client', 'servicePrincipal', 'federation'].map(key => run.ids[key]).filter(value => value !== null);
    ids.forEach(objectId);
    check(new Set(ids).size === ids.length, 'Identity object IDs must be distinct.');
    for (const id of ids) {
      check(!allIds.has(id), 'Never reuse a prior full run identity.');
      allIds.add(id);
    }
    for (const step of ['application', 'servicePrincipal', 'federation', 'environment', 'environmentPolicy']) {
      if (run.steps[step] === 'verified') check(run.ids[step] !== null, 'Verified step has no captured object ID.');
      if (run.steps[step] === 'pending') check(run.ids[step] === null, 'Unreserved step has captured ID.');
    }
    for (const step of ['environment', 'environmentPolicy']) {
      check(run.ids[step] === null || (Number.isSafeInteger(run.ids[step]) && run.ids[step] > 0), 'Invalid GitHub environment metadata ID.');
    }
    check((run.ids.application === null) === (run.ids.client === null), 'Application/client capture must be atomic.');
    if (index === 1 && state.runs[0].credential.fingerprint !== null) {
      exact(Object.keys(run.additionalKeyEvidence ?? {}).sort(), ['separatelyApproved', 'keyReady', 'fingerprint'].sort(),
        'A second seeded run needs separately approved fresh-key-ready evidence.');
      check(run.additionalKeyEvidence.separatelyApproved === true && run.additionalKeyEvidence.keyReady === true &&
        /^[a-f0-9]{64}$/.test(run.additionalKeyEvidence.fingerprint) &&
        run.additionalKeyEvidence.fingerprint !== state.runs[0].credential.fingerprint,
      'ONE scoped key does not authorize key two or reuse of the revoked first key.');
    } else {
      check(run.additionalKeyEvidence === null, 'Unexpected additional key authorization.');
    }
    exact(Object.keys(run.credential).sort(), ['fingerprint', 'revocation'].sort(), 'Invalid nonsecret credential evidence.');
    check(['not-requested', 'pending', 'confirmed'].includes(run.credential.revocation) &&
      (run.credential.fingerprint === null || /^[a-f0-9]{64}$/.test(run.credential.fingerprint)),
    'Invalid owner-supplied public-key SHA256 fingerprint.');
    if (run.steps.seedConfirmation === 'pending') {
      check(run.credential.revocation === 'not-requested' && run.credential.fingerprint === null, 'Unrequested key evidence.');
    } else {
      check(run.credential.revocation !== 'not-requested', 'Requested key must remain pending until owner confirms revocation.');
      if (run.steps.seedConfirmation === 'verified') check(run.credential.fingerprint !== null, 'Confirmed seed needs nonsecret fingerprint.');
    }
    if (run.credential.fingerprint !== null) {
      check(!keyFingerprints.has(run.credential.fingerprint), 'Never reuse a prior revoked spike key.');
      keyFingerprints.add(run.credential.fingerprint);
      if (run.additionalKeyEvidence !== null) check(run.credential.fingerprint === run.additionalKeyEvidence.fingerprint,
        'Seed fingerprint differs from separately approved fresh key.');
    }
    let notAbsent = false;
    for (const step of cleanupSteps) {
      check(['pending', 'reserved', 'accepted', 'absent'].includes(run.cleanup[step]), 'Invalid cleanup state.');
      if (notAbsent) check(run.cleanup[step] === 'pending', 'Cleanup order bypassed.');
      if (run.cleanup[step] !== 'absent') notAbsent = true;
    }
    const cloudGone = !notAbsent;
    const credentialGone = run.credential.revocation !== 'pending';
    check((run.phase === 'closed') === (cloudGone && credentialGone), 'Closed run requires all absence and credential revocation evidence.');
    check((run.phase === 'credential-revocation') === (cloudGone && !credentialGone), 'Credential cleanup must be reported separately from paid cleanup.');
    if (run.phase === 'active') check(Object.values(run.cleanup).every(value => value === 'pending'), 'Active run contains cleanup.');
    if (index < state.runs.length - 1) check(run.phase === 'closed', 'Second run requires first full cleanup.');
  }
}

// Persist each transition before its corresponding external request. Reserved steps are never reissued.
export function transitionIdentityEnvelope(state, action, input = {}) {
  validateIdentityEnvelope(state);
  const next = structuredClone(state);
  const run = next.runs.at(-1);
  if (action === 'begin') {
    const now = timestamp(input.now);
    check(next.runOrdinal < 2 && (!run || run.phase === 'closed'), 'Previous run cleanup incomplete or full-run cap exhausted.');
    const projectedCombinedUsd = priceOriginalEnvelope(input.pricing, input.now);
    next.reservedCostUsd = Math.max(next.reservedCostUsd, projectedCombinedUsd);
    if (next.startedUtc === null) {
      next.startedUtc = input.now;
      next.workDeadlineUtc = new Date(now + 3 * hour).toISOString();
      next.hardDeadlineUtc = new Date(now + 4 * hour).toISOString();
    }
    check(now >= timestamp(next.startedUtc) && now + 45 * 60 * 1000 < timestamp(next.workDeadlineUtc),
      'Insufficient original work window; cleanup reserve cannot be consumed.');
    next.runOrdinal++;
    next.reservedUsage = Object.fromEntries(Object.entries(perRunTraffic).map(([key, value]) => [key, value * next.runOrdinal]));
    next.runs.push({
      ordinal: next.runOrdinal, phase: 'active', projectedCombinedUsd, pricing: structuredClone(input.pricing), pricedUtc: input.now,
      steps: Object.fromEntries(steps.map(step => [step, 'pending'])),
      ids: { application: null, client: null, servicePrincipal: null, federation: null, environment: null, environmentPolicy: null },
      cleanup: Object.fromEntries(cleanupSteps.map(step => [step, 'pending'])),
      credential: { fingerprint: null, revocation: 'not-requested' },
      additionalKeyEvidence: run?.credential.fingerprint ? structuredClone(input.additionalKeyEvidence ?? null) : null,
    });
  } else {
    check(run, 'No full run was started.');
    if (action === 'reserve') {
      const now = timestamp(input.now);
      check(run.phase === 'active' && steps.includes(input.step) &&
        run.steps[input.step] === 'pending' && steps.slice(0, steps.indexOf(input.step)).every(step => run.steps[step] === 'verified'),
      'No step retry, bypass or work after cleanup.');
      check(now >= timestamp(next.startedUtc) && now + 30 * 1000 < timestamp(next.workDeadlineUtc), 'Work deadline exhausted.');
      run.steps[input.step] = 'reserved';
      if (input.step === 'seedConfirmation') run.credential.revocation = 'pending';
    } else if (action === 'verify') {
      check(run.phase === 'active' && steps.includes(input.step) && run.steps[input.step] === 'reserved', 'Unreserved verification.');
      check(!['application', 'servicePrincipal', 'federation', 'environment', 'environmentPolicy'].includes(input.step) || run.ids[input.step] !== null,
        'Reconcile captured identity metadata before verification.');
      if (input.step === 'federation') assertSanitizedEnvironmentClaims(input.claims);
      if (input.step === 'seedConfirmation') check(input.seedConfirmed === true,
        'Explicit approved coordinator seed evidence required; metadata existence is not confirmation.');
      if (input.step === 'seedConfirmation') check(run.credential.fingerprint !== null, 'Owner-supplied public-key fingerprint required.');
      run.steps[input.step] = 'verified';
    } else if (action === 'record-key-fingerprint') {
      check(run.steps.seedConfirmation === 'reserved' &&
        (run.credential.fingerprint === null || run.credential.fingerprint === input.fingerprint) &&
        typeof input.fingerprint === 'string' && /^[a-f0-9]{64}$/.test(input.fingerprint),
      'Capture exactly one owner-supplied nonsecret SHA256 public-key fingerprint.');
      run.credential.fingerprint = input.fingerprint;
    } else if (action === 'confirm-key-revocation') {
      check(['cleanup', 'credential-revocation'].includes(run.phase) && run.credential.revocation === 'pending' &&
        input.revocationConfirmed === true, 'Only explicit approved coordinator evidence can confirm spike-key revocation.');
      check(run.credential.fingerprint === null ? input.noKeyCreatedConfirmed === true :
        input.fingerprint === run.credential.fingerprint, 'Confirm the exact spike-key fingerprint, never revoke production keys.');
      run.credential.revocation = 'confirmed';
      if (run.phase === 'credential-revocation') run.phase = 'closed';
    } else if (action === 'capture') {
      check(['application', 'servicePrincipal', 'federation', 'environment', 'environmentPolicy'].includes(input.step) &&
        run.steps[input.step] === 'reserved' && run.ids[input.step] === null, 'Unexpected identity capture.');
      if (['environment', 'environmentPolicy'].includes(input.step)) {
        check(Number.isSafeInteger(input.id) && input.id > 0, 'Invalid GitHub metadata ID.');
        run.ids[input.step] = input.id;
      } else {
        run.ids[input.step] = objectId(input.id);
      }
      if (input.step === 'application') run.ids.client = objectId(input.clientId);
    } else if (action === 'cleanup') {
      check(run.phase === 'active', 'Run already entered cleanup.');
      run.phase = 'cleanup';
    } else if (action === 'reserve-delete' || action === 'acknowledge-delete' || action === 'verify-absent') {
      check(run.phase === 'cleanup' && cleanupSteps.includes(input.step) &&
        cleanupSteps.slice(0, cleanupSteps.indexOf(input.step)).every(step => run.cleanup[step] === 'absent'),
      'Delete order requires RG then assignment/FIC/application/SP/environment.');
      if (action === 'reserve-delete') {
        check(run.cleanup[input.step] === 'pending', 'No delete retry; reconcile reserved outcome read-only.');
        run.cleanup[input.step] = 'reserved';
      } else if (action === 'acknowledge-delete') {
        check(run.cleanup[input.step] === 'reserved' && input.accepted === true,
          'Actual successful delete response or verified never-created evidence required.');
        run.cleanup[input.step] = 'accepted';
      } else {
        check(run.cleanup[input.step] === 'accepted' && input.absent === true, 'Explicit acknowledged deletion and authoritative absence required.');
        run.cleanup[input.step] = 'absent';
        if (Object.values(run.cleanup).every(value => value === 'absent')) {
          run.phase = run.credential.revocation === 'pending' ? 'credential-revocation' : 'closed';
        }
      }
    } else {
      throw new Error('Unknown identity transition.');
    }
  }
  validateIdentityEnvelope(next);
  return next;
}

export function writeIdentityEnvelope(path, initial) {
  validateIdentityEnvelope(initial);
  check(initial.runOrdinal === 0 && initial.startedUtc === null, 'Only a fresh envelope may be initialized.');
  writeFileSync(path, `${JSON.stringify(initial, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
}

export function updateIdentityEnvelope(path, action, input) {
  const lock = `${path}.lock`;
  const fd = openSync(lock, 'wx', 0o600);
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    const state = JSON.parse(readFileSync(path, 'utf8'));
    const next = transitionIdentityEnvelope(state, action, input);
    writeFileSync(temporary, `${JSON.stringify(next, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    renameSync(temporary, path);
    return next;
  } finally {
    try {
      try { unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    } finally {
      closeSync(fd);
      unlinkSync(lock);
    }
  }
}

export function bootstrapPlan(state) {
  validateIdentityEnvelope(state);
  check(state.runs.at(-1)?.phase === 'active', 'Start the original clock and full run before planning bootstrap.');
  const names = identityNames(state.runId, state.runOrdinal);
  const ids = state.runs.at(-1).ids;
  return {
    enabled: false, tenant, scope, names,
    seed: { environment: environmentName, secret: 'GH_APP_PRIVATE_KEY', method: 'approved-coordinator-only',
      appId: 5224898, key: 'one-new-spike-only-key-same-App',
      explicitSeedEvidenceRequired: true, thisAdapterMayCreateReadOrTransfer: false },
    resourceGroup: {
      method: 'PUT', url: `https://management.azure.com${scope}?api-version=2024-03-01`,
      body: { location: 'swedencentral', tags: {
        application: 'ghrunners', environment: 'spike', workload: 'gh-runners',
        owner: 'jonathan-vella', costcenter: 'platform-engineering',
        'tech-contact': 'jonathan-vella', 'technical-contact': 'jonathan-vella',
        sla: 'development', 'backup-policy': 'none', 'maint-window': 'none', ...tags(state, state.runOrdinal),
      } },
    },
    application: {
      method: 'POST', url: 'https://graph.microsoft.com/v1.0/applications',
      body: { displayName: names.displayName, signInAudience: 'AzureADMyOrg', tags: appTags(state, state.runOrdinal),
        passwordCredentials: [], keyCredentials: [], requiredResourceAccess: [] },
    },
    servicePrincipal: ids.client === null ? null : {
      method: 'POST', url: 'https://graph.microsoft.com/v1.0/servicePrincipals',
      body: { appId: ids.client, displayName: names.displayName, tags: appTags(state, state.runOrdinal) },
    },
    environment: {
      method: 'PUT', url: `https://api.github.com/repos/jonathan-vella/azure-gh-runners/environments/${environmentName}`,
      body: { wait_timer: 0, reviewers: [], deployment_branch_policy: { protected_branches: false, custom_branch_policies: true } },
    },
    environmentPolicy: ids.environment === null ? null : {
      method: 'POST', url: `https://api.github.com/repos/jonathan-vella/azure-gh-runners/environments/${environmentName}/deployment-branch-policies`,
      body: { name: 'main', type: 'branch' },
    },
    federation: ids.application === null ? null : {
      method: 'POST', url: `https://graph.microsoft.com/v1.0/applications/${ids.application}/federatedIdentityCredentials`,
      body: standardCredential(state),
    },
    owner: ids.servicePrincipal === null ? null : {
      method: 'PUT', url: `https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/${names.assignmentId}?api-version=2022-04-01`,
      body: { properties: { roleDefinitionId: ownerRole, principalId: ids.servicePrincipal, principalType: 'ServicePrincipal' } },
    },
  };
}

export function assertOwnedIdentityInventory(state, inventory) {
  validateIdentityEnvelope(state);
  const run = state.runs.at(-1);
  check(run && inventory && typeof inventory === 'object', 'Missing authoritative reconciliation inventory.');
  const names = identityNames(state.runId, state.runOrdinal);
  const expectedTags = appTags(state, state.runOrdinal);
  for (const [kind, values] of [['application', inventory.applications], ['servicePrincipal', inventory.servicePrincipals]]) {
    check(Array.isArray(values) && values.length <= 1, 'Ambiguous identity inventory; no deletion.');
    for (const item of values) {
      check(run.steps[kind] !== 'pending', 'Unreserved identity exists; no deletion.');
      objectId(item.id);
      objectId(item.appId);
      check(item.displayName === names.displayName && item.appId === run.ids.client &&
        item.id === run.ids[kind], 'Captured identity linkage mismatch; reconcile exact tagged create outcome first.');
      exact(item.tags?.slice().sort(), expectedTags.slice().sort(), 'Identity ownership tags differ.');
      exact(item.passwordCredentials, [], 'Unexpected password credential.');
      exact(item.keyCredentials, [], 'Unexpected certificate credential.');
      if (kind === 'application') {
        check(item.signInAudience === 'AzureADMyOrg', 'Temporary application must remain single tenant.');
        exact(item.requiredResourceAccess, [], 'Unexpected API permissions.');
      }
    }
  }
  check(Array.isArray(inventory.assignments) && inventory.assignments.length <= 1, 'Unexpected role grants.');
  for (const assignment of inventory.assignments) {
    check(run.steps.owner !== 'pending' && run.ids.servicePrincipal !== null, 'Unreserved Owner grant.');
    exact(assignment, {
      id: `${scope}/providers/Microsoft.Authorization/roleAssignments/${names.assignmentId}`,
      scope, roleDefinitionId: ownerRole, principalId: run.ids.servicePrincipal, principalType: 'ServicePrincipal',
      condition: null,
    }, 'Only the exact captured SP, assignment ID and RG Owner grant are permitted.');
  }
  check(Array.isArray(inventory.federatedCredentials) && inventory.federatedCredentials.length <= 1, 'Unexpected FIC count.');
  for (const fic of inventory.federatedCredentials) {
    check(run.steps.federation !== 'pending' && run.ids.federation !== null, 'Unreserved FIC.');
    exact(fic, { id: run.ids.federation, ...standardCredential(state) }, 'Federation differs from exact reviewed environment subject.');
  }
  if (inventory.environment !== null) {
    const env = inventory.environment;
    check(run.steps.environment !== 'pending' && env.id === run.ids.environment &&
      env.name === environmentName, 'Environment capture/ownership mismatch.');
    exact(env.deployment_branch_policy, { protected_branches: false, custom_branch_policies: true }, 'Unexpected environment branch policy.');
    check(Array.isArray(env.protection_rules) && env.protection_rules.every(rule => rule.type === 'branch_policy'),
      'Unexpected environment reviewer, wait timer or protection rule.');
    if (run.ids.environmentPolicy === null) {
      exact(env.branchPolicies, [], 'Uncaptured environment branch policy.');
    } else {
      exact(env.branchPolicies, [{ id: run.ids.environmentPolicy, name: 'main', type: 'branch' }], 'Environment must allow only main branch, not tags.');
    }
  }
}

export function cleanupPlan(state, inventory) {
  assertOwnedIdentityInventory(state, inventory);
  const run = state.runs.at(-1);
  check(run.phase === 'cleanup', 'Cleanup transition must be durable before deletion.');
  check(inventory.resourceGroup === null || (
    inventory.resourceGroup.id === scope && inventory.resourceGroup.location === 'swedencentral' &&
    Object.entries(tags(state, state.runOrdinal)).every(([key, value]) => inventory.resourceGroup.tags?.[key] === value) &&
    run.steps.resourceGroup !== 'pending'), 'Unowned resource group; no deletion.');
  const names = identityNames(state.runId, state.runOrdinal);
  return {
    enabled: false,
    // Null IDs require bounded read-only tagged reconciliation, never a name-only delete.
    resourceGroup: `https://management.azure.com${scope}?api-version=2024-03-01`,
    owner: `https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/${names.assignmentId}?api-version=2022-04-01`,
    federation: run.ids.application && run.ids.federation ?
      `https://graph.microsoft.com/v1.0/applications/${run.ids.application}/federatedIdentityCredentials/${run.ids.federation}` : null,
    application: run.ids.application ? `https://graph.microsoft.com/v1.0/applications/${run.ids.application}` : null,
    servicePrincipal: run.ids.servicePrincipal ? `https://graph.microsoft.com/v1.0/servicePrincipals/${run.ids.servicePrincipal}` : null,
    environment: run.ids.environment ? `https://api.github.com/repos/jonathan-vella/azure-gh-runners/environments/${environmentName}` : null,
  };
}

export function executeTemporaryIdentity() {
  throw new Error('Temporary identity execution is disabled: exact-head review, sanitized environment-subject verification, credential delivery and independent operator cleanup integration are required.');
}
