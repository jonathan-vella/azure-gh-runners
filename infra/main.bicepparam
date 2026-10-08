using './main.bicep'

// Values come from the platform-prod deploy workflow environment; empty defaults keep local builds offline.
param deployJobs = bool(readEnvironmentVariable('DEPLOY_JOBS', 'false'))
param githubAppPrivateKey = readEnvironmentVariable('GH_APP_PRIVATE_KEY', '')
param githubAppId = readEnvironmentVariable('GH_APP_ID', '')
param githubAppInstallationId = readEnvironmentVariable('GH_APP_INSTALLATION_ID', '')
param jitInitImageDigest = readEnvironmentVariable('JIT_INIT_IMAGE_DIGEST', '')
param runnerImageDigest = readEnvironmentVariable('RUNNER_IMAGE_DIGEST', '')
