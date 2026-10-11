using './main.bicep'

// Values come from the deploy-windows workflow environment; empty defaults keep local builds offline.
param deployJobs = bool(readEnvironmentVariable('DEPLOY_JOBS', 'false'))
param githubAppPrivateKey = readEnvironmentVariable('GH_APP_PRIVATE_KEY', '')
param githubAppId = readEnvironmentVariable('GH_APP_ID', '')
param githubAppInstallationId = readEnvironmentVariable('GH_APP_INSTALLATION_ID', '')
param orchestratorImageDigest = readEnvironmentVariable('ORCHESTRATOR_IMAGE_DIGEST', '')

// Budget is optional and alert-only. 0 disables it; set WINDOWS_BUDGET_AMOUNT and WINDOWS_BUDGET_EMAILS (comma-separated).
param budgetAmount = int(readEnvironmentVariable('WINDOWS_BUDGET_AMOUNT', '0'))
param budgetContactEmails = empty(readEnvironmentVariable('WINDOWS_BUDGET_EMAILS', '')) ? [] : split(readEnvironmentVariable('WINDOWS_BUDGET_EMAILS', ''), ',')

var tagOwner = readEnvironmentVariable('GHR_TAG_OWNER', 'platform-team')
param tags = {
  application: 'ghrunners'
  environment: 'prod'
  workload: 'gh-runners-windows'
  owner: tagOwner
  costcenter: readEnvironmentVariable('GHR_TAG_COSTCENTER', 'platform-engineering')
  'tech-contact': tagOwner
  'technical-contact': tagOwner
  sla: 'development'
  'backup-policy': 'none'
  'maint-window': 'none'
}
