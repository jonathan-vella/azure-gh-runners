targetScope = 'resourceGroup'

@description('Non-secret 32-character lowercase hexadecimal spike run ID.')
@minLength(32)
@maxLength(32)
param runId string

@description('Reviewed 40-character source commit SHA for ownership tags.')
@minLength(40)
@maxLength(40)
param head string

@description('Worker slot within the two-worker spike cap. Slot 1 is the only slot allowed by the current deployment-call budget.')
@allowed([
  1
  2
])
param workerIndex int

@description('Exact Canonical Ubuntu 24.04 Marketplace version verified for Sweden Central immediately before an authorized deployment. "latest" is rejected at deployment evaluation.')
@minLength(1)
param canonicalUbuntuVersion string

@description('Resource ID of the pre-created empty Flexible VM scale set.')
param flexScaleSetResourceId string

@description('Resource ID of the worker subnet with defaultOutboundAccess disabled and NAT attached.')
param workerSubnetResourceId string

@description('Non-secret native bootstrap custom data. It must install the reviewed bootstrap and readiness marker without App-key or JIT material.')
param bootstrapCustomData string

@description('Existing operator-provided SSH public key for worker administration. This is a public key, not a private key.')
@minLength(1)
param adminSshPublicKey string

@description('Base64-encoded root Custom Script Extension script containing the one-time JIT handoff. Pass only as a secure ARM parameter.')
@secure()
param jitProtectedScript string

var location = 'swedencentral'
var approvedSubscriptionId = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
var approvedTenantId = '30bac921-1547-4b1e-8445-72455da783f1'
var approvedResourceGroupName = 'rg-ghrunners-spike-vmss-swc'
var approvedScopeValues = [
  'approved'
]
var approvedScopeIndex = (subscription().subscriptionId == approvedSubscriptionId && tenant().tenantId == approvedTenantId && resourceGroup().name == approvedResourceGroupName) ? 0 : 1
var approvedScope = approvedScopeValues[approvedScopeIndex]
// Flex VM resource names are limited to 44 characters. Keep the requested prefix and
// enough run-ID entropy to stay within that limit; the full run ID remains in ownership tags.
var virtualMachineName = 'vm-ghr-spike60-${substring(runId, 0, 25)}-${workerIndex}'
var networkInterfaceName = 'nic-${virtualMachineName}'
var osDiskName = 'disk-${virtualMachineName}-os'
var extensionName = 'CustomScript'
var scaleSetInstanceId = virtualMachineName
var canonicalUbuntuVersionCandidates = [
  canonicalUbuntuVersion
]
var canonicalUbuntuVersionIndex = toLower(canonicalUbuntuVersion) == 'latest' ? 1 : 0
var pinnedCanonicalUbuntuVersion = canonicalUbuntuVersionCandidates[canonicalUbuntuVersionIndex]

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
  'spike-worker-index': string(workerIndex)
  'deployment-scope': approvedScope
}

module worker 'br/public:avm/res/compute/virtual-machine:0.22.0' = {
  name: 'one-private-worker-${workerIndex}'
  params: {
    name: virtualMachineName
    computerName: virtualMachineName
    location: location
    vmSize: 'Standard_D2ls_v5'
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: '0001-com-ubuntu-server-noble'
      sku: '24_04-lts-gen2'
      version: pinnedCanonicalUbuntuVersion
    }
    virtualMachineScaleSetResourceId: flexScaleSetResourceId
    osDisk: {
      name: osDiskName
      diskSizeGB: 32
      createOption: 'FromImage'
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    adminUsername: 'ghrworker'
    disablePasswordAuthentication: true
    publicKeys: [
      {
        path: '/home/ghrworker/.ssh/authorized_keys'
        keyData: adminSshPublicKey
      }
    ]
    customData: bootstrapCustomData
    nicConfigurations: [
      {
        name: networkInterfaceName
        nicSuffix: 'worker-${workerIndex}'
        enableAcceleratedNetworking: false
        deleteOption: 'Delete'
        tags: tags
        ipConfigurations: [
          {
            name: 'ipconfig-worker'
            subnetResourceId: workerSubnetResourceId
          }
        ]
      }
    ]
    availabilityZone: -1
    enableTelemetry: false
    tags: tags
  }
}

// AVM 0.22's Custom Script parameter allows only commandToExecute/fileUris; it cannot express a protected inline
// script. The narrowly scoped raw child resource uses the verified Linux CSE v2.1 protectedSettings.script contract.
resource workerVmReference 'Microsoft.Compute/virtualMachines@2025-11-01' existing = {
  name: virtualMachineName
  dependsOn: [
    worker
  ]
}

resource workerCustomScript 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: workerVmReference
  name: extensionName
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: false
    enableAutomaticUpgrade: false
    settings: {}
    protectedSettings: {
      script: jitProtectedScript
    }
    suppressFailures: false
  }
  tags: tags
  dependsOn: [
    worker
  ]
}

// For Flexible orchestration, the VM resource name is the scale-set instance ID. Protection belongs to the
// per-instance model and is supported by API versions 2023-09-01 and later.
resource flexScaleSet 'Microsoft.Compute/virtualMachineScaleSets@2024-11-01' existing = {
  name: last(split(flexScaleSetResourceId, '/'))
}

resource workerScaleSetInstance 'Microsoft.Compute/virtualMachineScaleSets/virtualMachines@2025-04-01' = {
  parent: flexScaleSet
  name: scaleSetInstanceId
  location: location
  properties: {
    protectionPolicy: {
      protectFromScaleIn: true
      protectFromScaleSetActions: true
    }
  }
  dependsOn: [
    worker
  ]
}

output workerVmId string = worker.outputs.resourceId
output workerVmName string = virtualMachineName
output nicId string = resourceId('Microsoft.Network/networkInterfaces', networkInterfaceName)
output nicName string = networkInterfaceName
output osDiskId string = resourceId('Microsoft.Compute/disks', osDiskName)
output osDiskName string = osDiskName
output customScriptExtensionId string = workerCustomScript.id
output scaleSetInstanceId string = scaleSetInstanceId
output appliedTags object = tags
output workerResourceCounts object = {
  virtualMachines: 1
  networkInterfaces: 1
  managedDisks: 1
  diskTagResources: 1
  customScriptExtensions: 1
  flexInstanceProtectionResources: 1
  total: 6
}

resource workerOsDisk 'Microsoft.Compute/disks@2025-01-02' existing = {
  name: osDiskName
  dependsOn: [
    worker
  ]
}

resource workerOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  scope: workerOsDisk
  properties: {
    tags: tags
  }
  dependsOn: [
    worker
  ]
}
