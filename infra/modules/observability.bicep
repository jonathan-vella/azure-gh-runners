@allowed([
  'swedencentral'
])
param location string = 'swedencentral'
param workspaceName string = 'law-ghrunners-prod-swc'

var governanceTags = {
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
}

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

@description('The Log Analytics workspace customer ID required by the Container Apps environment.')
output workspaceCustomerId string = logAnalyticsWorkspace.outputs.logAnalyticsWorkspaceId
