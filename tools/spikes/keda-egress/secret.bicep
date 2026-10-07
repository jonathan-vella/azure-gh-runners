@secure()
param appKey string
param vaultName string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

resource appSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'gh-runner-app-key'
  properties: {
    value: appKey
    attributes: {
      enabled: true
    }
  }
}
