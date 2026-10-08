const fs = require('node:fs');
const path = require('node:path');

const requiredSubnets = [
  'aca',
  'privateEndpoints',
  'consumerPrivateEndpoints',
];

const requiredDnsZones = [
  'privatelink.blob.core.windows.net',
  'privatelink.file.core.windows.net',
  'privatelink.queue.core.windows.net',
  'privatelink.table.core.windows.net',
  'privatelink.vaultcore.azure.net',
  'privatelink.azurecr.io',
];

const requiredGovernanceTags = {
  application: 'ghrunners',
  environment: 'prod',
  workload: 'gh-runners',
  owner: 'jonathan-vella',
  costcenter: 'platform-engineering',
  'tech-contact': 'jonathan-vella',
  'technical-contact': 'jonathan-vella',
  sla: 'development',
  'backup-policy': 'none',
  'maint-window': 'none',
};

const requiredPlatform = {
  subscriptionId: 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e',
  resourceGroup: 'rg-ghrunners-prod-swc',
  location: 'swedencentral',
};

const acaReservedRanges = [
  '169.254.0.0/16',
  '172.30.0.0/16',
  '172.31.0.0/16',
  '192.0.2.0/24',
  '100.100.0.0/17',
  '100.100.128.0/19',
  '100.100.160.0/19',
  '100.100.192.0/19',
];

const privateIpv4Ranges = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

function parseCidr(value, label) {
  if (typeof value !== 'string') {
    throw new Error(`${label} must be an IPv4 CIDR string.`);
  }

  const parts = value.split('/');
  if (parts.length !== 2 || !/^(0|[1-9]\d*)$/.test(parts[1])) {
    throw new Error(`${label} must be an IPv4 CIDR string.`);
  }

  const octets = parts[0].split('.');
  if (
    octets.length !== 4
    || octets.some((octet) => !/^(0|[1-9]\d{0,2})$/.test(octet) || Number(octet) > 255)
  ) {
    throw new Error(`${label} must be an IPv4 CIDR string.`);
  }

  const prefix = Number(parts[1]);
  if (prefix > 32) {
    throw new Error(`${label} has an invalid prefix length.`);
  }

  const address = octets.reduce((result, octet) => (result << 8n) | BigInt(octet), 0n);
  const hostBits = 32 - prefix;
  const mask = prefix === 0 ? 0n : (0xffffffffn << BigInt(hostBits)) & 0xffffffffn;
  const start = address & mask;

  if (start !== address) {
    throw new Error(`${label} must use a network-aligned address.`);
  }

  return {
    prefix,
    start,
    end: start | ((1n << BigInt(hostBits)) - 1n),
  };
}

function overlaps(left, right) {
  return left.start <= right.end && right.start <= left.end;
}

function containsRange(parent, child) {
  return child.start >= parent.start && child.end <= parent.end;
}

function isValidDnsZoneName(name) {
  return name.length <= 253 && name.split('.').every(
    (label) => label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label),
  );
}

function validateGovernanceTags(tags) {
  if (!tags || typeof tags !== 'object' || Array.isArray(tags)) {
    throw new Error('governanceTags must be an object.');
  }

  for (const [key, expected] of Object.entries(requiredGovernanceTags)) {
    if (tags[key] !== expected) {
      throw new Error(`governanceTags.${key} must be "${expected}".`);
    }
  }

  if (Object.entries(tags).some(([key, value]) => !key || typeof value !== 'string' || !value)) {
    throw new Error('governanceTags may contain only non-empty string values.');
  }
}

function validateNetworkConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('Network configuration must be an object.');
  }

  validateGovernanceTags(config.governanceTags);

  for (const [key, expected] of Object.entries(requiredPlatform)) {
    if (config[key] !== expected) {
      throw new Error(`${key} must be "${expected}".`);
    }
  }

  const addressSpace = parseCidr(config.addressSpace, 'addressSpace');
  if (!privateIpv4Ranges.some((range) => containsRange(parseCidr(range, 'RFC1918 range'), addressSpace))) {
    throw new Error('addressSpace must be contained within one RFC1918 private IPv4 range.');
  }

  if (!config.subnets || typeof config.subnets !== 'object' || Array.isArray(config.subnets)) {
    throw new Error('subnets must be an object.');
  }

  const subnetNames = Object.keys(config.subnets);
  if (
    subnetNames.length !== requiredSubnets.length
    || requiredSubnets.some((name) => !Object.hasOwn(config.subnets, name))
  ) {
    throw new Error(`subnets must contain exactly: ${requiredSubnets.join(', ')}.`);
  }

  const subnetRanges = requiredSubnets.map((name) => {
    const range = parseCidr(config.subnets[name], `subnets.${name}`);

    if (range.prefix > 29) {
      throw new Error(`subnets.${name} must be /29 or larger for an Azure subnet.`);
    }

    if (range.start < addressSpace.start || range.end > addressSpace.end) {
      throw new Error(`subnets.${name} must be contained within addressSpace.`);
    }

    return { name, range };
  });

  for (let index = 0; index < subnetRanges.length; index += 1) {
    for (let otherIndex = index + 1; otherIndex < subnetRanges.length; otherIndex += 1) {
      if (overlaps(subnetRanges[index].range, subnetRanges[otherIndex].range)) {
        throw new Error(`subnets.${subnetRanges[index].name} overlaps subnets.${subnetRanges[otherIndex].name}.`);
      }
    }
  }

  const aca = subnetRanges.find(({ name }) => name === 'aca').range;
  if (aca.prefix > 27) {
    throw new Error('subnets.aca must be /27 or larger for an ACA workload-profiles environment.');
  }

  const consumerPrivateEndpoints = subnetRanges.find(
    ({ name }) => name === 'consumerPrivateEndpoints',
  ).range;
  if (consumerPrivateEndpoints.prefix !== 26) {
    throw new Error('subnets.consumerPrivateEndpoints must be /26.');
  }

  for (const reservedRange of acaReservedRanges) {
    if (overlaps(aca, parseCidr(reservedRange, 'ACA reserved range'))) {
      throw new Error(`subnets.aca overlaps ACA-reserved range ${reservedRange}.`);
    }
  }

  if (!Array.isArray(config.privateDnsZones) || config.privateDnsZones.length === 0) {
    throw new Error('privateDnsZones must be a non-empty array.');
  }

  if (
    config.privateDnsZones.some(
      (zone) => typeof zone !== 'string' || !zone || !isValidDnsZoneName(zone),
    )
  ) {
    throw new Error('privateDnsZones must contain valid DNS zone names.');
  }

  const normalizedZones = config.privateDnsZones.map((zone) => zone.toLowerCase());
  if (new Set(normalizedZones).size !== normalizedZones.length) {
    throw new Error('privateDnsZones must contain unique zone names, ignoring case.');
  }

  const normalizedZoneSet = new Set(normalizedZones);
  const missingZones = requiredDnsZones.filter((zone) => !normalizedZoneSet.has(zone.toLowerCase()));
  if (missingZones.length > 0) {
    throw new Error(`privateDnsZones is missing required zones: ${missingZones.join(', ')}.`);
  }
}

if (require.main === module) {
  try {
    const configPath = path.join(__dirname, '..', 'infra', 'network-config.json');
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    validateNetworkConfig(config);
    console.log(
      `Network configuration is valid (${requiredSubnets.length} subnets, ${config.privateDnsZones.length} private DNS zones).`,
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { validateGovernanceTags, validateNetworkConfig };
