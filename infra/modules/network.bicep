@description('The approved Azure region for the shared runner platform.')
@allowed([
  'swedencentral'
])
param location string

@description('The validated address ranges, private DNS zones, and governance tags for the network.')
param networkConfig networkConfigType

var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 5)
var virtualNetworkName = 'vnet-ghrunners-prod-swc-${uniqueSuffix}'
var acaNsgName = 'nsg-ghrunners-aca-prod-swc-${uniqueSuffix}'
var acrAgentsNsgName = 'nsg-ghrunners-acr-agents-prod-swc-${uniqueSuffix}'
var natGatewayName = 'nat-ghrunners-prod-swc-${uniqueSuffix}'
var natGatewayPublicIpName = 'pip-ghrunners-prod-swc-${uniqueSuffix}'
var tags = union(networkConfig.governanceTags, {
  application: 'ghrunners'
  environment: 'prod'
  workload: 'gh-runners'
  owner: 'jonathan-vella'
  costcenter: 'platform-engineering'
  'tech-contact': 'jonathan-vella'
  'technical-contact': 'jonathan-vella'
  sla: 'development'
  'backup-policy': 'none'
  'maint-window': 'none'
})

var acaSecurityRules = [
  {
    name: 'Allow-ACA-Load-Balancer-Probes'
    properties: {
      access: 'Allow'
      description: 'Required for Container Apps workload-profile infrastructure health probes.'
      destinationAddressPrefix: networkConfig.subnets.aca
      destinationPortRange: '30000-32767'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-Other-Inbound'
    properties: {
      access: 'Deny'
      description: 'Runner jobs do not accept inbound connections.'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      direction: 'Inbound'
      priority: 4096
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-ACA-Subnet-Dependencies'
    properties: {
      access: 'Allow'
      description: 'Required for communication between Container Apps environment IPs in its dedicated subnet.'
      destinationAddressPrefix: networkConfig.subnets.aca
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 100
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Private-Endpoints-HTTPS'
    properties: {
      access: 'Allow'
      description: 'Allow HTTPS only to platform and consumer private endpoint subnets.'
      destinationAddressPrefixes: [
        networkConfig.subnets.privateEndpoints
        networkConfig.subnets.consumerPrivateEndpoints
      ]
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Internet-HTTPS'
    properties: {
      access: 'Allow'
      description: 'Permit documented HTTPS egress; subnet NAT supplies the static egress address.'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Microsoft-Container-Registry'
    properties: {
      access: 'Allow'
      description: 'Required for Container Apps system container images.'
      destinationAddressPrefix: 'MicrosoftContainerRegistry'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 130
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Front-Door-First-Party'
    properties: {
      access: 'Allow'
      description: 'Microsoft Container Registry service dependency.'
      destinationAddressPrefix: 'AzureFrontDoor.FirstParty'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 140
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Active-Directory'
    properties: {
      access: 'Allow'
      description: 'Required for Azure managed identity dependencies.'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 150
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Monitor'
    properties: {
      access: 'Allow'
      description: 'Allow HTTPS telemetry and monitoring egress.'
      destinationAddressPrefix: 'AzureMonitor'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 160
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-10'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '10.0.0.0/8'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-172'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '172.16.0.0/12'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4001
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-192'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '192.168.0.0/16'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4002
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.aca
      sourcePortRange: '*'
    }
  }
]

var acrAgentsSecurityRules = [
  {
    name: 'Deny-Other-Inbound'
    properties: {
      access: 'Deny'
      description: 'Agent-pool operations do not require inbound connections.'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      direction: 'Inbound'
      priority: 4096
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Private-Endpoints-HTTPS'
    properties: {
      access: 'Allow'
      description: 'Allow HTTPS only to platform and consumer private endpoint subnets.'
      destinationAddressPrefixes: [
        networkConfig.subnets.privateEndpoints
        networkConfig.subnets.consumerPrivateEndpoints
      ]
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Internet-HTTPS'
    properties: {
      access: 'Allow'
      description: 'Permit external registry HTTPS; subnet NAT supplies the static egress address.'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Key-Vault'
    properties: {
      access: 'Allow'
      description: 'Required ACR agent-pool service dependency.'
      destinationAddressPrefix: 'AzureKeyVault'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Storage'
    properties: {
      access: 'Allow'
      description: 'Required ACR agent-pool service dependency.'
      destinationAddressPrefix: 'Storage'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 130
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Event-Hub'
    properties: {
      access: 'Allow'
      description: 'Required ACR agent-pool service dependency.'
      destinationAddressPrefix: 'EventHub'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 140
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Active-Directory'
    properties: {
      access: 'Allow'
      description: 'Required ACR agent-pool service dependency.'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 150
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Monitor'
    properties: {
      access: 'Allow'
      description: 'Required ACR agent-pool diagnostics dependency, including its unique diagnostics port.'
      destinationAddressPrefix: 'AzureMonitor'
      destinationPortRanges: [
        '443'
        '12000'
      ]
      direction: 'Outbound'
      priority: 160
      protocol: 'Tcp'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-10'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '10.0.0.0/8'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-172'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '172.16.0.0/12'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4001
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-192'
    properties: {
      access: 'Deny'
      description: 'Deny lateral access outside the explicit subnet and private endpoint exceptions.'
      destinationAddressPrefix: '192.168.0.0/16'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4002
      protocol: '*'
      sourceAddressPrefix: networkConfig.subnets.acrAgents
      sourcePortRange: '*'
    }
  }
]

module acaNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'aca-nsg-${uniqueSuffix}'
  params: {
    name: acaNsgName
    location: location
    securityRules: acaSecurityRules
    tags: tags
    enableTelemetry: false
  }
}

module acrAgentsNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'acr-agents-nsg-${uniqueSuffix}'
  params: {
    name: acrAgentsNsgName
    location: location
    securityRules: acrAgentsSecurityRules
    tags: tags
    enableTelemetry: false
  }
}

module natGatewayPublicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'nat-pip-${uniqueSuffix}'
  params: {
    name: natGatewayPublicIpName
    location: location
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    skuName: 'Standard'
    availabilityZones: [
      1
      2
      3
    ]
    tags: tags
    enableTelemetry: false
  }
}

module natGateway 'br/public:avm/res/network/nat-gateway:2.1.1' = {
  name: 'nat-gateway-${uniqueSuffix}'
  params: {
    name: natGatewayName
    location: location
    availabilityZone: -1
    natGatewaySku: 'Standard'
    publicIpResourceIds: [
      natGatewayPublicIp.outputs.resourceId
    ]
    tags: tags
    enableTelemetry: false
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'virtual-network-${uniqueSuffix}'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      networkConfig.addressSpace
    ]
    subnets: [
      {
        name: 'snet-aca'
        addressPrefix: networkConfig.subnets.aca
        delegation: 'Microsoft.App/environments'
        networkSecurityGroupResourceId: acaNsg.outputs.resourceId
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'snet-acr-agents'
        addressPrefix: networkConfig.subnets.acrAgents
        networkSecurityGroupResourceId: acrAgentsNsg.outputs.resourceId
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'snet-pe'
        addressPrefix: networkConfig.subnets.privateEndpoints
        defaultOutboundAccess: false
      }
      {
        name: 'snet-consumer-pe'
        addressPrefix: networkConfig.subnets.consumerPrivateEndpoints
        defaultOutboundAccess: false
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module privateDnsZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for (zone, index) in networkConfig.privateDnsZones: {
    name: 'private-dns-${index}-${uniqueSuffix}'
    params: {
      name: zone
      virtualNetworkLinks: [
        {
          name: 'vnetlink-${uniqueSuffix}'
          virtualNetworkResourceId: virtualNetwork.outputs.resourceId
          registrationEnabled: false
          tags: tags
        }
      ]
      tags: tags
      enableTelemetry: false
    }
  }
]

output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId
output acaSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[0]
output acrAgentsSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[1]
output platformPrivateEndpointSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[2]
output consumerPrivateEndpointSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[3]
output natGatewayResourceId string = natGateway.outputs.resourceId
output natGatewayPublicIpResourceId string = natGatewayPublicIp.outputs.resourceId
output natGatewayPublicIpAddress string = natGatewayPublicIp.outputs.ipAddress
output privateDnsZoneResourceIds array = [
  for (zone, index) in networkConfig.privateDnsZones: {
    name: zone
    resourceId: privateDnsZones[index].outputs.resourceId
  }
]

@export()
type networkConfigType = {
  location: string
  addressSpace: string
  subnets: {
    aca: string
    acrAgents: string
    privateEndpoints: string
    consumerPrivateEndpoints: string
  }
  privateDnsZones: string[]
  governanceTags: object
  subscriptionId: string
  resourceGroup: string
}
