@description('Azure region.')
param location string

@description('One Windows consumer from infra/generated/windows-consumers.json.')
param consumer object

@description('Resource ID of the Container Apps environment.')
param environmentResourceId string

@description('Orchestrator user-assigned identity resource ID.')
param identityResourceId string

@description('Client ID of the orchestrator identity (used by az login --identity).')
param identityClientId string

@description('ACR login server holding the orchestrator image.')
param registryServer string

@description('Orchestrator image reference pinned by digest.')
param orchestratorImage string

@secure()
@description('GitHub App private key. Stored as an ACA secret; only the orchestrator container receives it.')
param githubAppPrivateKey string

@description('GitHub App ID; not a secret.')
param githubAppId string

@description('GitHub App installation ID; not a secret.')
param githubAppInstallationId string

@description('Resource group that holds the worker VMs.')
param workerResourceGroupName string

@description('VMSS Flex name that workers attach to.')
param vmssName string

@description('Compute Gallery image definition resource ID (latest version is used).')
param imageDefinitionResourceId string

@description('Worker subnet resource ID.')
param workerSubnetResourceId string

@description('Governance tags.')
param tags object

var repo = last(split(consumer.repo, '/'))
var appKeySecretName = 'github-app-private-key'

resource job 'Microsoft.App/jobs@2026-07-01' = {
  name: 'caj-ghrw-${consumer.name}'
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
      // Worker VM expiry is job timeout + 15 minutes; the replica must outlive the wait and still run cleanup.
      replicaTimeout: (consumer.jobTimeoutMinutes + 20) * 60
      replicaRetryLimit: 0
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          pollingInterval: 15
          minExecutions: 0
          maxExecutions: consumer.maxRunners
          rules: [
            {
              name: 'github-runner'
              type: 'github-runner'
              metadata: {
                githubAPIURL: 'https://api.github.com'
                owner: consumer.owner
                runnerScope: 'repo'
                repos: repo
                labels: consumer.label
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
      // The orchestrator needs its identity at runtime to manage worker VMs. It runs only this platform's code.
      identitySettings: [
        {
          identity: identityResourceId
          lifecycle: 'Main'
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
          value: githubAppPrivateKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'orchestrator'
          image: orchestratorImage
          env: [
            { name: 'GH_APP_PRIVATE_KEY', secretRef: appKeySecretName }
            { name: 'GH_APP_ID', value: githubAppId }
            { name: 'GH_APP_INSTALLATION_ID', value: githubAppInstallationId }
            { name: 'GITHUB_OWNER', value: consumer.owner }
            { name: 'GITHUB_REPOSITORY', value: repo }
            { name: 'RUNNER_LABEL', value: consumer.label }
            { name: 'CONSUMER_NAME', value: consumer.name }
            { name: 'WORKER_VM_SIZE', value: consumer.vmSize }
            { name: 'JOB_TIMEOUT_MINUTES', value: string(consumer.jobTimeoutMinutes) }
            { name: 'WORKER_POLICY_JSON', value: string(consumer.policy) }
            { name: 'AZURE_RESOURCE_GROUP', value: workerResourceGroupName }
            { name: 'VMSS_NAME', value: vmssName }
            { name: 'IMAGE_DEFINITION_ID', value: imageDefinitionResourceId }
            { name: 'WORKER_SUBNET_ID', value: workerSubnetResourceId }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
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
