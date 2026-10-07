targetScope = 'resourceGroup'

@description('Enable diagnostic settings only after live categories have been checked for all deployed target resource IDs.')
param enableDiagnostics bool = false

var networkConfig = loadJsonContent('./network-config.json')
var diagnosticsConfig = loadJsonContent('./diagnostics-config.json')
var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 5)

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

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'aca-environment-${uniqueString(deployment().name, resourceGroup().id)}'
  params: {
    name: 'cae-ghrunners-prod-swc-${uniqueSuffix}'
    location: networkConfig.location
    internal: true
    publicNetworkAccess: 'Disabled'
    infrastructureSubnetResourceId: network.outputs.acaSubnetResourceId
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
        minimumCount: 0
        maximumCount: 1
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    tags: networkConfig.governanceTags
    enableTelemetry: false
  }
}

module acaNsgDiagnostics './modules/diagnostic-settings.bicep' = if (enableDiagnostics) {
  name: 'aca-nsg-diagnostics'
  params: {
    targetResourceId: network.outputs.acaNetworkSecurityGroupResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-aca-nsg'
    logCategories: diagnosticsConfig.networkSecurityGroup.logCategories
    enableAllMetrics: contains(diagnosticsConfig.networkSecurityGroup.metricCategories, 'AllMetrics')
  }
}

module containerAppsEnvironmentDiagnostics './modules/diagnostic-settings.bicep' = if (enableDiagnostics) {
  name: 'aca-environment-diagnostics'
  params: {
    targetResourceId: containerAppsEnvironment.outputs.resourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-aca-environment'
    logCategories: diagnosticsConfig.containerAppsEnvironment.logCategories
    enableAllMetrics: contains(diagnosticsConfig.containerAppsEnvironment.metricCategories, 'AllMetrics')
  }
}

module acrAgentsNsgDiagnostics './modules/diagnostic-settings.bicep' = if (enableDiagnostics) {
  name: 'acr-agents-nsg-diagnostics'
  params: {
    targetResourceId: network.outputs.acrAgentsNetworkSecurityGroupResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-acr-agents-nsg'
    logCategories: diagnosticsConfig.networkSecurityGroup.logCategories
    enableAllMetrics: contains(diagnosticsConfig.networkSecurityGroup.metricCategories, 'AllMetrics')
  }
}

module virtualNetworkDiagnostics './modules/diagnostic-settings.bicep' = if (enableDiagnostics) {
  name: 'virtual-network-diagnostics'
  params: {
    targetResourceId: network.outputs.virtualNetworkResourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-vnet'
    logCategories: diagnosticsConfig.virtualNetwork.logCategories
    enableAllMetrics: contains(diagnosticsConfig.virtualNetwork.metricCategories, 'AllMetrics')
  }
}

module natGatewayPublicIpDiagnostics './modules/diagnostic-settings.bicep' = if (enableDiagnostics) {
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
output containerAppsEnvironmentResourceId string = containerAppsEnvironment.outputs.resourceId
output workspaceResourceId string = observability.outputs.workspaceResourceId
output workspaceCustomerId string = observability.outputs.workspaceCustomerId
output diagnosticsEnabled bool = enableDiagnostics
