import { readFileSync } from 'node:fs';
import {
  newIdentityEnvelope, writeIdentityEnvelope, validateIdentityEnvelope, inspectIdentityLock,
} from './temporary-identity.mjs';
import { bootstrapTemporaryIdentity, cleanupTemporaryIdentity } from './identity-adapter.mjs';

const [action, path, value] = process.argv.slice(2);
if (!path) throw new Error('Usage: identity-cli.mjs prepare|inspect|inspect-lock|bootstrap|cleanup <external-state-or-lock-path> [head|nonsecret-approval-path]');
if (action === 'prepare') {
  writeIdentityEnvelope(path, newIdentityEnvelope(value));
  console.log('Offline envelope prepared. No clock or cloud call started.');
} else if (action === 'inspect') {
  const state = JSON.parse(readFileSync(path, 'utf8'));
  validateIdentityEnvelope(state);
  console.log(JSON.stringify(state, null, 2));
} else if (action === 'inspect-lock') {
  console.log(JSON.stringify(inspectIdentityLock(path), null, 2));
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
  throw new Error('Canonical seed evidence writer unavailable; local snapshots cannot authorize writes.');
} else if (action === 'confirm-revocation') {
  throw new Error('Canonical revocation evidence writer unavailable; inspect state read-only.');
} else if (action === 'reserve-foundation') {
  throw new Error('Canonical foundation fencing unavailable; workflow artifacts/base64 are not CAS.');
} else {
  throw new Error('Unknown temporary identity action.');
}
