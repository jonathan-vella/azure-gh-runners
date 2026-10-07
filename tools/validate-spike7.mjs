import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const template = await readFile(new URL('../infra/spike7/main.bicep', import.meta.url), 'utf8');
const jobTemplate = await readFile(new URL('../infra/spike7/job.bicep', import.meta.url), 'utf8');
const runner = await readFile(new URL('../infra/spike7/Invoke-Spike.ps1', import.meta.url), 'utf8');
const comparison = await readFile(new URL('../infra/spike7/Comparison.psm1', import.meta.url), 'utf8');
const lifecycle = await readFile(new URL('../infra/spike7/Lifecycle.psm1', import.meta.url), 'utf8');
const lifecycleCommand = await readFile(new URL('../infra/spike7/Invoke-Lifecycle.ps1', import.meta.url), 'utf8');
const boundedProcess = await readFile(new URL('./spikes/keda-egress/Process.psm1', import.meta.url), 'utf8');

const requiredTemplateText = [
  "'br/public:avm/res/network/public-ip-address:0.13.0'",
  "'br/public:avm/res/network/nat-gateway:2.1.1'",
  "'br/public:avm/res/network/network-security-group:0.5.3'",
  "'br/public:avm/res/network/virtual-network:0.10.2'",
  "'br/public:avm/res/network/private-dns-zone:0.8.1'",
  "'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0'",
  "'br/public:avm/res/key-vault/vault:0.14.2'",
  "'br/public:avm/res/network/private-endpoint:0.12.1'",
  "'br/public:avm/res/app/managed-environment:0.16.0'",
  '@secure()',
  "publicNetworkAccess: 'Disabled'",
  "bypass: 'None'",
  "defaultAction: 'Deny'",
  "internal: true",
  "natGatewayResourceId: natGateway.outputs.resourceId",
  "networkSecurityGroupResourceId: acaNetworkSecurityGroup.outputs.resourceId",
  "privateLinkServiceId: keyVault.outputs.resourceId",
  "privateDnsZoneResourceId: resourceId('Microsoft.Network/privateDnsZones', dnsZoneName)",
  "roleDefinitionIdOrName: keyVaultSecretsUserRoleId",
  "param workloadProfileName string = 'Consumption'",
  "name: 'D4'",
  "workloadProfileType: 'D4'",
  'minimumCount: 0',
  'maximumCount: 3',
  "name: 'Consumption'",
  "workloadProfileType: 'Consumption'",
  'maximumCount: 1',
  'zoneRedundant: false',
  'output workloadProfileName string = workloadProfileName',
];

for (const expected of requiredTemplateText) {
  assert.ok(template.includes(expected), `Spike template is missing required invariant: ${expected}`);
}

assert.ok(jobTemplate.includes("'br/public:avm/res/app/job:0.7.2'"));
assert.ok(jobTemplate.includes('mcr.microsoft.com/azure-cli@sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044'));
assert.ok(jobTemplate.includes('RESULT=match'));
assert.ok(jobTemplate.includes('RESULT=mismatch'));
assert.ok(jobTemplate.includes("name: 'PROBE_SECRET'"));
assert.ok(jobTemplate.includes("name: 'EXPECTED_SHA256'"));
assert.match(jobTemplate, /workloadProfileName: workloadProfileName/);
assert.match(jobTemplate, /parallelism: 1[\s\S]*replicaCompletionCount: 1/);
assert.match(jobTemplate, /cpu: '0\.25'[\s\S]*memory: '0\.5Gi'/);
for (const [permit, deny] of [
  ['Allow-KeyVault-PrivateEndpoint', 'Deny-RFC1918-10'],
  ['Allow-HTTPS-Egress-Via-NAT', 'Deny-RFC1918-10'],
  ['Deny-RFC1918-10', 'Deny-RFC1918-172'],
  ['Deny-RFC1918-172', 'Deny-RFC1918-192'],
]) {
  assert.ok(template.indexOf(permit) < template.indexOf(deny), `${permit} must precede ${deny}`);
}

assert.match(runner, /b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/);
assert.match(runner, /30bac921-1547-4b1e-8445-72455da783f1/);
assert.match(runner, /rg-ghrunners-spike7-swc/);
assert.match(runner, /swedencentral/);
assert.match(runner, /if \(\$SubscriptionId -cne \$approvedSubscription\)/);
assert.match(runner, /An explicit --subscription ID is required for every Azure operation/);
assert.match(runner, /ConfirmCapacityRecovered/);
assert.match(runner, /ConfirmD4ProfileAttempt/);
assert.match(runner, /ValidateSet\('Consumption', 'D4'\)/);
assert.match(runner, /minimumCount=0, maximumCount=3, zoneRedundant=false/);
assert.match(runner, /zoneRedundant -cne \$false/);
assert.match(runner, /properties\.workloadProfileName -cne \$Profile/);
assert.match(runner, /workloadProfileName=\$Profile/);
assert.match(runner, /EnvironmentProvisioningState =/);
assert.match(runner, /stage=resource-group-deployment/);
assert.match(runner, /originalExit=\$\(\$result\.ExitCode\).*originalCode=\$\(\$result\.ErrorCode\)/);
assert.match(runner, /'Cleanup'\s*\{[\s\S]*Get-SpikeDeploymentState[\s\S]*'group', 'delete'/);
assert.match(runner, /'Succeeded', 'Failed', 'Canceled'/);
assert.match(runner, /DeploymentAbsentOwnedGroupEmpty/);
assert.match(lifecycle, /finally[\s\S]*try \{ & \$Diagnose \} catch[\s\S]*try \{ & \$Cleanup \} catch/);
assert.match(lifecycle, /System\.AggregateException/);
assert.match(lifecycleCommand, /Assert-ApprovedScope[\s\S]*Assert-ProfileAuthorization[\s\S]*Get-ResourceGroupExists[\s\S]*Invoke-SpikeLifecycle/);
assert.doesNotMatch(lifecycleCommand, /&\s*az\b/);
assert.match(runner, /Stage = 'job-provisioning'/);
assert.match(runner, /'containerapp', 'env', 'show', '--subscription', \$approvedSubscription/);
assert.match(runner, /'containerapp', 'job', 'show', '--subscription', \$approvedSubscription/);
assert.match(runner, /function Invoke-AzProcess[\s\S]*Invoke-BoundedProcess[\s\S]*Get-RemainingActionSeconds/);
assert.match(runner, /function Invoke-AzJson[\s\S]*Invoke-AzProcess/);
assert.match(runner, /function Invoke-AzBounded[\s\S]*Invoke-AzProcess/);
assert.match(runner, /function Get-ResourceGroupExists[\s\S]*Invoke-AzProcess/);
assert.match(runner, /function Get-OptionalTaggedResourceGroup[\s\S]*Get-ResourceGroupExists[\s\S]*Get-TaggedResourceGroup/);
assert.match(runner, /'Cleanup'\s*\{[\s\S]*Get-OptionalTaggedResourceGroup[\s\S]*already absent; cleanup is complete/);
assert.equal((runner.match(/Invoke-BoundedProcess/g) ?? []).length, 1, 'All subprocesses use the single bounded wrapper');
assert.doesNotMatch(runner, /(?:^|\n)\s*&\s*az(?:\.cmd|\.exe)?\b/m, 'No Azure CLI call can bypass the wrapper');
assert.doesNotMatch(runner, /ProcessStartInfo|WaitForExit|\.Kill\(/, 'Process lifecycle is delegated to the shared helper');
assert.match(boundedProcess, /RedirectStandardOutput = \$true/);
assert.match(boundedProcess, /RedirectStandardError = \$true/);
assert.match(boundedProcess, /ReadToEndAsync\(\)/);
assert.match(boundedProcess, /Kill\(\$true\)/);
assert.match(boundedProcess, /WaitForExit\(5000\)/);
assert.match(boundedProcess, /WaitAll/);
assert.match(boundedProcess, /\$process\.Dispose\(\)/);
assert.match(runner, /function Get-OptionalTaggedResourceGroup[\s\S]*if \(-not \(Get-ResourceGroupExists\)\)[\s\S]*return \$null/);
assert.match(runner, /Resource-group existence readback was ambiguous/);
assert.match(runner, /unexpected scope\/location/);
assert.match(runner, /SetAccessRuleProtection\(\$true, \$false\)/);
assert.match(runner, /New-FreshDiagnosticJob/);
assert.match(runner, /Invoke-SpikeBypassComparison/);
assert.match(runner, /probeDigest=\$ProbeDigest/);
assert.match(comparison, /finally/);
assert.match(comparison, /Neither trusted-services configuration resolved the probe/);
assert.match(runner, /properties\.publicNetworkAccess -cne 'Disabled'/);
assert.doesNotMatch(runner, /purge|Delete-AzKeyVault/);
assert.doesNotMatch(template, /publicNetworkAccess:\s*'Enabled'/);
assert.doesNotMatch(template, /natGatewayResourceId: null/);
assert.doesNotMatch(jobTemplate, /Microsoft\.App\/jobs\/start\/action/);
assert.doesNotMatch(jobTemplate, /printenv|echo\s+\$PROBE_SECRET/);
assert.doesNotMatch(template, /zones\s*:/);
assert.doesNotMatch(runner, /rg-ghrunners-prod-swc|rg-ghrunners-spike6-swc/);

console.log('Issue-7 local artifact invariants passed.');
