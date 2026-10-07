const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const config = require('../infra/network-config.json');
const { validateGovernanceTags, validateNetworkConfig } = require('./validate-network.js');
const networkBicep = fs.readFileSync(
  path.join(__dirname, '..', 'infra', 'modules', 'network.bicep'),
  'utf8',
);

function rulesNamed(name) {
  const rulePattern = new RegExp(
    `name: '${name}'\\s+properties: \\{([\\s\\S]*?)\\n\\s{4}\\}`,
    'g',
  );
  return [...networkBicep.matchAll(rulePattern)].map((match) => match[1]);
}

function copyConfig() {
  return JSON.parse(JSON.stringify(config));
}

test('approved network configuration has required ranges, DNS zones, and tags', () => {
  assert.doesNotThrow(() => validateNetworkConfig(config));
});

test('network configuration rejects overlapping subnets', () => {
  const invalidConfig = copyConfig();
  invalidConfig.subnets.acrAgents = invalidConfig.subnets.aca;

  assert.throws(() => validateNetworkConfig(invalidConfig), /overlaps/);
});

test('network configuration rejects subnets outside the VNet address space', () => {
  const invalidConfig = copyConfig();
  invalidConfig.subnets.privateEndpoints = '10.61.0.0/27';

  assert.throws(() => validateNetworkConfig(invalidConfig), /contained within addressSpace/);
});

test('VNet address space must use RFC1918 private IPv4 addresses', () => {
  const invalidConfig = copyConfig();
  invalidConfig.addressSpace = '8.0.0.0/22';

  assert.throws(() => validateNetworkConfig(invalidConfig), /addressSpace must be contained within one RFC1918/);
});

test('network configuration enforces ACA and ACR agent subnet sizing', () => {
  const undersizedAca = copyConfig();
  undersizedAca.subnets.aca = '10.60.0.0/28';
  assert.throws(() => validateNetworkConfig(undersizedAca), new RegExp('aca must be /27 or larger'));

  const undersizedAgents = copyConfig();
  undersizedAgents.subnets.acrAgents = '10.60.0.32/28';
  assert.throws(
    () => validateNetworkConfig(undersizedAgents),
    new RegExp('acrAgents must be /27 or larger'),
  );
});

test('all subnets reject ranges smaller than Azure minimum /29', () => {
  const invalidConfig = copyConfig();
  invalidConfig.subnets.privateEndpoints = '10.60.0.64/32';

  assert.throws(
    () => validateNetworkConfig(invalidConfig),
    new RegExp('privateEndpoints must be /29 or larger'),
  );
});

test('consumer private endpoint subnet must remain /26', () => {
  const invalidConfig = copyConfig();
  invalidConfig.subnets.consumerPrivateEndpoints = '10.60.0.128/27';

  assert.throws(
    () => validateNetworkConfig(invalidConfig),
    new RegExp('consumerPrivateEndpoints must be /26'),
  );
});

test('ACA subnet cannot overlap Azure-reserved address ranges', () => {
  const invalidConfig = copyConfig();
  invalidConfig.addressSpace = '172.30.0.0/24';
  invalidConfig.subnets.aca = '172.30.0.0/27';
  invalidConfig.subnets.acrAgents = '172.30.0.32/27';
  invalidConfig.subnets.privateEndpoints = '172.30.0.64/27';
  invalidConfig.subnets.consumerPrivateEndpoints = '172.30.0.128/26';

  assert.throws(() => validateNetworkConfig(invalidConfig), /ACA-reserved range/);
});

test('private DNS configuration includes all required zones', () => {
  const invalidConfig = copyConfig();
  invalidConfig.privateDnsZones = ['privatelink.blob.core.windows.net'];

  assert.throws(() => validateNetworkConfig(invalidConfig), /missing required zones/);
});

test('private DNS names reject invalid syntax and case-insensitive duplicates', () => {
  const invalidSyntax = copyConfig();
  invalidSyntax.privateDnsZones.push('invalid zone name');
  assert.throws(() => validateNetworkConfig(invalidSyntax), /valid DNS zone names/);

  const duplicate = copyConfig();
  duplicate.privateDnsZones.push('PRIVATELINK.BLOB.CORE.WINDOWS.NET');
  assert.throws(() => validateNetworkConfig(duplicate), /unique zone names, ignoring case/);
});

test('governance tags require the approved contract and permit additional tags', () => {
  const tags = { ...config.governanceTags, service: 'platform' };
  assert.doesNotThrow(() => validateGovernanceTags(tags));

  tags.environment = 'test';
  assert.throws(() => validateGovernanceTags(tags), /governanceTags.environment/);
});

test('compute subnet rules allow only explicit HTTPS and required service dependencies', () => {
  const privateEndpointRules = rulesNamed('Allow-Private-Endpoints-HTTPS');
  const internetRules = rulesNamed('Allow-Internet-HTTPS');

  assert.equal(privateEndpointRules.length, 2);
  assert.equal(internetRules.length, 2);
  for (const rule of [...privateEndpointRules, ...internetRules]) {
    assert.match(rule, /destinationPortRange: '443'/);
    assert.match(rule, /direction: 'Outbound'/);
  }
  for (const rule of privateEndpointRules) {
    assert.match(rule, /destinationAddressPrefixes:/);
    assert.match(rule, /subnets\.privateEndpoints/);
    assert.match(rule, /subnets\.consumerPrivateEndpoints/);
  }
  for (const rule of internetRules) {
    assert.match(rule, /destinationAddressPrefix: 'Internet'/);
  }
});

test('compute subnet rules explicitly deny RFC1918 lateral ranges', () => {
  for (const [name, range] of [
    ['Deny-RFC1918-10', '10.0.0.0/8'],
    ['Deny-RFC1918-172', '172.16.0.0/12'],
    ['Deny-RFC1918-192', '192.168.0.0/16'],
  ]) {
    const rules = rulesNamed(name);
    assert.equal(rules.length, 2);
    for (const rule of rules) {
      assert.match(rule, new RegExp(`destinationAddressPrefix: '${range.replaceAll('.', '\\.')}'`));
      assert.match(rule, /access: 'Deny'/);
      assert.match(rule, /direction: 'Outbound'/);
    }
  }
});

test('VNet subnets use the required layout and share NAT only across compute subnets', () => {
  for (const [name, address] of [
    ['snet-aca', 'subnets.aca'],
    ['snet-acr-agents', 'subnets.acrAgents'],
    ['snet-pe', 'subnets.privateEndpoints'],
    ['snet-consumer-pe', 'subnets.consumerPrivateEndpoints'],
  ]) {
    assert.match(networkBicep, new RegExp(`name: '${name}'\\s+addressPrefix: networkConfig\\.${address}`));
  }

  assert.match(networkBicep, /delegation: 'Microsoft\.App\/environments'/);
  assert.equal(
    [...networkBicep.matchAll(/natGatewayResourceId: natGateway\.outputs\.resourceId/g)].length,
    2,
  );
  assert.match(networkBicep, /publicIPAllocationMethod: 'Static'/);
  assert.match(networkBicep, /skuName: 'Standard'/);
});

test('ACA permits only its own subnet and platform probes inbound before the deny', () => {
  const inboundRule = rulesNamed('Allow-ACA-Subnet-Inbound-Dependencies');
  const inboundDeny = rulesNamed('Deny-Other-Inbound');
  const probeRule = rulesNamed('Allow-ACA-Load-Balancer-Probes');

  assert.equal(inboundRule.length, 1);
  assert.equal(inboundDeny.length, 2);
  assert.equal(probeRule.length, 1);
  assert.match(inboundRule[0], /sourceAddressPrefix: networkConfig\.subnets\.aca/);
  assert.match(inboundRule[0], /destinationAddressPrefix: networkConfig\.subnets\.aca/);
  assert.match(inboundRule[0], /direction: 'Inbound'/);
  assert.match(inboundRule[0], /priority: 110/);
  assert.match(probeRule[0], /sourceAddressPrefix: 'AzureLoadBalancer'/);
  assert.match(probeRule[0], /priority: 100/);
  assert.match(inboundDeny[0], /priority: 4096/);
});

test('ACA platform communication is explicitly allowed in both directions', () => {
  const inboundRule = rulesNamed('Allow-ACA-Subnet-Inbound-Dependencies');
  const outboundRule = rulesNamed('Allow-ACA-Subnet-Dependencies');

  assert.equal(inboundRule.length, 1);
  assert.equal(outboundRule.length, 1);
  for (const rule of [...inboundRule, ...outboundRule]) {
    assert.match(rule, /sourceAddressPrefix: networkConfig\.subnets\.aca/);
    assert.match(rule, /destinationAddressPrefix: networkConfig\.subnets\.aca/);
    assert.match(rule, /destinationPortRange: '\*'/);
    assert.match(rule, /protocol: '\*'/);
  }
  assert.match(inboundRule[0], /direction: 'Inbound'/);
  assert.match(outboundRule[0], /direction: 'Outbound'/);
});

test('network Bicep uses exact AVM module versions and exposes downstream resource IDs', () => {
  const moduleReferences = [...networkBicep.matchAll(/br\/public:avm\/res\/network\/[\w/-]+:\d+\.\d+\.\d+/g)];
  assert.deepEqual(
    moduleReferences.map(([reference]) => reference).sort(),
    [
      'br/public:avm/res/network/nat-gateway:2.1.1',
      'br/public:avm/res/network/network-security-group:0.5.3',
      'br/public:avm/res/network/network-security-group:0.5.3',
      'br/public:avm/res/network/private-dns-zone:0.8.1',
      'br/public:avm/res/network/public-ip-address:0.13.0',
      'br/public:avm/res/network/virtual-network:0.10.2',
    ].sort(),
  );
  assert.match(networkBicep, /natGatewayResourceId: natGateway\.outputs\.resourceId/g);
  assert.match(networkBicep, /output privateDnsZoneResourceIds array/);
  assert.match(networkBicep, /resourceId: privateDnsZones\[index\]\.outputs\.resourceId/);
});
