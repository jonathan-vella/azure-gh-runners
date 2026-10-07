targetScope = 'resourceGroup'

@description('Resource ID of the existing internal ACA environment dedicated to spike 10.')
param environmentResourceId string

@description('Infrastructure subnet ID of the existing spike 10 ACA environment.')
param infrastructureSubnetId string

@description('Resource ID of the dedicated spike 10 NAT Gateway.')
param natGatewayResourceId string

@description('Public IPv4 address allocated only for spike 10 outbound NAT.')
param natPublicIpAddress string

@description('Init container image reference pinned to a sha256 digest in the private registry.')
param initImageReference string

@description('Runner container image reference pinned to a sha256 digest in the private registry.')
param runnerImageReference string

@description('User-assigned identity with only image-pull and Key Vault secret-read access for spike 10.')
param pullIdentityResourceId string

@description('Versionless Key Vault secret URL for the GitHub App private key.')
param keyVaultAppKeySecretUrl string

@description('GitHub App ID; not a secret.')
param appId string

@description('GitHub App installation ID for ghr-smoke; not a secret.')
param installationId string

@description('GitHub owner containing the synthetic test repository.')
param owner string

@description('Single repository monitored by the diagnostic scaler.')
param repo string

@description('The only label used by the KEDA rule and the matching smoke workflow.')
param customLabel string

@description('The isolated ACA environment and job location.')
param location string = 'swedencentral'

@description('GitHub Actions run ID that owns this temporary diagnostic job.')
param deploymentRunId string

var jobName = 'caj-ghr-spike10-jit-labels'
var registryServer = split(initImageReference, '/')[0]
var appKeySecretName = 'github-app-private-key'

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: last(split(environmentResourceId, '/'))
}

resource job 'Microsoft.App/jobs@2026-07-01' = {
  name: jobName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentityResourceId}': {}
    }
  }
  properties: {
    environmentId: environment.id
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 900
      replicaRetryLimit: 0
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          pollingInterval: 15
          minExecutions: 0
          maxExecutions: 1
          rules: [
            {
              name: 'github-runner-jit-label-spike'
              type: 'github-runner'
              metadata: {
                owner: owner
                repos: repo
                runnerScope: 'repo'
                labels: customLabel
                noDefaultLabels: 'true'
                enableEtags: 'true'
                targetWorkflowQueueLength: '1'
                applicationID: appId
                installationID: installationId
              }
              auth: [
                {
                  triggerParameter: 'appKey'
                  secretRef: appKeySecretName
                }
              ]
            }
          ]
        }
      }
      identitySettings: [
        {
          identity: pullIdentityResourceId
          lifecycle: 'None'
        }
      ]
      registries: [
        {
          server: registryServer
          identity: pullIdentityResourceId
        }
      ]
      secrets: [
        {
          name: appKeySecretName
          keyVaultUrl: keyVaultAppKeySecretUrl
          identity: pullIdentityResourceId
        }
      ]
    }
    template: {
      initContainers: [
        {
          name: 'mint-jit-config'
          image: initImageReference
          env: [
            {
              name: 'GH_APP_PRIVATE_KEY'
              secretRef: appKeySecretName
            }
            {
              name: 'GH_APP_ID'
              value: appId
            }
            {
              name: 'GH_APP_INSTALLATION_ID'
              value: installationId
            }
            {
              name: 'GITHUB_OWNER'
              value: owner
            }
            {
              name: 'GITHUB_REPOSITORY'
              value: repo
            }
            {
              name: 'RUNNER_LABEL'
              value: customLabel
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          volumeMounts: [
            {
              volumeName: 'jit-config'
              mountPath: '/jit'
            }
          ]
        }
      ]
      containers: [
        {
          name: 'actions-runner'
          image: runnerImageReference
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          volumeMounts: [
            {
              volumeName: 'jit-config'
              mountPath: '/jit'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'jit-config'
          storageType: 'EmptyDir'
        }
      ]
    }
  }
  tags: {
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
    'spike-id': '10'
    'spike-name': 'jit-runner-labels'
    'spike-deployment-run-id': deploymentRunId
  }
}

output jobResourceId string = job.id
output jobName string = job.name
output environmentResourceId string = environment.id
output infrastructureSubnetId string = infrastructureSubnetId
output natGatewayResourceId string = natGatewayResourceId
output natPublicIpAddress string = natPublicIpAddress
output runnerLabel string = customLabel
