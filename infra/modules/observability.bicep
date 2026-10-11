@allowed([
  'swedencentral'
])
param location string = 'swedencentral'
param workspaceName string = 'law-ghrunners-prod-swc'

@description('Governance tags, sourced from infra/network-config.json.')
param governanceTags object

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-analytics-workspace'
  params: {
    name: workspaceName
    location: location
    features: {
      disableLocalAuth: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    tags: governanceTags
    enableTelemetry: false
  }
}

@description('The Log Analytics workspace resource ID, for use as a diagnostic-settings destination.')
output workspaceResourceId string = logAnalyticsWorkspace.outputs.resourceId

@description('The non-secret Log Analytics workspace customer ID.')
output workspaceCustomerId string = logAnalyticsWorkspace.outputs.logAnalyticsWorkspaceId
