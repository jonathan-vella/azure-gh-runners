import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { provisionReservedBootstrap, cleanupTemporaryIdentity } from '../../identity-adapter.mjs';
import { scope, tenant } from '../../temporary-identity.mjs';

const [path, boundary] = process.argv.slice(2);
const canonicalPath = `${path}.canonical`;
function stop(stage) {
  process.send({ stage });
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
}
const coordination = {
  async withExclusive(runId, work) {
    return work({
      read: () => JSON.parse(readFileSync(canonicalPath, 'utf8')),
      compareAndSwap(expected, next) {
        assert.deepEqual(expected, JSON.parse(readFileSync(canonicalPath, 'utf8')));
        assert.equal(runId, next.runId);
        writeFileSync(canonicalPath, JSON.stringify(next));
        if (boundary === 'rename' && next.intents.some(intent => intent.receipt !== null)) stop('rename');
        return true;
      },
    });
  },
};
const invoke = async (operation, payload = {}) => {
  if (operation === 'account') return { id: scope.split('/')[2], tenantId: tenant, name: 'shared', user: { type: 'user' } };
  if (operation === 'request') {
    if (boundary === 'reserve') stop('reserve');
    writeFileSync(`${path}.sent`, JSON.stringify({ operationId: payload.operationId, method: payload.method }));
    if (boundary === 'send') stop('send');
    return { value: {}, receipt: { operationId: payload.operationId, provider: 'arm', state: 'succeeded', operationUrl: null } };
  }
  if (operation === 'group-read') {
    if (boundary === 'receipt') stop('receipt');
  }
  if (operation === 'group-exists') return false;
  throw new Error('Unexpected crash fixture continuation.');
};
const options = { coordination, now: () => '2026-10-08T05:00:00.000Z' };
if (boundary === 'cleanup-lock') {
  const account = invoke;
  await cleanupTemporaryIdentity(path, async (operation, payload) => {
    if (operation === 'account') stop('cleanup-lock');
    return account(operation, payload);
  }, options);
} else {
  await provisionReservedBootstrap(path, invoke, options);
}
