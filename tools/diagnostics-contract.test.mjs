import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createDiagnosticSettings } from './diagnostics-contract.mjs';

const diagnosticsConfig = JSON.parse(
  readFileSync(fileURLToPath(new URL('../infra/diagnostics-config.json', import.meta.url)), 'utf8'),
);

test('accepts only the diagnostic categories wired into the deployment configuration', () => {
  assert.deepEqual(Object.keys(diagnosticsConfig).sort(), [
    'networkSecurityGroup',
    'publicIpAddress',
    'virtualNetwork',
  ]);

  for (const profile of Object.values(diagnosticsConfig)) {
    assert.deepEqual(
      createDiagnosticSettings(profile),
      {
        logCategories: profile.logCategories,
        enableAllMetrics: profile.metricCategories.includes('AllMetrics'),
      },
    );
  }
});

test('rejects the Standard NAT Gateway flow-log category and non-exportable metrics', () => {
  const standardNatGatewayCapabilities = {
    supportedLogCategories: [],
    supportedMetricCategories: [],
  };

  assert.throws(
    () =>
      createDiagnosticSettings({
        ...standardNatGatewayCapabilities,
        logCategories: ['NatGatewayFlowlogsV1'],
      }),
    /Unsupported log categories: NatGatewayFlowlogsV1/,
  );

  assert.throws(
    () =>
      createDiagnosticSettings({
        ...standardNatGatewayCapabilities,
        metricCategories: ['AllMetrics'],
      }),
    /Unsupported metric categories: AllMetrics/,
  );
});

test('rejects an empty diagnostic setting request', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        supportedLogCategories: [],
        supportedMetricCategories: [],
      }),
    /At least one supported log or metric category must be requested/,
  );
});

test('rejects malformed category lists', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        supportedLogCategories: ['AuditEvent'],
        supportedMetricCategories: ['AllMetrics'],
        logCategories: [''],
      }),
    /Requested log and metric categories must be arrays of non-empty strings/,
  );
});

test('rejects duplicate or unsupported categories', () => {
  assert.throws(
    () =>
      createDiagnosticSettings({
        supportedLogCategories: ['AuditEvent'],
        supportedMetricCategories: [],
        logCategories: ['AuditEvent', 'AuditEvent'],
      }),
    /must not contain duplicates/,
  );

  assert.throws(
    () =>
      createDiagnosticSettings({
        supportedLogCategories: ['AuditEvent'],
        supportedMetricCategories: [],
        logCategories: ['UnknownCategory'],
      }),
    /Unsupported log categories: UnknownCategory/,
  );
});

test('omits AllMetrics when metrics are not requested', () => {
  assert.deepEqual(
    createDiagnosticSettings({
      supportedLogCategories: ['AuditEvent'],
      supportedMetricCategories: ['AllMetrics'],
      logCategories: ['AuditEvent'],
    }),
    {
      logCategories: ['AuditEvent'],
      enableAllMetrics: false,
    },
  );
});
