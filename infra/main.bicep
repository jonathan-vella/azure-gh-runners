targetScope = 'resourceGroup'

var networkConfig = loadJsonContent('./network-config.json')
var diagnosticsConfig = loadJsonContent('./diagnostics-config.json')

module network './modules/network.bicep' = {
  name: 'network-${uniqueString(deployment().name, resourceGroup().id)}'
  params: {
    location: networkConfig.location
    networkConfig: networkConfig
  }
}

module observability './modules/observability.bicep' = {
  name: 'observability-${uniqueString(deployment().name, resourceGroup().id)}'
  params: {
    location: networkConfig.location
  }
}

module acaNsgDiagnostics './modules/diagnostic-settings.bicep' = {
  name: 'aca-nsg-diagnostics'
  params: {
    targetResourceId: network.outputs.acaNetworkSecurityGroupResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-aca-nsg'
    logCategories: diagnosticsConfig.networkSecurityGroup.logCategories
    enableAllMetrics: contains(diagnosticsConfig.networkSecurityGroup.metricCategories, 'AllMetrics')
  }
}

module acrAgentsNsgDiagnostics './modules/diagnostic-settings.bicep' = {
  name: 'acr-agents-nsg-diagnostics'
  params: {
    targetResourceId: network.outputs.acrAgentsNetworkSecurityGroupResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-acr-agents-nsg'
    logCategories: diagnosticsConfig.networkSecurityGroup.logCategories
    enableAllMetrics: contains(diagnosticsConfig.networkSecurityGroup.metricCategories, 'AllMetrics')
  }
}

module virtualNetworkDiagnostics './modules/diagnostic-settings.bicep' = {
  name: 'virtual-network-diagnostics'
  params: {
    targetResourceId: network.outputs.virtualNetworkResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-vnet'
    logCategories: diagnosticsConfig.virtualNetwork.logCategories
    enableAllMetrics: contains(diagnosticsConfig.virtualNetwork.metricCategories, 'AllMetrics')
  }
}

module natGatewayPublicIpDiagnostics './modules/diagnostic-settings.bicep' = {
  name: 'nat-public-ip-diagnostics'
  params: {
    targetResourceId: network.outputs.natGatewayPublicIpResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-nat-public-ip'
    logCategories: diagnosticsConfig.publicIpAddress.logCategories
    enableAllMetrics: contains(diagnosticsConfig.publicIpAddress.metricCategories, 'AllMetrics')
  }
}

output virtualNetworkResourceId string = network.outputs.virtualNetworkResourceId
output acaNetworkSecurityGroupResourceId string = network.outputs.acaNetworkSecurityGroupResourceId
output acrAgentsNetworkSecurityGroupResourceId string = network.outputs.acrAgentsNetworkSecurityGroupResourceId
output acaSubnetResourceId string = network.outputs.acaSubnetResourceId
output acrAgentsSubnetResourceId string = network.outputs.acrAgentsSubnetResourceId
output platformPrivateEndpointSubnetResourceId string = network.outputs.platformPrivateEndpointSubnetResourceId
output consumerPrivateEndpointSubnetResourceId string = network.outputs.consumerPrivateEndpointSubnetResourceId
output natGatewayResourceId string = network.outputs.natGatewayResourceId
output natGatewayPublicIpResourceId string = network.outputs.natGatewayPublicIpResourceId
output natGatewayPublicIpAddress string = network.outputs.natGatewayPublicIpAddress
output privateDnsZoneResourceIds array = network.outputs.privateDnsZoneResourceIds
output workspaceResourceId string = observability.outputs.workspaceResourceId
output workspaceCustomerId string = observability.outputs.workspaceCustomerId
