import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, unlinkSync, openSync, closeSync, fsyncSync } from 'node:fs';
import { hostname } from 'node:os';
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
const reviewedRates = Object.freeze({
  b2sHourly: 0.0432, d2lsHourly: 0.091, p4MonthlyUsd: 5.8072,
  natHourly: 0.045, natProcessedGb: 0.045, standardIpv4Hourly: 0.005,
  privateEndpointHourly: 0.01, privateEndpointIngressGb: 0.01, privateEndpointEgressGb: 0.01,
  internetEgressGb: 0.12, privateDnsZoneMonthly: 0.5, privateDnsQueriesPerMillion: 0.4,
  keyVaultOperationsPer10k: 0.03,
});

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
  check(pricing && typeof pricing === 'object' && !Array.isArray(pricing), 'Complete sourced USD meter evidence required.');
  const rateKeys = ['b2sHourly', 'd2lsHourly', 'p4MonthlyUsd', 'natHourly', 'natProcessedGb',
    'standardIpv4Hourly', 'privateEndpointHourly', 'privateEndpointIngressGb', 'privateEndpointEgressGb',
    'internetEgressGb', 'privateDnsZoneMonthly', 'privateDnsQueriesPerMillion', 'keyVaultOperationsPer10k'];
  const metadataKeys = ['schemaVersion', 'source', 'sourceUrl', 'retrievedUtc', 'currencyCode', 'region'];
  exact(Object.keys(pricing).sort(), [...rateKeys, ...metadataKeys].sort(), 'Complete sourced USD meter evidence required.');
  check(pricing.schemaVersion === 1 && pricing.source === 'azure-retail-prices-api' &&
    pricing.sourceUrl === 'https://prices.azure.com/api/retail/prices' &&
    pricing.currencyCode === 'USD' && pricing.region === 'swedencentral',
  'Only the reviewed Azure USD retail-price source and platform region are accepted.');
  const age = timestamp(now) - timestamp(pricing.retrievedUtc);
  check(age >= 0 && age <= 24 * hour, 'Price evidence is stale or future dated.');
  for (const key of rateKeys) check(Number.isFinite(pricing[key]) && pricing[key] === reviewedRates[key],
    'Meter rates must exactly match the reviewed USD source values.');
  const hourly = pricing.b2sHourly + 2 * pricing.d2lsHourly + 3 * (pricing.p4MonthlyUsd / 672) +
    pricing.natHourly + pricing.standardIpv4Hourly + 2 * pricing.privateEndpointHourly;
  const traffic = 2 * (perRunTraffic.natBytes / 1e9 * pricing.natProcessedGb +
    perRunTraffic.egressBytes / 1e9 * pricing.internetEgressGb +
    perRunTraffic.peIngressBytes / 1e9 * pricing.privateEndpointIngressGb +
    perRunTraffic.peEgressBytes / 1e9 * pricing.privateEndpointEgressGb +
    perRunTraffic.dnsQueries / 1e6 * pricing.privateDnsQueriesPerMillion);
  const secretOperations = 2 * 2;
  const total = 4 * hourly + traffic + 2 * pricing.privateDnsZoneMonthly +
    secretOperations / 10000 * pricing.keyVaultOperationsPer10k;
  check(Number.isFinite(total) && total < 10, 'Planned two-run resource and usage projection does not fit the $10 envelope.');
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
    schemaVersion: 2, issue: 81, runId: randomUUID().replaceAll('-', ''), revision: 0, intents: [],
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
  exact(Object.keys(state).sort(), ['schemaVersion', 'issue', 'runId', 'head', 'revision', 'intents',
    'startedUtc', 'workDeadlineUtc', 'hardDeadlineUtc', 'maxFullRuns', 'capUsd', 'runOrdinal', 'runs', 'reservedUsage', 'reservedCostUsd'].sort(),
  'Unexpected envelope fields; secrets do not belong in state.');
  check(state.schemaVersion === 2 && state.issue === 81 && sha.test(state.head) &&
    /^[a-f0-9]{32}$/.test(state.runId) &&
    state.maxFullRuns === 2 && state.capUsd === 10 && Number.isInteger(state.runOrdinal) &&
    state.runOrdinal >= 0 && state.runOrdinal <= 2 && Array.isArray(state.runs) &&
    state.runs.length === state.runOrdinal && Number.isSafeInteger(state.revision) && state.revision >= 0 &&
    Array.isArray(state.intents), 'Envelope scope or limits drift.');
  const operationIds = new Set();
  const intentKeys = new Set();
  for (const intent of state.intents) {
    exact(Object.keys(intent).sort(), ['operationId', 'ordinal', 'revision', 'kind', 'step', 'receipt'].sort(), 'Unexpected intent fields.');
    check(uuid.test(intent.operationId) && !operationIds.has(intent.operationId) &&
      Number.isInteger(intent.ordinal) && intent.ordinal > 0 && intent.ordinal <= state.runOrdinal &&
      Number.isSafeInteger(intent.revision) && intent.revision > 0 && intent.revision <= state.revision &&
      ['mutation', 'cleanup', 'delete'].includes(intent.kind) &&
      (intent.kind === 'cleanup' ? intent.step === null :
        (intent.kind === 'mutation' ? steps : cleanupSteps).includes(intent.step)), 'Invalid canonical operation intent.');
    const key = `${intent.ordinal}:${intent.kind}:${intent.step}`;
    check(!intentKeys.has(key), 'Duplicate operation intent.');
    operationIds.add(intent.operationId);
    intentKeys.add(key);
    if (intent.receipt !== null) {
      validateProviderReceipt(intent.receipt, intent.operationId);
      check(intent.receipt.provider !== 'inventory' || intent.kind === 'delete', 'Inventory cannot acknowledge a mutation.');
    }
  }
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
        /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(run.additionalKeyEvidence.fingerprint) &&
        run.additionalKeyEvidence.fingerprint !== state.runs[0].credential.fingerprint,
      'ONE scoped key does not authorize key two or reuse of the revoked first key.');
    } else {
      check(run.additionalKeyEvidence === null, 'Unexpected additional key authorization.');
    }
    exact(Object.keys(run.credential).sort(), ['fingerprint', 'revocation'].sort(), 'Invalid nonsecret credential evidence.');
    check(['not-requested', 'pending', 'confirmed'].includes(run.credential.revocation) &&
      (run.credential.fingerprint === null || /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(run.credential.fingerprint)),
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
    check((run.phase !== 'active') === intentKeys.has(`${run.ordinal}:cleanup:null`), 'Cleanup requires canonical intent.');
    for (const step of steps) check((run.steps[step] !== 'pending') === intentKeys.has(`${run.ordinal}:mutation:${step}`), 'Mutation reservation lacks intent.');
    for (const step of cleanupSteps) {
      check((run.cleanup[step] !== 'pending') === intentKeys.has(`${run.ordinal}:delete:${step}`), 'Delete reservation lacks intent.');
      if (['accepted', 'absent'].includes(run.cleanup[step])) {
        const deletion = state.intents.find(item => item.ordinal === run.ordinal && item.kind === 'delete' && item.step === step);
        check(deletion.receipt?.state === 'succeeded', 'Cleanup acknowledgement lacks terminal receipt.');
      }
    }
    if (cloudGone) {
      check(state.intents.filter(item => item.ordinal === run.ordinal && item.kind === 'mutation' &&
        !['seedConfirmation', 'test'].includes(item.step)).every(item =>
        ['succeeded', 'failed'].includes(item.receipt?.state)), 'Unsettled mutation prevents full cleanup.');
    }
    if (index < state.runs.length - 1) check(run.phase === 'closed', 'Second run requires first full cleanup.');
  }
}

// Persist each transition before its corresponding external request. Reserved steps are never reissued.
export function transitionIdentityEnvelope(state, action, input = {}) {
  validateIdentityEnvelope(state);
  if (input.expectedRevision !== undefined) check(input.expectedRevision === state.revision, 'Stale canonical revision.');
  const next = structuredClone(state);
  next.revision++;
  const run = next.runs.at(-1);
  function intent(kind, step = null) {
    next.intents.push({ operationId: randomUUID(), ordinal: next.runOrdinal, revision: next.revision, kind, step, receipt: null });
  }
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
      intent('mutation', input.step);
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
        typeof input.fingerprint === 'string' && /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(input.fingerprint),
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
      intent('cleanup');
    } else if (action === 'receipt') {
      const operation = next.intents.find(item => item.operationId === input.receipt?.operationId && item.ordinal === next.runOrdinal);
      check(operation && operation.kind !== 'cleanup', 'Receipt requires exact reserved operation.');
      validateProviderReceipt(input.receipt, operation.operationId);
      check(operation.receipt === null || (operation.receipt.state === 'accepted' &&
        input.receipt.provider === operation.receipt.provider && input.receipt.operationUrl === operation.receipt.operationUrl &&
        ['succeeded', 'failed'].includes(input.receipt.state)), 'Receipt cannot be replaced or downgraded.');
      operation.receipt = structuredClone(input.receipt);
    } else if (action === 'reserve-delete' || action === 'acknowledge-delete' || action === 'verify-absent') {
      check(run.phase === 'cleanup' && cleanupSteps.includes(input.step) &&
        cleanupSteps.slice(0, cleanupSteps.indexOf(input.step)).every(step => run.cleanup[step] === 'absent'),
      'Delete order requires RG then assignment/FIC/application/SP/environment.');
      if (action === 'reserve-delete') {
        check(run.cleanup[input.step] === 'pending', 'No delete retry; reconcile reserved outcome read-only.');
        run.cleanup[input.step] = 'reserved';
        intent('delete', input.step);
      } else if (action === 'acknowledge-delete') {
        const deletion = operationIntent(next, 'delete', input.step);
        check(run.cleanup[input.step] === 'reserved' && deletion.receipt?.state === 'succeeded',
          'Terminal provider receipt required; accepted:true is not evidence.');
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

export function operationIntent(state, kind, step) {
  return state.intents.find(item => item.ordinal === state.runOrdinal && item.kind === kind && item.step === step);
}

export function validateProviderReceipt(receipt, operationId) {
  exact(Object.keys(receipt ?? {}).sort(), ['operationId', 'provider', 'state', 'operationUrl'].sort(), 'Sanitized provider receipt required.');
  check(receipt.operationId === operationId && uuid.test(operationId) &&
    ['arm', 'graph', 'github', 'inventory'].includes(receipt.provider) &&
    ['accepted', 'succeeded', 'failed'].includes(receipt.state), 'Invalid provider operation receipt.');
  if (receipt.operationUrl !== null) {
    check(receipt.provider === 'arm' && typeof receipt.operationUrl === 'string' &&
      /^https:\/\/management\.azure\.com\/subscriptions\/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e\/providers\/Microsoft\.[A-Za-z]+\/locations\/swedencentral\/(?:operations|operationStatuses|operationResults)\/[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\?api-version=\d{4}-\d{2}-\d{2}$/.test(receipt.operationUrl),
    'Unsupported provider handle; never invent or adopt an operation endpoint.');
  }
  check(receipt.state !== 'accepted' || receipt.operationUrl !== null, 'Accepted operation needs actual pollable provider handle.');
}

export function acquireIdentityLock(path, purpose) {
  const fd = openSync(path, 'wx', 0o600);
  const metadata = { ownerId: randomUUID(), host: hostname(), pid: process.pid,
    processStartedUtc: new Date(Date.now() - process.uptime() * 1000).toISOString(), createdUtc: new Date().toISOString(), purpose };
  try { writeFileSync(fd, JSON.stringify(metadata)); fsyncSync(fd); }
  catch (error) { closeSync(fd); throw error; }
  return () => {
    closeSync(fd);
    check(JSON.parse(readFileSync(path, 'utf8')).ownerId === metadata.ownerId, 'Lock owner changed; no unlink.');
    unlinkSync(path);
  };
}

export function inspectIdentityLock(path) {
  // PID existence is not process identity, and remote host/PID reuse cannot authorize recovery.
  return { metadata: JSON.parse(readFileSync(path, 'utf8')), recovery: 'read-only', mayUnlock: false };
}

export function updateIdentityEnvelope(path, action, input, coordination) {
  const lock = `${path}.lock`;
  const release = acquireIdentityLock(lock, 'transition');
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    const state = JSON.parse(readFileSync(path, 'utf8'));
    const next = transitionIdentityEnvelope(state, action, input);
    if (coordination) check(coordination.compareAndSwap(state, next) === true, 'Stale canonical revision; mutation rejected.');
    const fd = openSync(temporary, 'wx', 0o600);
    try { writeFileSync(fd, `${JSON.stringify(next, null, 2)}\n`); fsyncSync(fd); }
    finally { closeSync(fd); }
    renameSync(temporary, path);
    return next;
  } finally {
    try {
      try { unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    } finally {
      release();
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
