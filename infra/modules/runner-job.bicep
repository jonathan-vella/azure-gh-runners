@description('The approved Azure region for the shared runner platform.')
@allowed([
  'swedencentral'
])
param location string

@description('One normalized consumer entry from infra/generated/consumers.json.')
param consumer object

@description('Resource ID of the internal Container Apps environment.')
param environmentResourceId string

@description('User-assigned identity with only AcrPull and Key Vault Secrets User access.')
param identityResourceId string

@description('Private ACR login server.')
param registryServer string

@description('jit-init image reference pinned by digest in the private ACR.')
param jitInitImage string

@description('Runner image reference pinned by digest in the private ACR.')
param runnerImage string

@description('Versionless Key Vault secret URL for the GitHub App private key.')
param appKeySecretUrl string

@description('GitHub App ID; not a secret.')
param githubAppId string

@description('GitHub App installation ID; not a secret.')
param githubAppInstallationId string

@description('Governance tags applied to the job.')
param tags object

var owner = split(consumer.repo, '/')[0]
var repo = split(consumer.repo, '/')[1]
var labels = join(consumer.labels, ',')
var appKeySecretName = 'github-app-private-key'
var initResources = {
  cpu: '0.25'
  memory: '0.5Gi'
}
// Consumer cpu/memory is the replica total; the runner gets the total minus the fixed init allocation.
var runnerResourcesByTotalMemory = {
  '1Gi': { cpu: '0.25', memory: '0.5Gi' }
  '1.5Gi': { cpu: '0.5', memory: '1Gi' }
  '2Gi': { cpu: '0.75', memory: '1.5Gi' }
  '2.5Gi': { cpu: '1.0', memory: '2Gi' }
  '3Gi': { cpu: '1.25', memory: '2.5Gi' }
  '3.5Gi': { cpu: '1.5', memory: '3Gi' }
  '4Gi': { cpu: '1.75', memory: '3.5Gi' }
  '4.5Gi': { cpu: '2.0', memory: '4Gi' }
  '5Gi': { cpu: '2.25', memory: '4.5Gi' }
  '5.5Gi': { cpu: '2.5', memory: '5Gi' }
  '6Gi': { cpu: '2.75', memory: '5.5Gi' }
  '6.5Gi': { cpu: '3.0', memory: '6Gi' }
  '7Gi': { cpu: '3.25', memory: '6.5Gi' }
  '7.5Gi': { cpu: '3.5', memory: '7Gi' }
  '8Gi': { cpu: '3.75', memory: '7.5Gi' }
}
var runnerResources = runnerResourcesByTotalMemory[consumer.memory]

resource job 'Microsoft.App/jobs@2026-07-01' = {
  name: 'caj-ghr-${consumer.name}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    environmentId: environmentResourceId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Event'
      replicaTimeout: consumer.replicaTimeoutSeconds
      replicaRetryLimit: 0
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          pollingInterval: 15
          minExecutions: 0
          maxExecutions: consumer.maxExecutions
          rules: [
            {
              name: 'github-runner'
              type: 'github-runner'
              metadata: {
                githubAPIURL: 'https://api.github.com'
                owner: owner
                runnerScope: 'repo'
                repos: repo
                labels: labels
                noDefaultLabels: 'true'
                enableEtags: 'true'
                targetWorkflowQueueLength: '1'
                applicationID: githubAppId
                installationID: githubAppInstallationId
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
          identity: identityResourceId
          lifecycle: 'None'
        }
      ]
      registries: [
        {
          server: registryServer
          identity: identityResourceId
        }
      ]
      secrets: [
        {
          name: appKeySecretName
          keyVaultUrl: appKeySecretUrl
          identity: identityResourceId
        }
      ]
    }
    template: {
      initContainers: [
        {
          name: 'jit-init'
          image: jitInitImage
          command: [
            '/home/runner/externals/node20/bin/node'
          ]
          args: [
            '/opt/runner-image/jit-init.mjs'
          ]
          env: [
            {
              name: 'GH_APP_PRIVATE_KEY'
              secretRef: appKeySecretName
            }
            {
              name: 'GH_APP_ID'
              value: githubAppId
            }
            {
              name: 'GH_APP_INSTALLATION_ID'
              value: githubAppInstallationId
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
              name: 'RUNNER_LABELS'
              value: labels
            }
            {
              name: 'RUNNER_NAME_PREFIX'
              value: 'ghr-${consumer.name}'
            }
          ]
          resources: {
            cpu: json(initResources.cpu)
            memory: initResources.memory
          }
          volumeMounts: [
            {
              volumeName: 'jit'
              mountPath: '/jit'
            }
          ]
        }
      ]
      containers: [
        {
          name: 'runner'
          image: runnerImage
          command: [
            '/opt/runner-image/runner-entrypoint.sh'
          ]
          env: [
            {
              name: 'CONSUMER_POLICY_JSON'
              value: consumer.policyJson
            }
          ]
          resources: {
            cpu: json(runnerResources.cpu)
            memory: runnerResources.memory
          }
          volumeMounts: [
            {
              volumeName: 'jit'
              mountPath: '/jit'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'jit'
          storageType: 'EmptyDir'
        }
      ]
    }
  }
  tags: union(tags, {
    consumer: consumer.name
  })
}

output jobName string = job.name
output jobResourceId string = job.id
