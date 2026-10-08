targetScope = 'resourceGroup'

@description('Enable the optional network diagnostic-settings matrix only after live categories have been checked.')
param enableDiagnostics bool = false

@description('Deploy one ACA runner job per registered consumer. Requires imported image digests.')
param deployJobs bool = false

@secure()
@description('GitHub App private key stored in Key Vault for the KEDA scaler and the JIT init container.')
param githubAppPrivateKey string

@description('GitHub App ID; not a secret.')
param githubAppId string = ''

@description('GitHub App installation ID; not a secret.')
param githubAppInstallationId string = ''

@description('ACR digest (sha256:...) of the imported jit-init image.')
param jitInitImageDigest string = ''

@description('ACR digest (sha256:...) of the imported runner image.')
param runnerImageDigest string = ''

var networkConfig = loadJsonContent('./network-config.json')
var diagnosticsConfig = loadJsonContent('./diagnostics-config.json')
var consumers = loadJsonContent('./generated/consumers.json').parameters.consumers.value
var location = networkConfig.location
var tags = networkConfig.governanceTags
var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 5)
var deploymentSuffix = uniqueString(deployment().name, resourceGroup().id)
var appKeySecretName = 'github-app-private-key'

module network './modules/network.bicep' = {
  name: 'network-${deploymentSuffix}'
  params: {
    location: location
    networkConfig: networkConfig
  }
}

var privateDnsZones = network.outputs.privateDnsZoneResourceIds

module observability './modules/observability.bicep' = {
  name: 'observability-${deploymentSuffix}'
  params: {
    location: location
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'aca-environment-${deploymentSuffix}'
  params: {
    name: 'cae-ghrunners-prod-swc-${uniqueSuffix}'
    location: location
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
    tags: tags
    enableTelemetry: false
  }
}

module containerAppsEnvironmentDiagnostics './modules/diagnostic-settings.bicep' = {
  name: 'aca-environment-diagnostics'
  params: {
    targetResourceId: containerAppsEnvironment.outputs.resourceId
    workspaceResourceId: observability.outputs.workspaceResourceId
    name: 'diag-aca-environment'
    logCategories: diagnosticsConfig.containerAppsEnvironment.logCategories
    enableAllMetrics: contains(diagnosticsConfig.containerAppsEnvironment.metricCategories, 'AllMetrics')
  }
}

module runnerIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'runner-identity-${deploymentSuffix}'
  params: {
    name: 'id-ghrunners-prod-swc-${uniqueSuffix}'
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: 'registry-${deploymentSuffix}'
  params: {
    name: 'crghrunnersprodswc${uniqueSuffix}'
    location: location
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    privateEndpoints: [
      {
        name: 'pe-cr-ghrunners-prod-swc-${uniqueSuffix}'
        service: 'registry'
        subnetResourceId: network.outputs.platformPrivateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: filter(privateDnsZones, zone => zone.name == 'privatelink.azurecr.io')[0].resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'AcrPull'
        principalId: runnerIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'key-vault-${deploymentSuffix}'
  params: {
    name: 'kv-ghr-prod-swc-${uniqueSuffix}'
    location: location
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: false
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    privateEndpoints: [
      {
        name: 'pe-kv-ghr-prod-swc-${uniqueSuffix}'
        service: 'vault'
        subnetResourceId: network.outputs.platformPrivateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: filter(privateDnsZones, zone => zone.name == 'privatelink.vaultcore.azure.net')[0].resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    secrets: [
      {
        name: appKeySecretName
        value: githubAppPrivateKey
        contentType: 'application/x-pem-file'
        roleAssignments: [
          {
            roleDefinitionIdOrName: 'Key Vault Secrets User'
            principalId: runnerIdentity.outputs.principalId
            principalType: 'ServicePrincipal'
          }
        ]
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module smokeStorage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'smoke-storage-${deploymentSuffix}'
  params: {
    name: 'stghrsmoke${uniqueSuffix}'
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
    blobServices: {
      containers: [
        {
          name: 'smoke'
          publicAccess: 'Container'
        }
      ]
    }
    privateEndpoints: [
      {
        name: 'pe-st-ghrsmoke-prod-swc-${uniqueSuffix}'
        service: 'blob'
        subnetResourceId: network.outputs.consumerPrivateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: filter(privateDnsZones, zone => zone.name == 'privatelink.blob.${environment().suffixes.storage}')[0].resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module runnerJobs './modules/runner-job.bicep' = [
  for consumer in consumers: if (deployJobs) {
    name: 'runner-job-${consumer.name}-${deploymentSuffix}'
    params: {
      location: location
      consumer: consumer
      environmentResourceId: containerAppsEnvironment.outputs.resourceId
      identityResourceId: runnerIdentity.outputs.resourceId
      registryServer: registry.outputs.loginServer
      jitInitImage: '${registry.outputs.loginServer}/jit-init@${jitInitImageDigest}'
      runnerImage: '${registry.outputs.loginServer}/runner@${runnerImageDigest}'
      appKeySecretUrl: '${keyVault.outputs.uri}secrets/${appKeySecretName}'
      githubAppId: githubAppId
      githubAppInstallationId: githubAppInstallationId
      tags: tags
    }
  }
]

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
output acaSubnetResourceId string = network.outputs.acaSubnetResourceId
output platformPrivateEndpointSubnetResourceId string = network.outputs.platformPrivateEndpointSubnetResourceId
output consumerPrivateEndpointSubnetResourceId string = network.outputs.consumerPrivateEndpointSubnetResourceId
output natGatewayResourceId string = network.outputs.natGatewayResourceId
output natGatewayPublicIpResourceId string = network.outputs.natGatewayPublicIpResourceId
output natGatewayPublicIpAddress string = network.outputs.natGatewayPublicIpAddress
output privateDnsZoneResourceIds array = network.outputs.privateDnsZoneResourceIds
output containerAppsEnvironmentResourceId string = containerAppsEnvironment.outputs.resourceId
output containerAppsEnvironmentName string = containerAppsEnvironment.outputs.name
output workspaceResourceId string = observability.outputs.workspaceResourceId
output workspaceCustomerId string = observability.outputs.workspaceCustomerId
output runnerIdentityResourceId string = runnerIdentity.outputs.resourceId
output registryName string = registry.outputs.name
output registryLoginServer string = registry.outputs.loginServer
output keyVaultName string = keyVault.outputs.name
output smokeStorageAccountName string = smokeStorage.outputs.name
output runnerJobNames array = deployJobs ? map(consumers, consumer => 'caj-ghr-${consumer.name}') : []
output diagnosticsEnabled bool = enableDiagnostics
