import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createDiagnosticSettings } from './diagnostics-contract.mjs';

const networkConfig = JSON.parse(
  readFileSync(new URL('../infra/network-config.json', import.meta.url), 'utf8'),
);
const diagnosticsConfig = JSON.parse(
  readFileSync(new URL('../infra/diagnostics-config.json', import.meta.url), 'utf8'),
);

const resourceProfiles = [
  {
    outputName: 'acaNetworkSecurityGroupResourceId',
    profileName: 'networkSecurityGroup',
    resourceType: 'Microsoft.Network/networkSecurityGroups',
    namePrefix: 'nsg-ghrunners-aca-prod-swc-',
  },
  {
    outputName: 'acrAgentsNetworkSecurityGroupResourceId',
    profileName: 'networkSecurityGroup',
    resourceType: 'Microsoft.Network/networkSecurityGroups',
    namePrefix: 'nsg-ghrunners-acr-agents-prod-swc-',
  },
  {
    outputName: 'virtualNetworkResourceId',
    profileName: 'virtualNetwork',
    resourceType: 'Microsoft.Network/virtualNetworks',
    namePrefix: 'vnet-ghrunners-prod-swc-',
  },
  {
    outputName: 'natGatewayPublicIpResourceId',
    profileName: 'publicIpAddress',
    resourceType: 'Microsoft.Network/publicIPAddresses',
    namePrefix: 'pip-ghrunners-prod-swc-',
  },
];

const azureCliOptions = {
  encoding: 'utf8',
  maxBuffer: 1024 * 1024,
  stdio: ['ignore', 'pipe', 'pipe'],
  timeout: 30_000,
  windowsHide: true,
};

export function parseAvailableCategories(response) {
  const categories = Array.isArray(response) ? response : response?.value;
  if (!Array.isArray(categories) || categories.length === 0) {
    throw new TypeError('Azure CLI must return a non-empty category array or an object with a non-empty value array.');
  }

  const logs = [];
  const metrics = [];
  for (const category of categories) {
    const name = category?.category ?? category?.name;
    const type = category?.categoryType ?? category?.properties?.categoryType;
    if (typeof name !== 'string' || name.trim() === '') {
      throw new TypeError('Azure CLI returned a diagnostic category without a name.');
    }

    if (type === 'Metrics') {
      metrics.push(name);
    } else if (type === 'Logs') {
      logs.push(name);
    } else {
      throw new TypeError('Azure CLI returned a diagnostic category with an unsupported category type.');
    }
  }

  return { logs, metrics };
}

export function validateLiveDiagnosticCategories(profile, availableCategories) {
  createDiagnosticSettings(profile);
  return validateAgainstLiveCategories(profile, parseAvailableCategories(availableCategories));
}

function validateAgainstLiveCategories(profile, available) {
  return createDiagnosticSettings({
    ...profile,
    supportedLogCategories: available.logs,
    supportedMetricCategories: available.metrics,
  });
}

function validateStaticConfiguration() {
  for (const profile of Object.values(diagnosticsConfig)) {
    createDiagnosticSettings(profile);
  }
}

export function runValidation(args, {
  loadOutputs = (outputsPath) => JSON.parse(readFileSync(resolve(outputsPath), 'utf8')),
  liveValidator = validateLiveConfiguration,
  writeOutput = console.log,
  writeError = console.error,
} = {}) {
  try {
    validateStaticConfiguration();
    if (args.length === 0) {
      writeOutput('Static diagnostic category configuration is valid.');
      return 0;
    }

    if (args.length !== 2 || args[0] !== '--live') {
      throw new Error('Usage: node tools/validate-diagnostics.mjs [--live <deployment-outputs.json>]');
    }

    liveValidator(loadOutputs(args[1]));
    writeOutput('Live diagnostic categories verified for all monitored network resources.');
    return 0;
  } catch (error) {
    writeError(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

function requireResourceId(outputs, resource, { subscriptionId, resourceGroup }) {
  const resourceId = outputs?.[resource.outputName]?.value;
  if (typeof resourceId !== 'string') {
    throw new Error(`Deployment output ${resource.outputName} must contain a resource ID.`);
  }

  const escapedSubscriptionId = subscriptionId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const escapedResourceGroup = resourceGroup.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const escapedResourceType = resource.resourceType.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const escapedNamePrefix = resource.namePrefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const resourceIdPattern = new RegExp(
    `^/subscriptions/${escapedSubscriptionId}/resourceGroups/${escapedResourceGroup}/providers/${escapedResourceType}/${escapedNamePrefix}[a-z0-9]{5}$`,
    'i',
  );
  if (!resourceIdPattern.test(resourceId)) {
    throw new Error(`Deployment output ${resource.outputName} is outside the approved resource scope or name contract.`);
  }

  return resourceId;
}

function invokeAzureCli(args, executor, platform, comSpec) {
  if (platform !== 'win32') {
    return executor('az', args, azureCliOptions);
  }

  const command = `az ${args.map((argument) => `"${argument}"`).join(' ')}`;
  return executor(comSpec, ['/d', '/s', '/c', command], azureCliOptions);
}

function queryResourceCategories(resource, resourceId, { executor, platform, comSpec, subscriptionId }) {
  const args = [
    'monitor',
    'diagnostic-settings',
    'categories',
    'list',
    '--resource',
    resourceId,
    '--subscription',
    subscriptionId,
    '--output',
    'json',
    '--only-show-errors',
  ];

  try {
    const output = invokeAzureCli(args, executor, platform, comSpec);
    try {
      return JSON.parse(output);
    } catch {
      throw new Error('Azure CLI returned invalid JSON.');
    }
  } catch {
    throw new Error(`Live diagnostic category validation failed for ${resource.outputName}. Check Azure CLI access and category support.`);
  }
}

export function validateLiveConfiguration(outputs, {
  executor = execFileSync,
  platform = process.platform,
  comSpec = process.env.ComSpec ?? 'cmd.exe',
  subscriptionId = networkConfig.subscriptionId,
  resourceGroup = networkConfig.resourceGroup,
} = {}) {
  const rawResourceIds = resourceProfiles.map((resource) => {
    const resourceId = outputs?.[resource.outputName]?.value;
    if (typeof resourceId !== 'string') {
      throw new Error(`Deployment output ${resource.outputName} must contain a resource ID.`);
    }
    return resourceId;
  });
  const uniqueResourceIds = new Set(rawResourceIds.map((resourceId) => resourceId.toLowerCase()));
  if (uniqueResourceIds.size !== rawResourceIds.length) {
    throw new Error('Deployment outputs must contain distinct IDs for every monitored network resource.');
  }

  const resolvedResourceIds = resourceProfiles.map((resource) => ({
    resource,
    resourceId: requireResourceId(outputs, resource, { subscriptionId, resourceGroup }),
  }));

  for (const { resource, resourceId } of resolvedResourceIds) {
    const response = queryResourceCategories(resource, resourceId, {
      executor,
      platform,
      comSpec,
      subscriptionId,
    });
    let availableCategories;
    try {
      availableCategories = parseAvailableCategories(response);
    } catch {
      throw new Error(`Live diagnostic category validation failed for ${resource.outputName}. Azure CLI returned no usable categories.`);
    }
    validateAgainstLiveCategories(diagnosticsConfig[resource.profileName], availableCategories);
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = runValidation(process.argv.slice(2));
}
