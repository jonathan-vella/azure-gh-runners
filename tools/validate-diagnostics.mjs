import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createDiagnosticSettings } from './diagnostics-contract.mjs';

const diagnosticsConfig = JSON.parse(
  readFileSync(new URL('../infra/diagnostics-config.json', import.meta.url), 'utf8'),
);

const resourceProfiles = [
  {
    outputName: 'acaNetworkSecurityGroupResourceId',
    profileName: 'networkSecurityGroup',
    resourceType: 'Microsoft.Network/networkSecurityGroups',
  },
  {
    outputName: 'acrAgentsNetworkSecurityGroupResourceId',
    profileName: 'networkSecurityGroup',
    resourceType: 'Microsoft.Network/networkSecurityGroups',
  },
  {
    outputName: 'virtualNetworkResourceId',
    profileName: 'virtualNetwork',
    resourceType: 'Microsoft.Network/virtualNetworks',
  },
  {
    outputName: 'natGatewayPublicIpResourceId',
    profileName: 'publicIpAddress',
    resourceType: 'Microsoft.Network/publicIPAddresses',
  },
];

export function parseAvailableCategories(categories) {
  if (!Array.isArray(categories)) {
    throw new TypeError('Azure CLI must return a JSON array of diagnostic categories.');
  }

  const logs = [];
  const metrics = [];
  for (const category of categories) {
    const name = category?.category ?? category?.name;
    const type = category?.categoryType ?? category?.properties?.categoryType;
    if (typeof name !== 'string' || name.trim() === '') {
      throw new TypeError('Azure CLI returned a diagnostic category without a name.');
    }

    if (typeof type === 'string' && type.toLowerCase().includes('metric')) {
      metrics.push(name);
    } else if (typeof type === 'string' && type.toLowerCase().includes('log')) {
      logs.push(name);
    } else if (name === 'AllMetrics') {
      metrics.push(name);
    } else {
      throw new TypeError(`Azure CLI returned an unclassified diagnostic category: ${name}`);
    }
  }

  return { logs, metrics };
}

export function validateLiveDiagnosticCategories(profile, availableCategories) {
  createDiagnosticSettings(profile);
  const available = parseAvailableCategories(availableCategories);
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

function requireResourceId(outputs, { outputName, resourceType }) {
  const resourceId = outputs?.[outputName]?.value;
  if (
    typeof resourceId !== 'string'
    || !/^\/[A-Za-z0-9._:/-]+$/.test(resourceId)
    || !resourceId.toLowerCase().includes(`/providers/${resourceType.toLowerCase()}/`)
  ) {
    throw new Error(`Deployment output ${outputName} must contain a ${resourceType} resource ID.`);
  }

  return resourceId;
}

function queryResourceCategories(resourceId) {
  const args = [
    'monitor',
    'diagnostic-settings',
    'categories',
    'list',
    '--resource',
    resourceId,
    '--output',
    'json',
  ];
  const output = process.platform === 'win32'
    ? execFileSync(
      process.env.ComSpec ?? 'cmd.exe',
      ['/d', '/s', '/c', `az ${args.join(' ')}`],
      { encoding: 'utf8' },
    )
    : execFileSync('az', args, { encoding: 'utf8' });

  return JSON.parse(output);
}

function validateLiveConfiguration(outputsPath) {
  const outputs = JSON.parse(readFileSync(resolve(outputsPath), 'utf8'));
  for (const resource of resourceProfiles) {
    const resourceId = requireResourceId(outputs, resource);
    const categories = queryResourceCategories(resourceId);
    validateLiveDiagnosticCategories(diagnosticsConfig[resource.profileName], categories);
    console.log(`Live diagnostic categories verified for ${resource.outputName}.`);
  }
}

function main(args) {
  validateStaticConfiguration();
  if (args.length === 0) {
    console.log('Static diagnostic category configuration is valid.');
    return;
  }

  if (args.length !== 2 || args[0] !== '--live') {
    throw new Error('Usage: node tools/validate-diagnostics.mjs [--live <deployment-outputs.json>]');
  }

  validateLiveConfiguration(args[1]);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
