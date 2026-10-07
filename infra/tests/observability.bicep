// Compile-only fixture. Never deploy; this uses dummy resource IDs and skips the diagnostic module.
targetScope = 'resourceGroup'

module diagnosticSettings '../modules/diagnostic-settings.bicep' = if (false) {
  name: 'diagnostics-contract-test'
  params: {
    targetResourceId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/diagnostic-test/providers/Microsoft.KeyVault/vaults/contract-test'
    workspaceResourceId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/diagnostic-test/providers/Microsoft.OperationalInsights/workspaces/contract-test'
    name: 'diagnostics-contract-test'
    logCategories: [
      'AuditEvent'
    ]
    enableAllMetrics: true
  }
}
