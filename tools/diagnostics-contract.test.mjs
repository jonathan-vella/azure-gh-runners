import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createDiagnosticSettings } from './diagnostics-contract.mjs';
import {
  parseAvailableCategories,
  runValidation,
  validateLiveConfiguration,
  validateLiveDiagnosticCategories,
} from './validate-diagnostics.mjs';

const diagnosticsConfig = JSON.parse(
  readFileSync(fileURLToPath(new URL('../infra/diagnostics-config.json', import.meta.url)), 'utf8'),
);
const mainBicep = readFileSync(fileURLToPath(new URL('../infra/main.bicep', import.meta.url)), 'utf8');
const subscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e';
const resourceGroup = 'rg-ghrunners-prod-swc';

function makeOutputs(overrides = {}) {
  return {
    acaNetworkSecurityGroupResourceId: {
      value: `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/networkSecurityGroups/nsg-ghrunners-aca-prod-swc-abc12`,
    },
    virtualNetworkResourceId: {
      value: `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/virtualNetworks/vnet-ghrunners-prod-swc-ghi56`,
    },
    natGatewayPublicIpResourceId: {
      value: `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/publicIPAddresses/pip-ghrunners-prod-swc-jkl78`,
    },
    containerAppsEnvironmentResourceId: {
      value: `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.App/managedEnvironments/cae-ghrunners-prod-swc-mno12`,
    },
    ...overrides,
  };
}

function liveCategoriesForResource(resourceId) {
  if (resourceId.includes('/managedEnvironments/')) {
    return [
      { name: 'ContainerAppConsoleLogs', properties: { categoryType: 'Logs' } },
      { name: 'ContainerAppSystemLogs', properties: { categoryType: 'Logs' } },
      { name: 'AllMetrics', properties: { categoryType: 'Metrics' } },
    ];
  }

  if (resourceId.includes('/networkSecurityGroups/')) {
    return [
      { name: 'NetworkSecurityGroupEvent', properties: { categoryType: 'Logs' } },
      { name: 'NetworkSecurityGroupFlowEvent', properties: { categoryType: 'Logs' } },
      { name: 'NetworkSecurityGroupRuleCounter', properties: { categoryType: 'Logs' } },
    ];
  }

  if (resourceId.includes('/virtualNetworks/')) {
    return {
      value: [
        { name: 'VMProtectionAlerts', properties: { categoryType: 'Logs' } },
        { name: 'AllMetrics', properties: { categoryType: 'Metrics' } },
      ],
    };
  }

  return [
    { name: 'DDoSMitigationFlowLogs', properties: { categoryType: 'Logs' } },
    { name: 'DDoSMitigationReports', properties: { categoryType: 'Logs' } },
    { name: 'DDoSProtectionNotifications', properties: { categoryType: 'Logs' } },
    { name: 'AllMetrics', properties: { categoryType: 'Metrics' } },
  ];
}

test('accepts only the diagnostic categories wired into the deployment configuration', () => {
  assert.deepEqual(Object.keys(diagnosticsConfig).sort(), [
    'containerAppsEnvironment',
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

  assert.deepEqual(diagnosticsConfig.containerAppsEnvironment.logCategories, [
    'ContainerAppConsoleLogs',
    'ContainerAppSystemLogs',
  ]);
  assert.deepEqual(diagnosticsConfig.containerAppsEnvironment.metricCategories, ['AllMetrics']);
});

test('ACA environment uses an internal workload-profiles subnet and Azure Monitor logging', () => {
  assert.match(mainBicep, /param enableDiagnostics bool = false/);
  assert.match(mainBicep, /'br\/public:avm\/res\/app\/managed-environment:0\.16\.0'/);
  assert.match(mainBicep, /name: 'cae-ghrunners-prod-swc-\$\{uniqueSuffix\}'/);
  assert.match(mainBicep, /internal: true/);
  assert.match(mainBicep, /publicNetworkAccess: 'Disabled'/);
  assert.match(mainBicep, /infrastructureSubnetResourceId: network\.outputs\.acaSubnetResourceId/);
  assert.match(mainBicep, /workloadProfileType: 'Consumption'/);
  assert.match(mainBicep, /destination: 'azure-monitor'/);
  assert.match(
    mainBicep,
    /output containerAppsEnvironmentResourceId string = containerAppsEnvironment\.outputs\.resourceId/,
  );
  assert.match(mainBicep, /module containerAppsEnvironmentDiagnostics[^]*?if \(enableDiagnostics\)/);
  assert.match(mainBicep, /targetResourceId: containerAppsEnvironment\.outputs\.resourceId/);
  assert.match(mainBicep, /workspaceResourceId: observability\.outputs\.workspaceResourceId/);
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

test('checks requested categories against live Azure category results', () => {
  assert.deepEqual(
    parseAvailableCategories([
      { name: 'AuditEvent', properties: { categoryType: 'Logs' } },
      { category: 'AllMetrics', categoryType: 'Metrics' },
    ]),
    {
      logs: ['AuditEvent'],
      metrics: ['AllMetrics'],
    },
  );

  assert.deepEqual(
    validateLiveDiagnosticCategories(
      {
        supportedLogCategories: ['AuditEvent'],
        supportedMetricCategories: ['AllMetrics'],
        logCategories: ['AuditEvent'],
        metricCategories: ['AllMetrics'],
      },
      [
        { name: 'AuditEvent', properties: { categoryType: 'Logs' } },
        { category: 'AllMetrics', categoryType: 'Metrics' },
      ],
    ),
    {
      logCategories: ['AuditEvent'],
      enableAllMetrics: true,
    },
  );
});

test('live preflight rejects an unavailable ACA environment category', () => {
  const queriedResourceIds = [];

  assert.throws(
    () =>
      validateLiveConfiguration(makeOutputs(), {
        executor: (_file, args) => {
          const resourceId = args[args.indexOf('--resource') + 1];
          queriedResourceIds.push(resourceId);
          const categories = liveCategoriesForResource(resourceId);
          if (resourceId.includes('/managedEnvironments/')) {
            return JSON.stringify(
              categories.filter(({ name }) => name !== 'ContainerAppSystemLogs'),
            );
          }
          return JSON.stringify(categories);
        },
        platform: 'linux',
        subscriptionId,
        resourceGroup,
      }),
    /Unsupported log categories: ContainerAppSystemLogs/,
  );

  assert.ok(queriedResourceIds.some((resourceId) => resourceId.includes('/managedEnvironments/')));
});

test('live preflight queries every exact resource ID with explicit subscription and bounded execution', () => {
  const calls = [];
  validateLiveConfiguration(makeOutputs(), {
    executor: (file, args, options) => {
      calls.push({ file, args, options });
      const resourceId = args[args.indexOf('--resource') + 1];
      return JSON.stringify(liveCategoriesForResource(resourceId));
    },
    platform: 'linux',
    subscriptionId,
    resourceGroup,
  });

  assert.equal(calls.length, 4);
  for (const { file, args, options } of calls) {
    assert.equal(file, 'az');
    assert.deepEqual(args.slice(0, 5), [
      'monitor',
      'diagnostic-settings',
      'categories',
      'list',
      '--resource',
    ]);
    assert.equal(args[args.indexOf('--subscription') + 1], subscriptionId);
    assert.deepEqual(args.slice(-3), ['--output', 'json', '--only-show-errors']);
    assert.equal(options.timeout, 30_000);
    assert.equal(options.maxBuffer, 1024 * 1024);
    assert.deepEqual(options.stdio, ['ignore', 'pipe', 'pipe']);
  }
});

test('uses a quoted Azure CLI command with the same bounds on Windows', () => {
  let call;
  validateLiveConfiguration(makeOutputs(), {
    executor: (file, args, options) => {
      call = { file, args, options };
      const command = args.at(-1);
      const resourceId = command.match(/--resource" "([^"]+)"/)?.[1];
      return JSON.stringify(liveCategoriesForResource(resourceId));
    },
    platform: 'win32',
    comSpec: 'cmd.exe',
    subscriptionId,
    resourceGroup,
  });

  assert.equal(call.file, 'cmd.exe');
  assert.equal(call.args[0], '/d');
  assert.equal(call.args[1], '/s');
  assert.match(call.args[3], /--subscription" "b47d2942-f5ad-4d3c-b28e-c23e4f83d97e"/);
  assert.equal(call.options.timeout, 30_000);
  assert.equal(call.options.maxBuffer, 1024 * 1024);
});

test('rejects resource IDs outside the approved subscription, resource group, type, or exact resource path', () => {
  const invalidIds = [
    `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${resourceGroup}/providers/Microsoft.Network/networkSecurityGroups/nsg-ghrunners-aca-prod-swc-abc12`,
    `/subscriptions/${subscriptionId}/resourceGroups/other-rg/providers/Microsoft.Network/networkSecurityGroups/nsg-ghrunners-aca-prod-swc-abc12`,
    `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/virtualNetworks/nsg-ghrunners-aca-prod-swc-abc12`,
    `/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/networkSecurityGroups/nsg-ghrunners-aca-prod-swc-abc12/subnets/child`,
  ];

  for (const invalidId of invalidIds) {
    let queryCount = 0;
    assert.throws(
      () =>
        validateLiveConfiguration(
          makeOutputs({
            acaNetworkSecurityGroupResourceId: { value: invalidId },
          }),
          {
            executor: () => {
              queryCount += 1;
              return '[]';
            },
            subscriptionId,
            resourceGroup,
          },
        ),
      /outside the approved resource scope or name contract/,
    );
    assert.equal(queryCount, 0);
  }
});

test('rejects repeated network resource IDs before querying Azure', () => {
  let queryCount = 0;
  const outputs = makeOutputs();
  outputs.virtualNetworkResourceId = outputs.acaNetworkSecurityGroupResourceId;

  assert.throws(
    () =>
      validateLiveConfiguration(outputs, {
        executor: () => {
          queryCount += 1;
          return '[]';
        },
        subscriptionId,
        resourceGroup,
      }),
    /distinct IDs/,
  );
  assert.equal(queryCount, 0);
});

test('sanitizes Azure CLI failures and rejects malformed or empty category responses', () => {
  for (const executor of [
    () => {
      throw new Error('sensitive-token-value');
    },
    () => '{not-json',
    () => '[]',
  ]) {
    assert.throws(
      () =>
        validateLiveConfiguration(makeOutputs(), {
          executor,
          platform: 'linux',
          subscriptionId,
          resourceGroup,
        }),
      (error) => {
        assert.match(error.message, /Live diagnostic category validation failed/);
        assert.doesNotMatch(error.message, /sensitive-token-value|not-json/);
        return true;
      },
    );
  }
});

test('fails the live gate when any configured category is unavailable', () => {
  assert.throws(
    () =>
      validateLiveConfiguration(makeOutputs(), {
        executor: (_file, args) => {
          const resourceId = args[args.indexOf('--resource') + 1];
          const categories = liveCategoriesForResource(resourceId);
          if (resourceId.includes('/networkSecurityGroups/')) {
            return JSON.stringify(categories.slice(0, 2));
          }
          return JSON.stringify(categories);
        },
        platform: 'linux',
        subscriptionId,
        resourceGroup,
      }),
    /Unsupported log categories: NetworkSecurityGroupRuleCounter/,
  );
});

test('returns a failing CLI exit code when live categories do not support the contract', () => {
  let errorOutput = '';
  const exitCode = runValidation(['--live', 'unused-output.json'], {
    loadOutputs: () => makeOutputs(),
    liveValidator: (outputs) =>
      validateLiveConfiguration(outputs, {
        executor: (_file, args) => {
          const resourceId = args[args.indexOf('--resource') + 1];
          const categories = liveCategoriesForResource(resourceId);
          if (resourceId.includes('/networkSecurityGroups/')) {
            return JSON.stringify(categories.slice(0, 2));
          }
          return JSON.stringify(categories);
        },
        platform: 'linux',
        subscriptionId,
        resourceGroup,
      }),
    writeOutput: () => {},
    writeError: (message) => {
      errorOutput = message;
    },
  });

  assert.equal(exitCode, 1);
  assert.match(errorOutput, /Unsupported log categories: NetworkSecurityGroupRuleCounter/);
});

test('rejects a requested category missing from the live resource', () => {
  assert.throws(
    () =>
      validateLiveDiagnosticCategories(
        {
          supportedLogCategories: ['AuditEvent'],
          supportedMetricCategories: ['AllMetrics'],
          logCategories: ['AuditEvent'],
          metricCategories: ['AllMetrics'],
        },
        [{ name: 'AuditEvent', properties: { categoryType: 'Logs' } }],
      ),
    /Unsupported metric categories: AllMetrics/,
  );
});
