targetScope = 'subscription'

@description('Non-secret 32-character lowercase hexadecimal spike run ID.')
@minLength(32)
@maxLength(32)
param runId string

@description('Reviewed 40-character source commit SHA for ownership tags.')
@minLength(40)
@maxLength(40)
param head string

@description('Exact Canonical Ubuntu 24.04 Marketplace version verified for Sweden Central before an authorized deployment.')
@minLength(1)
param canonicalUbuntuVersion string

@description('Non-secret controller bootstrap custom data. Never include GitHub App credentials or JIT data.')
param controllerBootstrapCustomData string

@description('Existing operator-provided SSH public key for controller administration. This is a public key, not a private key.')
@minLength(1)
param adminSshPublicKey string

@description('GitHub App private key supplied only by the protected deployment workflow as an ARM secure parameter.')
@secure()
param githubAppPrivateKey string

var location = 'swedencentral'
var approvedSubscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
var approvedTenantId = '30bac921-1547-4b1e-8445-72455da783f1'
var approvedResourceGroupName = 'rg-ghrunners-spike-vmss-swc'
var approvedScopeValues = [
  'approved'
]
var approvedScopeIndex = (subscription().subscriptionId == approvedSubscriptionId && tenant().tenantId == approvedTenantId) ? 0 : 1
var approvedScope = approvedScopeValues[approvedScopeIndex]

var tags = {
  application: 'ghrunners'
  environment: 'spike'
  workload: 'gh-runners'
  owner: 'jonathan-vella'
  costcenter: 'platform-engineering'
  'tech-contact': 'jonathan-vella'
  'technical-contact': 'jonathan-vella'
  sla: 'development'
  'backup-policy': 'none'
  'maint-window': 'none'
  'spike-id': '60'
  'spike-run-id': runId
  'spike-head': head
  'deployment-scope': approvedScope
}

resource spikeResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: approvedResourceGroupName
  location: location
  tags: tags
}

module foundation 'main.bicep' = {
  name: 'vmss-flex-spike-foundation'
  scope: resourceGroup(spikeResourceGroup.name)
  params: {
    runId: runId
    head: head
    canonicalUbuntuVersion: canonicalUbuntuVersion
    controllerBootstrapCustomData: controllerBootstrapCustomData
    adminSshPublicKey: adminSshPublicKey
    githubAppPrivateKey: githubAppPrivateKey
  }
}

output resourceGroupId string = spikeResourceGroup.id
output location string = foundation.outputs.location
output virtualNetworkId string = foundation.outputs.virtualNetworkId
output controllerSubnetId string = foundation.outputs.controllerSubnetId
output workerSubnetId string = foundation.outputs.workerSubnetId
output privateEndpointSubnetId string = foundation.outputs.privateEndpointSubnetId
output controllerVmId string = foundation.outputs.controllerVmId
output controllerNicId string = foundation.outputs.controllerNicId
output controllerOsDiskId string = foundation.outputs.controllerOsDiskId
output controllerManagedIdentityPrincipalId string = foundation.outputs.controllerManagedIdentityPrincipalId
output controllerPrincipalId string = foundation.outputs.controllerPrincipalId
output flexScaleSetId string = foundation.outputs.flexScaleSetId
output flexScaleSetResourceId string = foundation.outputs.flexScaleSetResourceId
output workerSubnetResourceId string = foundation.outputs.workerSubnetResourceId
output keyVaultId string = foundation.outputs.keyVaultId
output keyVaultPrivateEndpointId string = foundation.outputs.keyVaultPrivateEndpointId
output keyVaultSecretVersionUri string = foundation.outputs.keyVaultSecretVersionUri
output secretVersionUri string = foundation.outputs.secretVersionUri
output natGatewayId string = foundation.outputs.natGatewayId
output natPublicIpId string = foundation.outputs.natPublicIpId
