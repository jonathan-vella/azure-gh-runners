targetScope = 'resourceGroup'

param location string = resourceGroup().location
param expiry string
param subnetId string

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
  project: 'azure-gh-runners'
  issue: '9'
  purpose: 'init-container-secret-isolation-spike'
  expiresOn: expiry
}

resource acaEnvironment 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: 'ghr9-env'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: subnetId
      internal: true
    }
    publicNetworkAccess: 'Disabled'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output environmentId string = acaEnvironment.id
