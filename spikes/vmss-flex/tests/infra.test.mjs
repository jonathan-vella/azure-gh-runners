import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const foundation = readFileSync(new URL('../infra/main.bicep', import.meta.url), 'utf8');
const subscription = readFileSync(new URL('../infra/subscription.bicep', import.meta.url), 'utf8');
const worker = readFileSync(new URL('../infra/worker.bicep', import.meta.url), 'utf8');

test('foundation pins the approved isolated spike scope and versioned AVMs', () => {
  assert.match(foundation, /targetScope = 'resourceGroup'/);
  assert.match(foundation, /var location = 'swedencentral'/);
  assert.match(foundation, /b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/);
  assert.match(foundation, /30bac921-1547-4b1e-8445-72455da783f1/);
  assert.match(foundation, /rg-ghrunners-spike-vmss-swc/);
  assert.match(foundation, /param runOrdinal int/);
  assert.match(foundation, /var keyVaultName = 'kv-ghr60-\$\{substring\(runId, 0, 14\)\}\$\{string\(runOrdinal\)\}'/);
  for (const moduleRef of [
    'avm/res/network/network-security-group:0.5.0',
    'avm/res/network/nat-gateway:2.1.0',
    'avm/res/network/virtual-network:0.10.0',
    'avm/res/network/private-dns-zone:0.8.0',
    'avm/res/key-vault/vault:0.14.0',
    'avm/res/compute/virtual-machine:0.22.0',
  ]) {
    assert.ok(foundation.includes(moduleRef), `Missing exact AVM reference ${moduleRef}`);
  }
});

test('subscription wrapper creates the fixed tagged resource group and deploys foundation in one invocation', () => {
  assert.match(subscription, /targetScope = 'subscription'/);
  assert.match(subscription, /Microsoft\.Resources\/resourceGroups@2024-03-01/);
  assert.match(subscription, /var approvedResourceGroupName = 'rg-ghrunners-spike-vmss-swc'/);
  assert.match(subscription, /var location = 'swedencentral'/);
  assert.match(subscription, /location: location/);
  assert.match(subscription, /param runOrdinal int/);
  assert.match(subscription, /runOrdinal: runOrdinal/);
  assert.match(subscription, /scope: resourceGroup\(spikeResourceGroup\.name\)/);
  assert.match(subscription, /module foundation 'main\.bicep'/);
  assert.match(subscription, /@secure\(\)\s*param githubAppPrivateKey string/);
  assert.match(subscription, /@minLength\(1\)\s*param adminSshPublicKey string/);
  assert.match(subscription, /adminSshPublicKey: adminSshPublicKey/);
  assert.match(subscription, /githubAppPrivateKey: githubAppPrivateKey/);
  assert.match(subscription, /output keyVaultSecretVersionUri string = foundation\.outputs\.keyVaultSecretVersionUri/);
  assert.match(subscription, /output keyVaultName string = foundation\.outputs\.keyVaultName/);
  assert.match(subscription, /output keyVaultSecretScope string = foundation\.outputs\.keyVaultSecretScope/);
  assert.match(subscription, /output keyVaultSoftDeleteRetentionInDays int = foundation\.outputs\.keyVaultSoftDeleteRetentionInDays/);
  assert.match(subscription, /output keyVaultPurgeProtectionEnabled bool = foundation\.outputs\.keyVaultPurgeProtectionEnabled/);
  assert.match(subscription, /output controllerPrincipalId string = foundation\.outputs\.controllerPrincipalId/);
  assert.match(subscription, /output secretVersionUri string = foundation\.outputs\.secretVersionUri/);
  assert.match(subscription, /output workerSubnetResourceId string = foundation\.outputs\.workerSubnetResourceId/);
  assert.match(subscription, /output flexScaleSetResourceId string = foundation\.outputs\.flexScaleSetResourceId/);
  assert.doesNotMatch(subscription, /Microsoft\.Authorization\/roleAssignments|roleAssignments:|githubAppPrivateKey string =|output .*githubAppPrivateKey/i);
  for (const outputName of [
    'resourceGroupId',
    'virtualNetworkId',
    'controllerSubnetId',
    'workerSubnetId',
    'privateEndpointSubnetId',
    'controllerVmId',
    'controllerNicId',
    'controllerOsDiskId',
    'controllerManagedIdentityPrincipalId',
    'controllerPrincipalId',
    'flexScaleSetId',
    'flexScaleSetResourceId',
    'workerSubnetResourceId',
    'keyVaultId',
    'keyVaultPrivateEndpointId',
    'keyVaultSecretVersionUri',
    'secretVersionUri',
    'natGatewayId',
    'natPublicIpId',
  ]) {
    assert.match(subscription, new RegExp(`output ${outputName} string =`), `Missing sanitized output ${outputName}`);
  }
});

test('foundation uses the three private subnets, restrictive NSGs, and one NAT public IP', () => {
  assert.match(foundation, /controllerSubnetName/);
  assert.match(foundation, /workerSubnetName/);
  assert.match(foundation, /privateEndpointSubnetName/);
  assert.match(foundation, /defaultOutboundAccess: false/);
  assert.match(foundation, /privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'/);
  assert.match(foundation, /DenyPrivateEndpointSubnet/);
  assert.match(foundation, /DenyControllerSubnet/);
  assert.match(foundation, /DenyWorkerSubnet/);
  assert.match(foundation, /publicIPAddresses: \[\s*\{\s*name: natPublicIpName/);
  assert.doesNotMatch(foundation, /publicIPAddressResourceId|publicIpEnabled|Microsoft\.Storage\/storageAccounts/);
});

test('foundation has a controller-only system identity and secure private Key Vault secret input', () => {
  assert.match(foundation, /managedIdentities: \{\s*systemAssigned: true\s*\}/);
  assert.match(foundation, /param adminSshPublicKey string/);
  assert.match(foundation, /var controllerVmName = 'vm-ghr-spike60-controller'/);
  assert.match(foundation, /adminUsername: 'ghrcontroller'\s*disablePasswordAuthentication: true\s*publicKeys: \[\s*\{\s*path: '\/home\/ghrcontroller\/\.ssh\/authorized_keys'\s*keyData: adminSshPublicKey/);
  assert.match(foundation, /adminUsername: 'ghrcontroller'\s*disablePasswordAuthentication: true\s*publicKeys: \[\s*\{\s*path: '\/home\/ghrcontroller\/\.ssh\/authorized_keys'\s*keyData: adminSshPublicKey/);
  assert.match(foundation, /@secure\(\)\s*param githubAppPrivateKey string/);
  assert.match(foundation, /publicNetworkAccess: 'Disabled'/);
  assert.match(foundation, /enableRbacAuthorization: true/);
  assert.match(foundation, /enablePurgeProtection: false/);
  assert.match(foundation, /softDeleteRetentionInDays: 7/);
  assert.match(foundation, /output keyVaultSoftDeleteRetentionInDays int = 7/);
  assert.match(foundation, /output keyVaultPurgeProtectionEnabled bool = false/);
  assert.match(foundation, /output keyVaultSecretScope string = '\$\{keyVault\.outputs\.resourceId\}\/secrets\/github-app-private-key'/);
  assert.match(foundation, /output keyVaultName string = keyVaultName/);
  assert.match(foundation, /name: 'github-app-private-key'\s*value: githubAppPrivateKey/);
  assert.match(foundation, /output keyVaultSecretVersionUri string = keyVault\.outputs\.secrets\[0\]\.uriWithVersion/);
  assert.doesNotMatch(foundation, /Microsoft\.Authorization\/roleAssignments|roleAssignments:/);
});

test('foundation creates no worker and keeps the canonical image version pinned', () => {
  assert.match(foundation, /capacity: 0/);
  assert.match(foundation, /orchestrationMode: 'Flexible'/);
  assert.match(foundation, /name: 'Standard_D2ls_v5'/);
  assert.match(foundation, /terminateNotificationProfile:\s*\{\s*enable: true\s*notBeforeTimeout: 'PT5M'/);
  assert.match(foundation, /pinnedCanonicalUbuntuVersion/);
  assert.match(foundation, /toLower\(canonicalUbuntuVersion\) == 'latest' \? 1 : 0/);
  assert.match(foundation, /version: pinnedCanonicalUbuntuVersion/);
  assert.match(foundation, /virtualMachines: 1/);
  assert.doesNotMatch(foundation, /name: 'vm-ghr-spike60-\$\{runId\}-\$\{workerIndex\}'/);
  assert.match(foundation, /diskSizeGB: 32/);
  assert.match(foundation, /storageAccountType: 'Premium_LRS'/);
  assert.match(foundation, /resource controllerOsDiskTags 'Microsoft\.Resources\/tags@2021-04-01'/);
});

test('worker template is a single bounded AVM VM with deterministic owned resources', () => {
  assert.match(worker, /avm\/res\/compute\/virtual-machine:0\.22\.0/);
  assert.match(worker, /@allowed\(\[\s*1\s*2\s*\]\)\s*param workerIndex int/);
  assert.match(worker, /vm-ghr-spike60-\$\{substring\(runId, 0, 25\)\}-\$\{workerIndex\}/);
  assert.match(worker, /nic-\$\{virtualMachineName\}/);
  assert.match(worker, /disk-\$\{virtualMachineName\}-os/);
  assert.match(worker, /'spike-id': '60'/);
  assert.match(worker, /'spike-run-id': runId/);
  assert.match(worker, /'spike-head': head/);
  assert.match(worker, /virtualMachineScaleSetResourceId: flexScaleSetResourceId/);
  assert.match(worker, /vmSize: 'Standard_D2ls_v5'/);
  assert.match(worker, /customData: bootstrapCustomData/);
  assert.match(worker, /param adminSshPublicKey string/);
  assert.match(worker, /adminUsername: 'ghrworker'\s*disablePasswordAuthentication: true\s*publicKeys: \[\s*\{\s*path: '\/home\/ghrworker\/\.ssh\/authorized_keys'\s*keyData: adminSshPublicKey/);
  assert.doesNotMatch(worker, /managedIdentities:|publicIP|publicIPAddressResourceId/);
  for (const tag of ['spike-id', 'spike-run-id', 'spike-head']) {
    assert.ok(worker.includes(`'${tag}'`), `Missing ownership tag ${tag}`);
  }
  assert.match(worker, /output workerVmId string = worker\.outputs\.resourceId/);
  assert.match(worker, /output nicId string = resourceId\('Microsoft\.Network\/networkInterfaces', networkInterfaceName\)/);
  assert.match(worker, /output osDiskId string = resourceId\('Microsoft\.Compute\/disks', osDiskName\)/);
  assert.match(worker, /diskSizeGB: 32/);
  assert.match(worker, /storageAccountType: 'Premium_LRS'/);
  assert.match(worker, /resource workerOsDiskTags 'Microsoft\.Resources\/tags@2021-04-01'/);
});

test('worker delivers JIT only through secure protected CSE settings and requests instance protection', () => {
  assert.match(worker, /@secure\(\)\s*param jitProtectedScript string/);
  assert.match(worker, /typeHandlerVersion: '2\.1'/);
  assert.match(worker, /autoUpgradeMinorVersion: false/);
  assert.match(worker, /enableAutomaticUpgrade: false/);
  assert.match(worker, /settings: \{\}\s*protectedSettings: \{\s*script: jitProtectedScript\s*\}/);
  assert.match(worker, /var scaleSetInstanceId = virtualMachineName/);
  assert.match(worker, /Microsoft\.Compute\/virtualMachineScaleSets\/virtualMachines@2025-04-01/);
  assert.match(worker, /name: scaleSetInstanceId[\s\S]*?protectionPolicy:\s*\{\s*protectFromScaleIn: true\s*protectFromScaleSetActions: true/);
  assert.match(worker, /@secure\(\)\s*param jitProtectedScript string/);
  assert.match(worker, /settings: \{\}\s*protectedSettings: \{\s*script: jitProtectedScript\s*\}/);
  assert.match(worker, /toLower\(canonicalUbuntuVersion\) == 'latest' \? 1 : 0/);
  assert.doesNotMatch(worker, /output .*(?:jitProtectedScript|ProtectedScript)/i);
  assert.doesNotMatch(worker, /customData: jitProtectedScript/i);
});
