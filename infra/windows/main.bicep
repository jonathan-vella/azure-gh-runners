targetScope = 'resourceGroup'

// Isolated Windows runner backend (ADR-0007). Deploys into its own resource group, with its own VNet.
// Nothing here is peered, linked or connected to the Linux ACA platform.

@description('Azure region.')
param location string = 'swedencentral'

@description('Short region code used in resource names.')
param regionShort string = 'swc'

@description('Address space of the isolated VNet. Must not overlap with, and is never peered to, any other network.')
param addressSpace string = '10.61.0.0/24'

@description('Worker subnet prefix inside the address space.')
param workerSubnetPrefix string = '10.61.0.0/25'

@description('Image-bake subnet prefix inside the address space.')
param buildSubnetPrefix string = '10.61.0.128/26'

@description('Azure Compute Gallery name.')
param galleryName string = 'gal_ghrunners_win_swc'

@description('Image definition name. The image bake publishes versions into it.')
param imageDefinitionName string = 'ghr-windows-2025'

@description('Governance tags applied to every resource.')
param tags object = {
  application: 'ghrunners'
  environment: 'prod'
  workload: 'gh-runners-windows'
  owner: 'platform-team'
  costcenter: 'platform-engineering'
  'tech-contact': 'platform-team'
  'technical-contact': 'platform-team'
  sla: 'development'
  'backup-policy': 'none'
  'maint-window': 'none'
}

@description('Deploy one orchestrator ACA job per Windows consumer. Requires an imported orchestrator image digest.')
param deployJobs bool = false

@secure()
@description('GitHub App private key. Stored only as an ACA secret on the orchestrator jobs.')
param githubAppPrivateKey string

@description('GitHub App ID; not a secret.')
param githubAppId string = ''

@description('GitHub App installation ID; not a secret.')
param githubAppInstallationId string = ''

@description('ACR digest (sha256:...) of the imported orchestrator image.')
param orchestratorImageDigest string = ''

@description('Monthly cost budget in the billing currency; 0 disables it. A budget only alerts, it never stops spending.')
@minValue(0)
param budgetAmount int = 0

@description('Recipients for budget alerts. Required when budgetAmount is greater than zero.')
param budgetContactEmails array = []

@description('First day of the budget month (yyyy-MM-01).')
param budgetStartDate string = utcNow('yyyy-MM-01')

var consumers = loadJsonContent('../generated/windows-consumers.json')
var diagnosticsConfig = loadJsonContent('../diagnostics-config.json')
var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 5)
var nameSuffix = 'prod-${regionShort}-${uniqueSuffix}'
var deploymentSuffix = uniqueString(deployment().name, resourceGroup().id)
var vmssName = 'vmss-ghrwin-prod-${regionShort}'

var orchestratorIdentityName = 'id-ghrwin-orchestrator-${nameSuffix}'

// Built-in role definition IDs, deliberately not Contributor.
var virtualMachineContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

module network './modules/network.bicep' = {
  name: 'network-${deploymentSuffix}'
  params: {
    location: location
    addressSpace: addressSpace
    workerSubnetPrefix: workerSubnetPrefix
    buildSubnetPrefix: buildSubnetPrefix
    suffix: nameSuffix
    tags: tags
  }
}

module compute './modules/compute.bicep' = {
  name: 'compute-${deploymentSuffix}'
  params: {
    location: location
    galleryName: galleryName
    imageDefinitionName: imageDefinitionName
    vmssName: vmssName
    tags: tags
  }
}

// Standard Log Analytics ingestion; local authentication is disabled and Azure RBAC governs access.
module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'workspace-${deploymentSuffix}'
  params: {
    name: 'law-ghrwin-${nameSuffix}'
    location: location
    features: {
      disableLocalAuth: true
    }
    tags: tags
    enableTelemetry: false
  }
}

// zoneRedundant must stay false: the AVM default is true and caused capacity failures in swedencentral.
// No VNet integration and no ingress: jobs only make outbound calls to GitHub and Azure Resource Manager.
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'aca-environment-${deploymentSuffix}'
  params: {
    name: 'cae-ghrwin-${nameSuffix}'
    location: location
    zoneRedundant: false
    publicNetworkAccess: 'Enabled'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    tags: tags
    enableTelemetry: false
  }
}

module containerAppsEnvironmentDiagnostics '../modules/diagnostic-settings.bicep' = {
  name: 'aca-environment-diagnostics-${deploymentSuffix}'
  params: {
    targetResourceId: containerAppsEnvironment.outputs.resourceId
    workspaceResourceId: workspace.outputs.resourceId
    name: 'diag-aca-environment'
    logCategories: diagnosticsConfig.containerAppsEnvironment.logCategories
    enableAllMetrics: contains(diagnosticsConfig.containerAppsEnvironment.metricCategories, 'AllMetrics')
  }
}

module orchestratorIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'orchestrator-identity-${deploymentSuffix}'
  params: {
    name: orchestratorIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

// Basic SKU has no private-link or network-rule support, so it is public by design; it holds only
// the orchestrator image, which contains no secrets.
module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: 'registry-${deploymentSuffix}'
  params: {
    name: 'crghrwin${regionShort}${uniqueSuffix}'
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'AcrPull'
        principalId: orchestratorIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

resource virtualMachineContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, orchestratorIdentityName, virtualMachineContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleId)
    principalId: orchestratorIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource networkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, orchestratorIdentityName, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: orchestratorIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

module orchestratorJobs './modules/orchestrator-job.bicep' = [
  for consumer in consumers: if (deployJobs) {
    name: 'orchestrator-job-${consumer.name}-${deploymentSuffix}'
    params: {
      location: location
      consumer: consumer
      environmentResourceId: containerAppsEnvironment.outputs.resourceId
      identityResourceId: orchestratorIdentity.outputs.resourceId
      identityClientId: orchestratorIdentity.outputs.clientId
      registryServer: registry.outputs.loginServer
      orchestratorImage: '${registry.outputs.loginServer}/windows-orchestrator@${orchestratorImageDigest}'
      githubAppPrivateKey: githubAppPrivateKey
      githubAppId: githubAppId
      githubAppInstallationId: githubAppInstallationId
      workerResourceGroupName: resourceGroup().name
      vmssName: compute.outputs.vmssName
      imageDefinitionResourceId: compute.outputs.imageDefinitionResourceId
      workerSubnetResourceId: network.outputs.workerSubnetResourceId
      tags: tags
    }
    dependsOn: [
      virtualMachineContributor
      networkContributor
    ]
  }
]

module budget './modules/budget.bicep' = if (budgetAmount > 0 && !empty(budgetContactEmails)) {
  name: 'budget-${deploymentSuffix}'
  params: {
    amount: max(budgetAmount, 1)
    budgetName: 'budget-ghrwin-${nameSuffix}'
    startDate: budgetStartDate
    contactEmails: budgetContactEmails
  }
}

output virtualNetworkResourceId string = network.outputs.virtualNetworkResourceId
output networkSecurityGroupResourceId string = network.outputs.networkSecurityGroupResourceId
output workerSubnetResourceId string = network.outputs.workerSubnetResourceId
output buildSubnetResourceId string = network.outputs.buildSubnetResourceId
output natGatewayPublicIpResourceId string = network.outputs.natGatewayPublicIpResourceId
output natGatewayPublicIpAddress string = network.outputs.natGatewayPublicIpAddress
output galleryResourceId string = compute.outputs.galleryResourceId
output imageDefinitionResourceId string = compute.outputs.imageDefinitionResourceId
output vmssResourceId string = compute.outputs.vmssResourceId
output containerAppsEnvironmentResourceId string = containerAppsEnvironment.outputs.resourceId
output workspaceResourceId string = workspace.outputs.resourceId
output orchestratorIdentityResourceId string = orchestratorIdentity.outputs.resourceId
output orchestratorIdentityPrincipalId string = orchestratorIdentity.outputs.principalId
output registryName string = registry.outputs.name
output registryLoginServer string = registry.outputs.loginServer
output windowsJobNames array = deployJobs ? map(consumers, consumer => 'caj-ghrw-${consumer.name}') : []
output budgetEnabled bool = budgetAmount > 0 && !empty(budgetContactEmails)
