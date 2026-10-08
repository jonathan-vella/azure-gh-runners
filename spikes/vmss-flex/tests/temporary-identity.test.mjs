import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  newIdentityEnvelope, validateIdentityEnvelope, identityNames, transitionIdentityEnvelope,
  writeIdentityEnvelope, updateIdentityEnvelope, standardCredential, assertSanitizedEnvironmentClaims,
  bootstrapPlan, cleanupPlan, assertOwnedIdentityInventory, executeTemporaryIdentity, scope,
  priceOriginalEnvelope,
} from '../temporary-identity.mjs';

const now = '2026-10-08T05:00:00.000Z';
const head = 'a'.repeat(40);
const fingerprint = Buffer.alloc(32, 1).toString('base64');
const pricing = {
  schemaVersion: 1, source: 'azure-retail-prices-api', sourceUrl: 'https://prices.azure.com/api/retail/prices',
  retrievedUtc: now, currencyCode: 'USD', region: 'swedencentral',
  b2sHourly: 0.0432, d2lsHourly: 0.091, p4MonthlyUsd: 5.8072,
  natHourly: 0.045, natProcessedGb: 0.045, standardIpv4Hourly: 0.005,
  privateEndpointHourly: 0.01, privateEndpointIngressGb: 0.01, privateEndpointEgressGb: 0.01,
  internetEgressGb: 0.12, privateDnsZoneMonthly: 0.5, privateDnsQueriesPerMillion: 0.4,
  keyVaultOperationsPer10k: 0.03,
};
const claims = {
  iss: 'https://token.actions.githubusercontent.com', aud: 'api://AzureADTokenExchange',
  sub: 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss',
  repository_id: '1408821667', repository_owner_id: '25802147',
};
const ids = {
  application: '11111111-1111-1111-1111-111111111111',
  client: '22222222-2222-2222-2222-222222222222',
  servicePrincipal: '33333333-3333-3333-3333-333333333333',
  federation: '44444444-4444-4444-4444-444444444444',
  environment: 100, environmentPolicy: 200,
};
const begin = state => transitionIdentityEnvelope(state, 'begin', { now, pricing });
function completeStep(state, step) {
  state = transitionIdentityEnvelope(state, 'reserve', { step, now });
  if (Object.hasOwn(ids, step)) state = transitionIdentityEnvelope(state, 'capture', {
    step, id: ids[step], clientId: ids.client,
  });
  if (step === 'seedConfirmation') state = transitionIdentityEnvelope(state, 'record-key-fingerprint', { fingerprint });
  return transitionIdentityEnvelope(state, 'verify', { step, claims, seedConfirmed: true });
}
function bootstrap() {
  let state = begin(newIdentityEnvelope(head));
  for (const step of ['resourceGroup', 'application', 'servicePrincipal', 'environment', 'environmentPolicy', 'federation', 'owner']) {
    state = completeStep(state, step);
  }
  return state;
}
function clean(state) {
  state = transitionIdentityEnvelope(state, 'cleanup');
  for (const step of ['resourceGroup', 'owner', 'federation', 'application', 'servicePrincipal', 'environment']) {
    state = transitionIdentityEnvelope(state, 'reserve-delete', { step });
    state = transitionIdentityEnvelope(state, 'acknowledge-delete', { step, accepted: true });
    state = transitionIdentityEnvelope(state, 'verify-absent', { step, absent: true });
  }
  return state;
}
function inventory(state) {
  const plan = bootstrapPlan(state);
  const app = { id: ids.application, appId: ids.client, ...plan.application.body };
  const sp = { id: ids.servicePrincipal, ...plan.servicePrincipal.body, passwordCredentials: [], keyCredentials: [] };
  return {
    applications: [app], servicePrincipals: [sp],
    assignments: [{ id: plan.owner.url.split('?')[0].replace('https://management.azure.com', ''),
      scope, ...plan.owner.body.properties, condition: null }],
    federatedCredentials: [{ id: ids.federation, ...plan.federation.body }],
    resourceGroup: { id: scope, ...plan.resourceGroup.body },
    environment: {
      id: ids.environment, name: 'spike-vmss', protection_rules: [{ type: 'branch_policy' }],
      deployment_branch_policy: plan.environment.body.deployment_branch_policy,
      branchPolicies: [{ id: ids.environmentPolicy, name: 'main', type: 'branch' }],
    },
  };
}

test('GA environment trust has one exact immutable subject, no flexible/reusable machinery', () => {
  const state = begin(newIdentityEnvelope(head));
  assert.deepEqual(standardCredential(state), {
    name: identityNames(state.runId, 1).ficName, issuer: claims.iss,
    audiences: [claims.aud], subject: claims.sub,
  });
  assertSanitizedEnvironmentClaims(claims);
  for (const replacement of [
    { sub: claims.sub.replace('spike-vmss', 'platform-prod') },
    { sub: claims.sub.replace('@25802147', '') }, { repository_id: '999' },
    { aud: [claims.aud] }, { token: 'not-accepted' },
  ]) assert.throws(() => assertSanitizedEnvironmentClaims({ ...claims, ...replacement }));
  assert.throws(executeTemporaryIdentity, /disabled/);
});

test('bootstrap is disabled, exact RG Owner only, no production principal or local key access', () => {
  const state = bootstrap();
  const plan = bootstrapPlan(state);
  assert.equal(plan.enabled, false);
  assert.equal(plan.resourceGroup.body.location, 'swedencentral');
  assert.equal(plan.resourceGroup.body.tags['spike-run-ordinal'], '1');
  assert.equal(plan.application.url, 'https://graph.microsoft.com/v1.0/applications');
  assert.deepEqual(plan.application.body.passwordCredentials, []);
  assert.deepEqual(plan.application.body.requiredResourceAccess, []);
  assert.equal(plan.owner.body.properties.principalId, ids.servicePrincipal);
  assert.equal(plan.owner.body.properties.roleDefinitionId.split('/').at(-1), '8e3af657-a8ff-443c-a75c-2fe8c4bcb635');
  assert.equal(plan.owner.url.startsWith(`https://management.azure.com${scope}/`), true);
  assert.deepEqual(plan.environmentPolicy.body, { name: 'main', type: 'branch' });
  assert.deepEqual(plan.environment.body.reviewers, []);
  assert.equal(plan.seed.thisAdapterMayCreateReadOrTransfer, false);
  assert.equal(plan.seed.explicitSeedEvidenceRequired, true);
  assert.equal(plan.seed.appId, 5224898);
});

test('clock precedes first write and survives second full run, which requires ALL cleanup', () => {
  const initial = newIdentityEnvelope(head);
  assert.throws(() => bootstrapPlan(initial));
  let state = begin(initial);
  assert.equal(state.startedUtc, now);
  assert.equal(state.workDeadlineUtc, '2026-10-08T08:00:00.000Z');
  assert.equal(state.hardDeadlineUtc, '2026-10-08T09:00:00.000Z');
  assert.throws(() => begin(state), /cleanup/);
  const firstName = identityNames(state.runId, 1);
  state = clean(state);
  state = transitionIdentityEnvelope(state, 'begin', { now: '2026-10-08T06:00:00.000Z', pricing });
  assert.equal(state.runOrdinal, 2);
  assert.equal(state.startedUtc, now);
  assert.deepEqual(state.reservedUsage, {
    guests: 4, natBytes: 17179869184, egressBytes: 8589934592,
    peIngressBytes: 8589934592, peEgressBytes: 8589934592, dnsQueries: 115280,
  });
  assert.notEqual(identityNames(state.runId, 2).displayName, firstName.displayName);
  assert.notEqual(identityNames(state.runId, 2).assignmentId, firstName.assignmentId);
  assert.notEqual(identityNames(state.runId, 2).ficName, firstName.ficName);
  state = clean(state);
  assert.throws(() => begin(state), /cap/);
});

test('original time and combined cost ceilings fail closed', () => {
  for (const value of [0, -1, 10, Infinity, NaN, '8']) {
    assert.throws(() => transitionIdentityEnvelope(newIdentityEnvelope(head), 'begin', { now, pricing: { ...pricing, b2sHourly: value } }));
  }
  const state = clean(begin(newIdentityEnvelope(head)));
  for (const time of ['2026-10-08T04:00:00.000Z', '2026-10-08T07:15:00.000Z', '2026-10-08T08:00:00.000Z']) {
    assert.throws(() => transitionIdentityEnvelope(state, 'begin', { now: time, pricing: { ...pricing, retrievedUtc: time } }), /window/);
  }
});

test('reservation cannot retry/bypass, ambiguous response can capture metadata during cleanup only', () => {
  let state = begin(newIdentityEnvelope(head));
  assert.throws(() => completeStep(state, 'application'), /bypass/);
  state = completeStep(state, 'resourceGroup');
  state = transitionIdentityEnvelope(state, 'reserve', { step: 'application', now });
  assert.throws(() => transitionIdentityEnvelope(state, 'reserve', { step: 'application', now }), /retry/);
  assert.throws(() => transitionIdentityEnvelope(state, 'verify', { step: 'application' }), /capture/);
  state = transitionIdentityEnvelope(state, 'cleanup');
  state = transitionIdentityEnvelope(state, 'capture', { step: 'application', id: ids.application, clientId: ids.client });
  assert.equal(state.runs[0].ids.application, ids.application);
  assert.throws(() => transitionIdentityEnvelope(state, 'verify', { step: 'application' }), /verification/);
  assert.throws(() => completeStep(state, 'servicePrincipal'), /cleanup/);
});

test('reserved RG create timeout still enters exact-owned cleanup, never another create', () => {
  let state = begin(newIdentityEnvelope(head));
  state = transitionIdentityEnvelope(state, 'reserve', { step: 'resourceGroup', now });
  state = transitionIdentityEnvelope(state, 'cleanup');
  const empty = { applications: [], servicePrincipals: [], assignments: [], federatedCredentials: [], environment: null };
  const plan = bootstrapPlan(begin(newIdentityEnvelope(head)));
  const own = { id: scope, ...plan.resourceGroup.body };
  own.tags['spike-run-id'] = state.runId;
  const cleanup = cleanupPlan(state, { ...empty, resourceGroup: own });
  assert.equal(cleanup.enabled, false);
  assert.equal(cleanup.application, null);
  assert.throws(() => cleanupPlan(state, { ...empty, resourceGroup: { ...own, id: scope.replace('spike-vmss', 'prod') } }), /Unowned/);
});

test('environment subject, canonical GitHub fingerprint and coordinator seed evidence are gates', () => {
  let state = bootstrap();
  state = transitionIdentityEnvelope(state, 'reserve', { step: 'seedConfirmation', now });
  for (const seedConfirmed of [undefined, false, 'true']) {
    assert.throws(() => transitionIdentityEnvelope(state, 'verify', { step: 'seedConfirmation', seedConfirmed }), /seed evidence/);
  }
  assert.throws(() => transitionIdentityEnvelope(state, 'verify', { step: 'seedConfirmation', seedConfirmed: true }), /fingerprint/);
  for (const invalid of ['f'.repeat(64), `SHA256:${fingerprint}`, fingerprint.replace(/=$/, ''), 'f'.repeat(43) + '=']) {
    assert.throws(() => transitionIdentityEnvelope(state, 'record-key-fingerprint', { fingerprint: invalid }), /fingerprint/);
  }
  state = transitionIdentityEnvelope(state, 'record-key-fingerprint', { fingerprint });
  state = transitionIdentityEnvelope(state, 'verify', { step: 'seedConfirmation', seedConfirmed: true });
  state = completeStep(state, 'foundation');
  assert.equal(state.runs[0].steps.foundation, 'verified');
  let noClaims = begin(newIdentityEnvelope(head));
  for (const step of ['resourceGroup', 'application', 'servicePrincipal', 'environment', 'environmentPolicy']) {
    noClaims = completeStep(noClaims, step);
  }
  noClaims = transitionIdentityEnvelope(noClaims, 'reserve', { step: 'federation', now });
  noClaims = transitionIdentityEnvelope(noClaims, 'capture', { step: 'federation', id: ids.federation });
  assert.throws(() => transitionIdentityEnvelope(noClaims, 'verify', { step: 'federation' }), /claims/);
});

test('every bootstrap failure point can close only after ordered absence of all resources', () => {
  for (const failureStep of Object.keys(begin(newIdentityEnvelope(head)).runs[0].steps)) {
    let state = begin(newIdentityEnvelope(head));
    for (const step of Object.keys(state.runs[0].steps)) {
      if (step === failureStep) {
        state = transitionIdentityEnvelope(state, 'reserve', { step, now });
        break;
      }
      state = completeStep(state, step);
    }
    const closed = clean(state);
    assert.equal(closed.runs[0].phase, ['seedConfirmation', 'foundation', 'worker', 'test'].includes(failureStep) ?
      'credential-revocation' : 'closed', failureStep);
    assert.equal(closed.startedUtc, now);
  }
});

test('paid cleanup never waits for owner revocation, but complete cleanup and second run do', () => {
  let state = completeStep(bootstrap(), 'seedConfirmation');
  state = clean(state);
  assert.equal(state.runs[0].phase, 'credential-revocation');
  assert.equal(state.runs[0].credential.revocation, 'pending');
  assert.equal(Object.values(state.runs[0].cleanup).every(value => value === 'absent'), true);
  assert.throws(() => begin(state), /cleanup/);
  assert.throws(() => transitionIdentityEnvelope(state, 'confirm-key-revocation', { fingerprint, revocationConfirmed: false }), /coordinator/);
  assert.throws(() => transitionIdentityEnvelope(state, 'confirm-key-revocation', { fingerprint: Buffer.alloc(32, 2).toString('base64'), revocationConfirmed: true }), /exact/);
  state = transitionIdentityEnvelope(state, 'confirm-key-revocation', { fingerprint, revocationConfirmed: true });
  assert.equal(state.runs[0].phase, 'closed');
  assert.throws(() => begin(state), /second seeded run/);
  const second = transitionIdentityEnvelope(state, 'begin', { now, pricing,
    additionalKeyEvidence: { separatelyApproved: true, keyReady: true, fingerprint: Buffer.alloc(32, 2).toString('base64') } });
  assert.equal(second.runOrdinal, 2);
});

test('owner request interrupted before fingerprint needs explicit no-key-created confirmation', () => {
  let state = transitionIdentityEnvelope(bootstrap(), 'reserve', { step: 'seedConfirmation', now });
  state = clean(state);
  assert.equal(state.runs[0].phase, 'credential-revocation');
  assert.throws(() => transitionIdentityEnvelope(state, 'confirm-key-revocation', { revocationConfirmed: true }), /exact/);
  state = transitionIdentityEnvelope(state, 'confirm-key-revocation', { revocationConfirmed: true, noKeyCreatedConfirmed: true });
  assert.equal(state.runs[0].phase, 'closed');
});

test('cleanup order includes environment, forbids delete retry and false absence', () => {
  let state = transitionIdentityEnvelope(bootstrap(), 'cleanup');
  assert.throws(() => transitionIdentityEnvelope(state, 'reserve-delete', { step: 'application' }), /order/);
  state = transitionIdentityEnvelope(state, 'reserve-delete', { step: 'resourceGroup' });
  assert.throws(() => transitionIdentityEnvelope(state, 'reserve-delete', { step: 'resourceGroup' }), /retry/);
  assert.throws(() => transitionIdentityEnvelope(state, 'verify-absent', { step: 'resourceGroup', absent: false }), /absence/);
  for (const step of ['resourceGroup', 'owner', 'federation', 'application', 'servicePrincipal']) {
    if (step !== 'resourceGroup') state = transitionIdentityEnvelope(state, 'reserve-delete', { step });
    state = transitionIdentityEnvelope(state, 'acknowledge-delete', { step, accepted: true });
    state = transitionIdentityEnvelope(state, 'verify-absent', { step, absent: true });
  }
  assert.throws(() => begin(state), /cleanup/);
  assert.equal(state.runs[0].phase, 'cleanup');
  state = transitionIdentityEnvelope(state, 'reserve-delete', { step: 'environment' });
  state = transitionIdentityEnvelope(state, 'acknowledge-delete', { step: 'environment', accepted: true });
  state = transitionIdentityEnvelope(state, 'verify-absent', { step: 'environment', absent: true });
  assert.equal(state.runs[0].phase, 'closed');
});

test('exact inventory rejects unexpected credentials, grants, FICs, env rules and production IDs', () => {
  const state = bootstrap();
  const good = inventory(state);
  assertOwnedIdentityInventory(state, good);
  const changes = [
    v => v.applications[0].passwordCredentials.push({ keyId: 'unexpected' }),
    v => v.applications[0].requiredResourceAccess.push({ resourceAppId: ids.client }),
    v => v.applications[0].tags.pop(),
    v => v.applications[0].signInAudience = 'AzureADMultipleOrgs',
    v => v.servicePrincipals[0].id = '24ebb9cc-0e3b-4956-a333-5665a060f2c7',
    v => v.servicePrincipals.push(v.servicePrincipals[0]),
    v => v.assignments[0].scope = '/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e',
    v => v.assignments[0].principalId = ids.application,
    v => v.federatedCredentials[0].subject = claims.sub.replace('spike-vmss', 'platform-prod'),
    v => v.federatedCredentials.push(v.federatedCredentials[0]),
    v => v.environment.id++,
    v => v.environment.branchPolicies[0].type = 'tag',
    v => v.environment.branchPolicies[0].name = '*',
    v => v.environment.protection_rules.push({ type: 'required_reviewers' }),
  ];
  for (const change of changes) {
    const bad = structuredClone(good);
    change(bad);
    assert.throws(() => assertOwnedIdentityInventory(state, bad));
  }
  const cleaning = transitionIdentityEnvelope(state, 'cleanup');
  const plan = cleanupPlan(cleaning, good);
  assert.deepEqual(Object.keys(plan), ['enabled', 'resourceGroup', 'owner', 'federation', 'application', 'servicePrincipal', 'environment']);
  assert.equal(plan.application.endsWith(ids.application), true);
  assert.equal(plan.servicePrincipal.endsWith(ids.servicePrincipal), true);
  assert.equal(plan.environment.endsWith('/spike-vmss'), true);
  const absentAfterCascade = { ...good, applications: [], servicePrincipals: [], assignments: [], federatedCredentials: [], resourceGroup: null, environment: null };
  assert.doesNotThrow(() => cleanupPlan(cleaning, absentAfterCascade));
});

test('production identity IDs and duplicate captured IDs cannot enter durable state', () => {
  let state = completeStep(begin(newIdentityEnvelope(head)), 'resourceGroup');
  state = transitionIdentityEnvelope(state, 'reserve', { step: 'application', now });
  for (const id of ['24ebb9cc-0e3b-4956-a333-5665a060f2c7', '4495f30e-3a65-4e94-8d4a-d13dcbe10204', 'not-a-guid']) {
    assert.throws(() => transitionIdentityEnvelope(state, 'capture', { step: 'application', id, clientId: ids.client }));
  }
  assert.throws(() => transitionIdentityEnvelope(state, 'capture', { step: 'application', id: ids.client, clientId: ids.client }), /distinct/);
});

test('envelope rejects widened limits, corrupt clock, extra secret fields and closed-before-absence', () => {
  const state = begin(newIdentityEnvelope(head));
  for (const change of [
    v => v.capUsd = 11, v => v.maxFullRuns = 3, v => v.hardDeadlineUtc = '2026-10-08T10:00:00.000Z',
    v => v.token = 'not-accepted', v => v.runs[0].phase = 'closed',
    v => v.runs[0].steps.foundation = 'verified',
  ]) {
    const bad = structuredClone(state);
    change(bad);
    assert.throws(() => validateIdentityEnvelope(bad));
  }
});

test('durable lock/atomic transitions preserve reservations on restart and never overwrite initial state', () => {
  const directory = mkdtempSync(join(tmpdir(), 'identity81-'));
  const path = join(directory, 'state.json');
  try {
    writeIdentityEnvelope(path, newIdentityEnvelope(head));
    assert.throws(() => writeIdentityEnvelope(path, newIdentityEnvelope(head)), /EEXIST/);
    const state = updateIdentityEnvelope(path, 'begin', { now, pricing });
    updateIdentityEnvelope(path, 'reserve', { step: 'resourceGroup', now });
    assert.throws(() => updateIdentityEnvelope(path, 'reserve', { step: 'resourceGroup', now }), /retry/);
    const resumed = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(resumed.startedUtc, state.startedUtc);
    assert.equal(resumed.runs[0].steps.resourceGroup, 'reserved');
    writeFileSync(`${path}.lock`, '');
    assert.throws(() => updateIdentityEnvelope(path, 'cleanup'), /EEXIST/);
    rmSync(`${path}.lock`);
    updateIdentityEnvelope(path, 'cleanup');
    assert.equal(JSON.parse(readFileSync(path, 'utf8')).runs[0].phase, 'cleanup');
  } finally {
    rmSync(directory, { recursive: true });
  }
});

test('sourced meter quote covers both runs and planned cleanup without invented reserve categories', () => {
  const total = priceOriginalEnvelope(pricing, now);
  assert.ok(total > 4.3 && total < 10);
  assert.equal(Math.round(total * 1e9) / 1e9, 4.306308956);
  assert.throws(() => priceOriginalEnvelope({ ...pricing, b2sHourly: 3 }, now), /fit/);
  assert.throws(() => priceOriginalEnvelope({ ...pricing, natProcessedGb: 0 }, now), /fallback/);
  const missing = { ...pricing };
  delete missing.keyVaultOperationsPer10k;
  assert.throws(() => priceOriginalEnvelope(missing, now), /Complete/);
  assert.throws(() => priceOriginalEnvelope(pricing, '2026-10-10T05:00:00.000Z'), /stale/);
  assert.throws(() => priceOriginalEnvelope({ ...pricing, logsCombinedCeilingUsd: 1 }, now), /Complete/);
  assert.throws(() => priceOriginalEnvelope({ ...pricing, currencyCode: 'EUR' }, now), /reviewed/);
  assert.throws(() => priceOriginalEnvelope({ ...pricing, sourceUrl: 'https://example.invalid' }, now), /reviewed/);
  const corrupt = begin(newIdentityEnvelope(head));
  corrupt.reservedUsage.natBytes = 0;
  assert.throws(() => validateIdentityEnvelope(corrupt), /Cumulative/);
});

test('priced network quantities match the enforced guest quotas before bootstrap downloads', () => {
  const bootstrap = readFileSync(new URL('../guest-bootstrap.sh', import.meta.url), 'utf8');
  const byteQuotas = [...bootstrap.matchAll(/iptables -w 5 -A GHR_SPIKE60_(?:BYTES|INPUT) -m quota --quota (\d+) -j RETURN/g)]
    .map(match => Number(match[1]));
  const dnsLimit = bootstrap.match(/iptables -w 5 -A GHR_SPIKE60_DNS -m limit --limit (\d+)\/second --limit-burst (\d+) -j RETURN/);
  assert.deepEqual(byteQuotas, [2 ** 31, 2 ** 31]);
  assert.deepEqual(dnsLimit?.slice(1).map(Number), [2, 20]);
  const run = begin(newIdentityEnvelope(head));
  assert.equal(run.reservedUsage.natBytes, 2 * 2 * 2 ** 31);
  assert.equal(run.reservedUsage.egressBytes, 2 * 2 ** 31);
  assert.equal(run.reservedUsage.peIngressBytes, 2 * 2 ** 31);
  assert.equal(run.reservedUsage.peEgressBytes, 2 * 2 ** 31);
  assert.equal(run.reservedUsage.dnsQueries, 2 * (2 * 4 * 60 * 60 + 20));
});

test('unpriced paid resource creates remain excluded from the VMSS templates', () => {
  const foundation = readFileSync(new URL('../infra/main.bicep', import.meta.url), 'utf8');
  const worker = readFileSync(new URL('../infra/worker.bicep', import.meta.url), 'utf8');
  assert.match(foundation, /privateDnsZones: 1[\s\S]*?keyVaultSecrets: 1[\s\S]*?privateEndpoints: 1/);
  assert.doesNotMatch(`${foundation}\n${worker}`,
    /Microsoft\.(?:OperationalInsights\/workspaces|ContainerRegistry\/registries|Storage\/storageAccounts|Compute\/galleries|Compute\/snapshots|Network\/privateDnsResolvers)/);
});

test('cheaper second-run quote cannot refund original cost reservation', () => {
  let state = clean(begin(newIdentityEnvelope(head)));
  const reserved = state.reservedCostUsd;
  state = transitionIdentityEnvelope(state, 'begin', {
    now: '2026-10-08T06:00:00.000Z', pricing: { ...pricing, b2sHourly: 0.001 },
  });
  assert.equal(state.reservedCostUsd, reserved);
  state.reservedCostUsd = 1;
  assert.throws(() => validateIdentityEnvelope(state), /refunded/);
});
