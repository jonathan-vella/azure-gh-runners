targetScope = 'resourceGroup'

var networkConfig = loadJsonContent('./network-config.json')

module network './modules/network.bicep' = {
  name: 'network-${uniqueString(deployment().name, resourceGroup().id)}'
  params: {
    location: networkConfig.location
    networkConfig: networkConfig
  }
}

output virtualNetworkResourceId string = network.outputs.virtualNetworkResourceId
output acaSubnetResourceId string = network.outputs.acaSubnetResourceId
output acrAgentsSubnetResourceId string = network.outputs.acrAgentsSubnetResourceId
output platformPrivateEndpointSubnetResourceId string = network.outputs.platformPrivateEndpointSubnetResourceId
output consumerPrivateEndpointSubnetResourceId string = network.outputs.consumerPrivateEndpointSubnetResourceId
output natGatewayResourceId string = network.outputs.natGatewayResourceId
output natGatewayPublicIpResourceId string = network.outputs.natGatewayPublicIpResourceId
output natGatewayPublicIpAddress string = network.outputs.natGatewayPublicIpAddress
output privateDnsZoneResourceIds array = network.outputs.privateDnsZoneResourceIds
