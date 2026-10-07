targetScope = 'resourceGroup'

@secure()
param syntheticAppKey string

param location string = resourceGroup().location
param expiry string

var suffix = uniqueString(resourceGroup().id)
var acrName = 'ghr9${suffix}'
var vaultName = 'ghr9kv${suffix}'
var environmentName = 'ghr9-env'
var identityName = 'ghr9-job-identity'
var tags = {
  project: 'azure-gh-runners'
  issue: '9'
  purpose: 'init-container-secret-isolation-spike'
  expiresOn: expiry
}

resource vnet 'Microsoft.Network/virtualNetworks@2026-05-01' = {
  name: 'ghr9-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.82.0.0/22'
      ]
    }
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2026-05-01' = {
  name: 'ghr9-nat-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nat 'Microsoft.Network/natGateways@2026-05-01' = {
  name: 'ghr9-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
    idleTimeoutInMinutes: 10
  }
}

resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2026-05-01' = {
  parent: vnet
  name: 'aca'
  properties: {
    addressPrefix: '10.82.0.0/27'
    delegations: [
      {
        name: 'aca-environment'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    natGateway: {
      id: nat.id
    }
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2026-05-01' = {
  parent: vnet
  name: 'private-endpoints'
  properties: {
    addressPrefix: '10.82.0.32/27'
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'None'
    dataEndpointEnabled: true
  }
}

resource vault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource syntheticAppSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  parent: vault
  name: 'synthetic-app-key'
  properties: {
    value: syntheticAppKey
    attributes: {
      enabled: true
    }
  }
}

resource acrPrivateDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurecr.io'
  location: 'global'
  tags: tags
}

resource vaultPrivateDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource acrDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: acrPrivateDns
  name: 'ghr9-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource vaultDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: vaultPrivateDns
  name: 'ghr9-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2026-05-01' = {
  name: 'ghr9-acr-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'acr'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}

resource vaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2026-05-01' = {
  name: 'ghr9-vault-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource acrPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-05-01' = {
  parent: acrPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr'
        properties: {
          privateDnsZoneId: acrPrivateDns.id
        }
      }
    ]
  }
}

resource vaultPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-05-01' = {
  parent: vaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: vaultPrivateDns.id
        }
      }
    ]
  }
}

resource jobIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  tags: tags
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identityName, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
    principalId: jobIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource vaultSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identityName, 'KeyVaultSecretsUser')
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: jobIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acaEnvironment 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnet.id
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

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output environmentName string = acaEnvironment.name
output identityId string = jobIdentity.id
output vaultName string = vault.name
output syntheticSecretUri string = format(
  'https://{0}.{1}/secrets/{2}',
  vault.name,
  environment().suffixes.keyvaultDns,
  syntheticAppSecret.name
)
