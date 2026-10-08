import { readFileSync } from 'node:fs';
import {
  newIdentityEnvelope, writeIdentityEnvelope, updateIdentityEnvelope, validateIdentityEnvelope,
} from './temporary-identity.mjs';
import { bootstrapTemporaryIdentity, cleanupTemporaryIdentity } from './identity-adapter.mjs';

const [action, path, value, confirmation] = process.argv.slice(2);
if (!path) throw new Error('Usage: identity-cli.mjs prepare|inspect|bootstrap|cleanup|confirm-seed|confirm-revocation <external-state-path> [head|nonsecret-approval-path|fingerprint] [--coordinator-confirmed]');
if (action === 'prepare') {
  writeIdentityEnvelope(path, newIdentityEnvelope(value));
  console.log('Offline envelope prepared. No clock or cloud call started.');
} else if (action === 'inspect') {
  const state = JSON.parse(readFileSync(path, 'utf8'));
  validateIdentityEnvelope(state);
  console.log(JSON.stringify(state, null, 2));
} else if (action === 'bootstrap') {
  const approval = JSON.parse(readFileSync(value, 'utf8'));
  const keys = Object.keys(approval);
  if (!keys.includes('claims') || !keys.includes('pricing') || !keys.includes('readiness') ||
    keys.some(key => !['claims', 'pricing', 'readiness', 'additionalKeyEvidence'].includes(key))) {
    throw new Error('Only sanitized claims, complete pricing and separately approved additional-key evidence belong in bootstrap approval.');
  }
  console.log(JSON.stringify(await bootstrapTemporaryIdentity(path, undefined, approval)));
} else if (action === 'cleanup') {
  console.log(JSON.stringify(await cleanupTemporaryIdentity(path)));
} else if (action === 'confirm-seed') {
  if (confirmation !== '--coordinator-confirmed') throw new Error('Record only actual approved coordinator seed evidence, never infer it from metadata.');
  updateIdentityEnvelope(path, 'record-key-fingerprint', { fingerprint: value });
  updateIdentityEnvelope(path, 'verify', { step: 'seedConfirmation', seedConfirmed: true });
  console.log('Approved coordinator spike-key seed evidence recorded; no secret read or transfer.');
} else if (action === 'confirm-revocation') {
  if (confirmation !== '--coordinator-confirmed') throw new Error('Record only actual approved coordinator revocation evidence.');
  updateIdentityEnvelope(path, 'confirm-key-revocation', {
    fingerprint: value, noKeyCreatedConfirmed: value === 'no-key-created', revocationConfirmed: true,
  });
  console.log('Exact scoped spike-key revocation evidence recorded.');
} else if (action === 'reserve-foundation') {
  if (value !== '--coordinator-confirmed') throw new Error('Reserve only an explicitly directed reviewed workflow handoff.');
  updateIdentityEnvelope(path, 'reserve', { step: 'foundation', now: new Date().toISOString() });
  console.log('Original full-run foundation handoff consumed; no cloud call or retry authorized.');
} else {
  throw new Error('Unknown temporary identity action.');
}
