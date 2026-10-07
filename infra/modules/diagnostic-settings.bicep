@description('The resource ID of the resource being monitored.')
param targetResourceId string

@description('The resource ID of the Log Analytics workspace destination.')
param workspaceResourceId string

@description('The diagnostic setting name.')
param name string

@description('Explicit service log categories supported by the target resource.')
param logCategories string[] = []

@description('Enable the AllMetrics category only when supported by the target resource.')
param enableAllMetrics bool = false

module diagnosticSetting 'diagnostic-settings.json' = if (!empty(logCategories) || enableAllMetrics) {
  name: name
  params: {
    targetResourceId: targetResourceId
    workspaceResourceId: workspaceResourceId
    name: name
    logCategories: logCategories
    enableAllMetrics: enableAllMetrics
  }
}
