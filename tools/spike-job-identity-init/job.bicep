targetScope = 'resourceGroup'

@secure()
param syntheticScaleAuth string

param location string = resourceGroup().location
param environmentId string
param identityId string
param registryServer string
param image string
param syntheticSecretUri string
param syntheticAppKeySha256 string
param jitConfigSha256 string

var tags = {
  project: 'azure-gh-runners'
  issue: '9'
  purpose: 'init-container-secret-isolation-spike'
}

resource job 'Microsoft.App/jobs@2026-07-01' = {
  name: 'ghr9-secret-isolation'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 300
      replicaRetryLimit: 0
      identitySettings: [
        {
          identity: identityId
          lifecycle: 'None'
        }
      ]
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 1
          pollingInterval: 30
          rules: [
            {
              name: 'synthetic-queue'
              type: 'azure-queue'
              metadata: {
                accountName: 'ghr9nonexistent'
                queueName: 'spike-never-trigger'
                queueLength: '1'
              }
              auth: [
                {
                  triggerParameter: 'connection'
                  secretRef: 'scale-only-auth'
                }
              ]
            }
          ]
        }
      }
      registries: [
        {
          server: registryServer
          identity: identityId
        }
      ]
      secrets: [
        {
          name: 'synthetic-app-key'
          keyVaultUrl: syntheticSecretUri
          identity: identityId
        }
        {
          name: 'scale-only-auth'
          value: syntheticScaleAuth
        }
      ]
    }
    template: {
      initContainers: [
        {
          name: 'init-secret-reader'
          image: image
          command: [
            '/bin/sh'
          ]
          args: [
            '-c'
            'set -eu; test -n "$APP_KEY"; printf "%s" "$APP_KEY" | sha256sum | grep -q "^$CANARY_SHA256 "; umask 077; printf "%s" "synthetic-jit-config" > /jit/config; chmod 400 /jit/config; stat -c "%a" /jit/config | grep -qx 400; if env | grep -q "^SCALE_ONLY_SECRET="; then exit 1; fi; printf "ASSERT_init_secret_ref_read=true\\nASSERT_init_secret_match=true\\nASSERT_scale_secret_absent_init=true\\nASSERT_jit_file_mode_0400=true\\n"'
          ]
          env: [
            {
              name: 'APP_KEY'
              secretRef: 'synthetic-app-key'
            }
            {
              name: 'CANARY_SHA256'
              value: syntheticAppKeySha256
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
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
          name: 'main'
          image: image
          command: [
            '/bin/sh'
          ]
          args: [
            '-c'
            'set -eu; stat -c "%a" /jit/config | grep -qx 400; sha256sum /jit/config | grep -q "^$EXPECTED_JIT_SHA256 "; if env | grep -q "^IDENTITY_ENDPOINT="; then exit 1; fi; if env | grep -q "^IDENTITY_HEADER="; then exit 1; fi; if env | grep -q "^APP_KEY="; then exit 1; fi; if env | grep -q "^SCALE_ONLY_SECRET="; then exit 1; fi; printf "ASSERT_emptydir_shared=true\\nASSERT_jit_file_mode_0400=true\\nASSERT_identity_endpoint_absent=true\\nASSERT_secret_env_absent_main=true\\nASSERT_scale_secret_absent_main=true\\n"'
          ]
          env: [
            {
              name: 'EXPECTED_JIT_SHA256'
              value: jitConfigSha256
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
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
}
