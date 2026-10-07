import assert from 'node:assert/strict';
import test from 'node:test';
import { createDiagnosticSettings } from './diagnostics-contract.mjs';

const keyVaultCapabilities = {
  supportedLogCategories: ['AuditEvent'],
  supportedMetricCategories: ['AllMetrics'],
};

test('accepts the service-supported log categories and AllMetrics', () => {
  assert.deepEqual(
    createDiagnosticSettings({
      ...keyVaultCapabilities,
      logCategories: ['AuditEvent'],
      metricCategories: ['AllMetrics'],
    }),
    {
      logCategories: ['AuditEvent'],
      enableAllMetrics: true,
    },
  );
});

test('rejects a log category that the resource does not support', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        ...keyVaultCapabilities,
        logCategories: ['UnknownCategory'],
      }),
    /Unsupported log categories: UnknownCategory/,
  );
});

test('rejects AllMetrics when the resource does not support metrics', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        supportedLogCategories: ['AuditEvent'],
        supportedMetricCategories: [],
        metricCategories: ['AllMetrics'],
      }),
    /Unsupported metric categories: AllMetrics/,
  );
});

test('rejects an empty diagnostic setting request', () => {
  assert.throws(
    () => createDiagnosticSettings({ ...keyVaultCapabilities }),
    /At least one supported log or metric category must be requested/,
  );
});

test('rejects malformed category lists', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        ...keyVaultCapabilities,
        logCategories: [''],
      }),
    /Requested log and metric categories must be arrays of non-empty strings/,
  );
});

test('omits AllMetrics when metrics are not requested', () => {
  assert.deepEqual(
    createDiagnosticSettings({
      ...keyVaultCapabilities,
      logCategories: ['AuditEvent'],
    }),
    {
      logCategories: ['AuditEvent'],
      enableAllMetrics: false,
    },
  );
});
