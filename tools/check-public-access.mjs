#!/usr/bin/env node
// Asserts that no PaaS resource in the platform resource group has public network access
// enabled and that the only public IPs are attached to the NAT gateway. Dependency-free.
//
//   node tools/check-public-access.mjs --resource-group <rg>   live, read-only `az` queries
//   node tools/check-public-access.mjs --input <file.json>     offline; JSON array of resources
//
// Exit codes: 0 pass, 1 violations found, 2 usage or collection error.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const lower = (value) => String(value ?? '').toLowerCase();
const isDisabled = (value) => lower(value) === 'disabled';

// Types whose properties must be read with `az resource show` before evaluation.
const RULES = {
  'microsoft.storage/storageaccounts': (r) => {
    const p = r.properties ?? {};
    const found = [];
    if (!isDisabled(p.publicNetworkAccess)) found.push('publicNetworkAccess must be Disabled');
    if (p.allowBlobPublicAccess === true) found.push('allowBlobPublicAccess must not be true');
    return found;
  },
  'microsoft.keyvault/vaults': (r) =>
    isDisabled(r.properties?.publicNetworkAccess) ? [] : ['publicNetworkAccess must be Disabled'],
  'microsoft.containerregistry/registries': (r) =>
    isDisabled(r.properties?.publicNetworkAccess) ? [] : ['publicNetworkAccess must be Disabled'],
  'microsoft.app/managedenvironments': (r) => {
    const p = r.properties ?? {};
    const found = [];
    if (!isDisabled(p.publicNetworkAccess)) found.push('publicNetworkAccess must be Disabled');
    if (p.vnetConfiguration?.internal !== true) found.push('vnetConfiguration.internal must be true');
    return found;
  },
};

// Documented exception (docs/observability.md): ingestion and query endpoints stay enabled
// without AMPLS, so the control is local authentication being disabled.
const WORKSPACE = 'microsoft.operationalinsights/workspaces';
const PUBLIC_IP = 'microsoft.network/publicipaddresses';
const PUBLIC_IP_PREFIX = 'microsoft.network/publicipprefixes';

// Types known to expose no public endpoint of their own.
const NO_ENDPOINT = new Set([
  'microsoft.app/jobs',
  'microsoft.managedidentity/userassignedidentities',
  'microsoft.network/natgateways',
  'microsoft.network/networkinterfaces',
  'microsoft.network/networksecuritygroups',
  'microsoft.network/privatednszones',
  'microsoft.network/privatednszones/virtualnetworklinks',
  'microsoft.network/privateendpoints',
  'microsoft.network/virtualnetworks',
]);

export const DETAIL_TYPES = new Set([...Object.keys(RULES), WORKSPACE, PUBLIC_IP, PUBLIC_IP_PREFIX]);

export function evaluate(resources) {
  const violations = [];
  const warnings = [];
  const notes = [];
  if (!Array.isArray(resources) || resources.length === 0) {
    return { violations: ['No resources found; refusing to pass on an empty inventory.'], warnings, notes };
  }

  const natPublicIps = [];
  for (const resource of resources) {
    const type = lower(resource.type);
    const label = `${resource.type} ${resource.name}`;
    if (resource.properties === undefined && DETAIL_TYPES.has(type)) {
      violations.push(`${label}: properties are missing, cannot verify.`);
    } else if (RULES[type]) {
      for (const finding of RULES[type](resource)) violations.push(`${label}: ${finding}.`);
    } else if (type === WORKSPACE) {
      if (resource.properties?.features?.disableLocalAuth !== true) {
        violations.push(`${label}: disableLocalAuth must be true for the documented public-endpoint exception.`);
      }
      notes.push(`${label}: public ingestion/query endpoints allowed by the documented exception (local auth disabled).`);
    } else if (type === PUBLIC_IP) {
      const p = resource.properties ?? {};
      if (!/\/natgateways\//i.test(p.natGateway?.id ?? '') || p.ipConfiguration) {
        violations.push(`${label}: public IP must be attached only to a NAT gateway.`);
      } else {
        natPublicIps.push(label);
      }
    } else if (type === PUBLIC_IP_PREFIX) {
      violations.push(`${label}: public IP prefixes are not permitted.`);
    } else if (!NO_ENDPOINT.has(type)) {
      warnings.push(`${label}: resource type is not reviewed by this check.`);
    }
  }

  if (natPublicIps.length === 0 && !violations.some((v) => v.includes('public IP'))) {
    violations.push('No NAT gateway public IP found; expected exactly the outbound-only NAT address.');
  } else if (natPublicIps.length > 0) {
    notes.push(`Public IPs (NAT gateway only): ${natPublicIps.join(', ')}.`);
  }
  return { violations, warnings, notes };
}

function az(args) {
  return JSON.parse(
    execFileSync('az', [...args, '--output', 'json'], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      shell: process.platform === 'win32',
    }),
  );
}

export function collect(resourceGroup, run = az) {
  const listed = run(['resource', 'list', '--resource-group', resourceGroup]);
  return listed.map((resource) =>
    DETAIL_TYPES.has(lower(resource.type)) ? run(['resource', 'show', '--ids', resource.id]) : resource,
  );
}

export function main(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) options[argv[i]] = argv[i + 1];
  const { '--resource-group': resourceGroup, '--input': input } = options;
  if (Boolean(resourceGroup) === Boolean(input) || argv.length !== 2) {
    console.error('Usage: check-public-access.mjs (--resource-group <name> | --input <file.json>)');
    return 2;
  }
  let resources;
  try {
    resources = input ? JSON.parse(readFileSync(input, 'utf8')) : collect(resourceGroup);
  } catch (error) {
    console.error(`::error::Could not collect resources: ${error.message}`);
    return 2;
  }
  const { violations, warnings, notes } = evaluate(resources);
  for (const note of notes) console.log(`note: ${note}`);
  for (const warning of warnings) console.log(`::warning::${warning}`);
  for (const violation of violations) console.log(`::error::${violation}`);
  console.log(
    violations.length === 0
      ? `Public access check passed (${resources.length} resources).`
      : `Public access check FAILED with ${violations.length} violation(s).`,
  );
  return violations.length === 0 ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
