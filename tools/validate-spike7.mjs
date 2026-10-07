import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const template = await readFile(new URL('../infra/spike7/main.bicep', import.meta.url), 'utf8');
const runner = await readFile(new URL('../infra/spike7/Invoke-Spike.ps1', import.meta.url), 'utf8');

const requiredTemplateText = [
  "'br/public:avm/res/network/virtual-network:0.10.2'",
  "'br/public:avm/res/network/private-dns-zone:0.8.1'",
  "'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0'",
  "'br/public:avm/res/key-vault/vault:0.14.2'",
  "'br/public:avm/res/network/private-endpoint:0.12.1'",
  "'br/public:avm/res/app/managed-environment:0.16.0'",
  "'br/public:avm/res/app/job:0.7.2'",
  'mcr.microsoft.com/azure-cli@sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044',
  '@secure()',
  "publicNetworkAccess: 'Disabled'",
  "bypass: 'None'",
  "defaultAction: 'Deny'",
  "internal: true",
  "privateLinkServiceId: keyVault.outputs.resourceId",
  "privateDnsZoneResourceId: resourceId('Microsoft.Network/privateDnsZones', dnsZoneName)",
  "roleDefinitionIdOrName: keyVaultSecretsUserRoleId",
  "name: 'PROBE_SECRET'",
  "name: 'EXPECTED_SHA256'",
  'RESULT=match',
  'RESULT=mismatch',
];

for (const expected of requiredTemplateText) {
  assert.ok(template.includes(expected), `Spike template is missing required invariant: ${expected}`);
}

assert.match(runner, /b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/);
assert.match(runner, /30bac921-1547-4b1e-8445-72455da783f1/);
assert.match(runner, /rg-ghrunners-spike7-swc/);
assert.match(runner, /if \(\$SubscriptionId -cne \$approvedSubscription\)/);
assert.match(runner, /ConfirmCapacityRecovered/);
assert.match(runner, /SetAccessRuleProtection\(\$true, \$false\)/);
assert.match(runner, /--set 'properties\.networkAcls\.bypass=AzureServices'/);
assert.match(runner, /--set 'properties\.networkAcls\.bypass=None'/);
assert.match(runner, /properties\.publicNetworkAccess -cne 'Disabled'/);
assert.doesNotMatch(runner, /purge|Delete-AzKeyVault/);
assert.doesNotMatch(template, /publicNetworkAccess:\s*'Enabled'/);
assert.doesNotMatch(template, /Microsoft\.App\/jobs\/start\/action/);
assert.doesNotMatch(template, /printenv|echo\s+\$PROBE_SECRET/);

console.log('Issue-7 local artifact invariants passed.');
