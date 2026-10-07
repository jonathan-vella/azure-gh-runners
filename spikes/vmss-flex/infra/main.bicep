targetScope = 'resourceGroup'

@description('Non-secret 32-character lowercase hexadecimal spike run ID.')
@minLength(32)
@maxLength(32)
param runId string

@description('Reviewed 40-character source commit SHA for ownership tags.')
@minLength(40)
@maxLength(40)
param head string

@description('Exact Canonical Ubuntu 24.04 Marketplace version verified for Sweden Central immediately before an authorized deployment. "latest" is rejected at deployment evaluation.')
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
var approvedScopeIndex = (subscription().subscriptionId == approvedSubscriptionId && tenant().tenantId == approvedTenantId && resourceGroup().name == approvedResourceGroupName) ? 0 : 1
var approvedScope = approvedScopeValues[approvedScopeIndex]
var virtualNetworkName = 'vnet-ghrunners-spike60-swc'
var controllerSubnetName = 'snet-ghrunners-controller'
var workerSubnetName = 'snet-ghrunners-workers'
var privateEndpointSubnetName = 'snet-ghrunners-pe'
var controllerNsgName = 'nsg-ghrunners-controller'
var workerNsgName = 'nsg-ghrunners-workers'
var privateEndpointNsgName = 'nsg-ghrunners-pe'
var natGatewayName = 'nat-ghrunners-spike60-swc'
var natPublicIpName = 'pip-ghrunners-spike60-swc'
var privateDnsZoneName = 'privatelink.vaultcore.azure.net'
var keyVaultName = 'kv-ghr-spike60-swc'
var keyVaultPrivateEndpointName = 'pe-kv-ghr-spike60-swc'
var flexScaleSetName = 'vmss-ghr-spike60-swc'
var controllerVmName = 'vm-ghr-spike60-controller'
var controllerNicName = 'nic-ghr-spike60-controller'
var controllerOsDiskName = 'disk-ghr-spike60-controller-os'
var controllerSubnetPrefix = '10.61.60.0/27'
var workerSubnetPrefix = '10.61.60.32/27'
var privateEndpointSubnetPrefix = '10.61.60.64/27'

// A one-element array indexed with a runtime expression makes an unpinned Marketplace version fail closed.
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
  'deployment-scope': approvedScope
}

module controllerNsg 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'controller-nsg'
  params: {
    name: controllerNsgName
    location: location
    enableTelemetry: false
    tags: tags
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowDnsToPlatform'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzurePlatformDNS'
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowKeyVaultPrivateEndpointHttps'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyWorkerSubnet'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: workerSubnetPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowHttpsEgress'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

module workerNsg 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'worker-nsg'
  params: {
    name: workerNsgName
    location: location
    enableTelemetry: false
    tags: tags
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyPrivateEndpointSubnet'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyControllerSubnet'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: controllerSubnetPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowDnsToPlatform'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzurePlatformDNS'
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowHttpsEgress'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

module privateEndpointNsg 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'private-endpoint-nsg'
  params: {
    name: privateEndpointNsgName
    location: location
    enableTelemetry: false
    tags: tags
    securityRules: [
      {
        name: 'AllowControllerHttps'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: controllerSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyWorkerSubnet'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: workerSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

module natGateway 'br/public:avm/res/network/nat-gateway:2.1.0' = {
  name: 'outbound-nat'
  params: {
    name: natGatewayName
    location: location
    availabilityZone: -1
    natGatewaySku: 'Standard'
    publicIPAddresses: [
      {
        name: natPublicIpName
        skuName: 'Standard'
        tags: tags
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.0' = {
  name: 'private-network'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      '10.61.60.0/24'
    ]
    enableTelemetry: false
    tags: tags
    subnets: [
      {
        name: controllerSubnetName
        addressPrefix: controllerSubnetPrefix
        networkSecurityGroupResourceId: resourceId('Microsoft.Network/networkSecurityGroups', controllerNsgName)
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: workerSubnetName
        addressPrefix: workerSubnetPrefix
        networkSecurityGroupResourceId: resourceId('Microsoft.Network/networkSecurityGroups', workerNsgName)
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetPrefix
        networkSecurityGroupResourceId: resourceId(
          'Microsoft.Network/networkSecurityGroups',
          privateEndpointNsgName
        )
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
      }
    ]
  }
  dependsOn: [
    controllerNsg
    workerNsg
    privateEndpointNsg
  ]
}

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'key-vault-private-dns'
  params: {
    name: privateDnsZoneName
    location: 'global'
    virtualNetworkLinks: [
      {
        name: 'vnet-ghrunners-spike60-swc-link'
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: false
        tags: tags
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.14.0' = {
  name: 'private-key-vault'
  params: {
    name: keyVaultName
    location: location
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: false
    softDeleteRetentionInDays: 7
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    privateEndpoints: [
      {
        name: keyVaultPrivateEndpointName
        subnetResourceId: resourceId(
          'Microsoft.Network/virtualNetworks/subnets',
          virtualNetworkName,
          privateEndpointSubnetName
        )
        service: 'vault'
        privateDnsZoneGroup: {
          name: 'default'
          privateDnsZoneGroupConfigs: [
            {
              name: 'key-vault'
              privateDnsZoneResourceId: privateDnsZone.outputs.resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    secrets: [
      {
        name: 'github-app-private-key'
        value: githubAppPrivateKey
        contentType: 'application/vnd.microsoft.app'
        tags: tags
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module controller 'br/public:avm/res/compute/virtual-machine:0.22.0' = {
  name: 'private-controller'
  params: {
    name: controllerVmName
    computerName: controllerVmName
    location: location
    vmSize: 'Standard_B2s'
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: '0001-com-ubuntu-server-noble'
      sku: '24_04-lts-gen2'
      version: pinnedCanonicalUbuntuVersion
    }
    osDisk: {
      name: controllerOsDiskName
      diskSizeGB: 32
      createOption: 'FromImage'
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    adminUsername: 'ghrcontroller'
    disablePasswordAuthentication: true
    publicKeys: [
      {
        path: '/home/ghrcontroller/.ssh/authorized_keys'
        keyData: adminSshPublicKey
      }
    ]
    customData: controllerBootstrapCustomData
    managedIdentities: {
      systemAssigned: true
    }
    nicConfigurations: [
      {
        name: controllerNicName
        nicSuffix: 'controller'
        networkSecurityGroupResourceId: resourceId(
          'Microsoft.Network/networkSecurityGroups',
          controllerNsgName
        )
        tags: tags
        ipConfigurations: [
          {
            name: 'ipconfig-controller'
            subnetResourceId: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
              virtualNetworkName,
              controllerSubnetName
            )
          }
        ]
      }
    ]
    availabilityZone: -1
    enableTelemetry: false
    tags: tags
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource controllerOsDisk 'Microsoft.Compute/disks@2025-01-02' existing = {
  name: controllerOsDiskName
  dependsOn: [
    controller
  ]
}

resource controllerOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  scope: controllerOsDisk
  properties: {
    tags: tags
  }
  dependsOn: [
    controller
  ]
}

// This is deliberately a raw, zero-capacity Flex shell: the pinned AVM scale-set module requires an image/profile
// and does not expose the empty-set-plus-scheduled-event contract needed for individually created AVM VMs.
resource flexScaleSet 'Microsoft.Compute/virtualMachineScaleSets@2024-11-01' = {
  name: flexScaleSetName
  location: location
  sku: {
    name: 'Standard_D2ls_v5'
    tier: 'Standard'
    capacity: 0
  }
  properties: {
    orchestrationMode: 'Flexible'
    platformFaultDomainCount: 1
    overprovision: false
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      scheduledEventsProfile: {
        terminateNotificationProfile: {
          enable: true
          notBeforeTimeout: 'PT5M'
        }
      }
    }
  }
  tags: tags
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2025-05-01' existing = {
  name: natPublicIpName
}

output location string = location
output virtualNetworkId string = virtualNetwork.outputs.resourceId
output controllerSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  controllerSubnetName
)
output workerSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  workerSubnetName
)
output privateEndpointSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  privateEndpointSubnetName
)
output controllerVmId string = controller.outputs.resourceId
output controllerNicId string = resourceId('Microsoft.Network/networkInterfaces', controllerNicName)
output controllerOsDiskId string = resourceId('Microsoft.Compute/disks', controllerOsDiskName)
output controllerManagedIdentityPrincipalId string = controller.outputs.systemAssignedMIPrincipalId!
output controllerPrincipalId string = controller.outputs.systemAssignedMIPrincipalId!
output flexScaleSetId string = flexScaleSet.id
output flexScaleSetResourceId string = flexScaleSet.id
output workerSubnetResourceId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  workerSubnetName
)
output keyVaultId string = keyVault.outputs.resourceId
output keyVaultPrivateEndpointId string = keyVault.outputs.privateEndpoints[0].resourceId
output keyVaultSecretId string = keyVault.outputs.secrets[0].resourceId
output keyVaultSecretVersionUri string = keyVault.outputs.secrets[0].uriWithVersion
output secretVersionUri string = keyVault.outputs.secrets[0].uriWithVersion
output natGatewayId string = natGateway.outputs.resourceId
output natPublicIpId string = natPublicIp.id
output natPublicIpAddress string = natPublicIp.properties.ipAddress

// Budget inventory: this template owns 20 Azure resources, including all module-created subnet, PE, DNS-link,
// secret, and NAT-PIP resources. It has no storage smoke target, Log Analytics workspace, role assignment, or worker.
output foundationResourceCounts object = {
  networkSecurityGroups: 3
  virtualNetworks: 1
  subnets: 3
  natGateways: 1
  publicIpAddresses: 1
  privateDnsZones: 1
  privateDnsZoneVirtualNetworkLinks: 1
  keyVaults: 1
  keyVaultSecrets: 1
  privateEndpoints: 1
  privateDnsZoneGroups: 1
  virtualMachineScaleSets: 1
  virtualMachines: 1
  networkInterfaces: 1
  managedDisks: 1
  diskTagResources: 1
  total: 20
}
