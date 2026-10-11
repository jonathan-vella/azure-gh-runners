@description('Azure region for the isolated Windows runner network.')
param location string

@description('Address space of the isolated VNet. Must not overlap or peer with any other network.')
param addressSpace string

@description('Prefix of the worker subnet.')
param workerSubnetPrefix string

@description('Prefix of the subnet used while baking the Windows image.')
param buildSubnetPrefix string

@description('Short unique suffix for globally scoped names.')
param suffix string

@description('Governance tags.')
param tags object

var nsgName = 'nsg-ghrwin-worker-${suffix}'
var natGatewayName = 'nat-ghrwin-${suffix}'
var natGatewayPublicIpName = 'pip-ghrwin-${suffix}'
var virtualNetworkName = 'vnet-ghrwin-${suffix}'

// 168.63.129.16 is the Azure platform address (DNS, VM agent wire server); 169.254.169.254 is IMDS.
var securityRules = [
  {
    name: 'Deny-All-Inbound'
    properties: {
      access: 'Deny'
      description: 'Workers accept no inbound connections from any source, including the VNet and load balancers.'
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
    name: 'Allow-Azure-DNS'
    properties: {
      access: 'Allow'
      description: 'Azure-provided DNS only.'
      destinationAddressPrefix: '168.63.129.16'
      destinationPortRange: '53'
      direction: 'Outbound'
      priority: 100
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-Platform-Agent'
    properties: {
      access: 'Allow'
      description: 'Azure VM agent wire server.'
      destinationAddressPrefix: '168.63.129.16'
      destinationPortRanges: [
        '80'
        '32526'
      ]
      direction: 'Outbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Azure-IMDS'
    properties: {
      access: 'Allow'
      description: 'Instance metadata service used by the VM agent.'
      destinationAddressPrefix: '169.254.169.254'
      destinationPortRange: '80'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Internet-HTTPS'
    properties: {
      access: 'Allow'
      description: 'HTTPS egress through the NAT Gateway.'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '443'
      direction: 'Outbound'
      priority: 130
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Allow-Internet-HTTP'
    properties: {
      access: 'Allow'
      description: 'HTTP egress through the NAT Gateway (package feeds, certificate revocation).'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '80'
      direction: 'Outbound'
      priority: 140
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-10'
    properties: {
      access: 'Deny'
      description: 'No lateral movement or access to other private networks.'
      destinationAddressPrefix: '10.0.0.0/8'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-172'
    properties: {
      access: 'Deny'
      description: 'No lateral movement or access to other private networks.'
      destinationAddressPrefix: '172.16.0.0/12'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4001
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-RFC1918-192'
    properties: {
      access: 'Deny'
      description: 'No lateral movement or access to other private networks.'
      destinationAddressPrefix: '192.168.0.0/16'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4002
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
  {
    name: 'Deny-CGNAT-100-64'
    properties: {
      access: 'Deny'
      description: 'No access to shared address space.'
      destinationAddressPrefix: '100.64.0.0/10'
      destinationPortRange: '*'
      direction: 'Outbound'
      priority: 4003
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
    }
  }
]

module workerNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-${suffix}'
  params: {
    name: nsgName
    location: location
    securityRules: securityRules
    tags: tags
    enableTelemetry: false
  }
}

module natGatewayPublicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'nat-pip-${suffix}'
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
  name: 'nat-gateway-${suffix}'
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

// No peerings, no private DNS links and no private endpoints: the VNet is a closed island.
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-${suffix}'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      addressSpace
    ]
    subnets: [
      {
        name: 'snet-worker'
        addressPrefix: workerSubnetPrefix
        networkSecurityGroupResourceId: workerNsg.outputs.resourceId
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'snet-build'
        addressPrefix: buildSubnetPrefix
        networkSecurityGroupResourceId: workerNsg.outputs.resourceId
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId
output networkSecurityGroupResourceId string = workerNsg.outputs.resourceId
output workerSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[0]
output buildSubnetResourceId string = virtualNetwork.outputs.subnetResourceIds[1]
output natGatewayResourceId string = natGateway.outputs.resourceId
output natGatewayPublicIpResourceId string = natGatewayPublicIp.outputs.resourceId
output natGatewayPublicIpAddress string = natGatewayPublicIp.outputs.ipAddress
