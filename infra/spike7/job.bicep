targetScope = 'resourceGroup'

param jobName string
param location string = 'swedencentral'
param environmentResourceId string
param identityResourceId string
param keyVaultSecretUrl string
param workloadProfileName string = 'Consumption'

@description('Non-secret SHA-256 digest of the synthetic probe value.')
@minLength(64)
@maxLength(64)
param probeDigest string

var tags = {
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
}

module diagnosticJob 'br/public:avm/res/app/job:0.7.2' = {
  name: 'job-${uniqueString(deployment().name)}'
  params: {
    name: jobName
    location: location
    environmentResourceId: environmentResourceId
    workloadProfileName: workloadProfileName
    triggerType: 'Manual'
    managedIdentities: {
      userAssignedResourceIds: [
        identityResourceId
      ]
    }
    replicaRetryLimit: 0
    replicaTimeout: 300
    manualTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
    }
    secrets: [
      {
        name: 'probe'
        identity: identityResourceId
        keyVaultUrl: keyVaultSecretUrl
      }
    ]
    containers: [
      {
        name: 'probe'
        image: 'mcr.microsoft.com/azure-cli@sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044'
        command: [
          '/bin/sh'
          '-c'
        ]
        args: [
          'actual="$(printf "%s" "$PROBE_SECRET" | sha256sum | cut -d " " -f 1)"; if [ "$actual" = "$EXPECTED_SHA256" ]; then printf "RESULT=match\\n"; else printf "RESULT=mismatch\\n"; exit 1; fi'
        ]
        env: [
          {
            name: 'PROBE_SECRET'
            secretRef: 'probe'
          }
          {
            name: 'EXPECTED_SHA256'
            value: probeDigest
          }
        ]
        resources: {
          cpu: '0.25'
          memory: '0.5Gi'
        }
      }
    ]
    tags: tags
  }
}

output name string = diagnosticJob.outputs.name
