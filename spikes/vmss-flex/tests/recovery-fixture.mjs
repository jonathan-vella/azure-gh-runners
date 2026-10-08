import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// In-memory test authority only: neither a durable store nor a recovery host.
export function mockCoordination(path) {
  let canonical = JSON.parse(readFileSync(path, 'utf8'));
  let held = false;
  const session = {
    read: () => structuredClone(canonical),
    compareAndSwap(expected, next) {
      try { assert.deepEqual(expected, canonical); } catch { return false; }
      assert.equal(next.revision, expected.revision + 1);
      canonical = structuredClone(next);
      return true;
    },
  };
  return {
    session,
    async withExclusive(runId, work) {
      assert.equal(runId, canonical.runId);
      if (held) throw new Error('EEXIST: shared operation already held; no lease takeover.');
      held = true;
      try { return await work(session); }
      finally { held = false; }
    },
  };
}

export function receipt(state, kind, step, provider = 'arm', status = 'succeeded', operationUrl = null) {
  const intent = state.intents.find(item => item.ordinal === state.runOrdinal && item.kind === kind && item.step === step);
  return { operationId: intent.operationId, provider, state: status, operationUrl };
}
