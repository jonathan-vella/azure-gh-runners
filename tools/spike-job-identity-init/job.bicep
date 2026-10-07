targetScope = 'resourceGroup'

@secure()
param syntheticScaleAuth string

param syntheticScaleAuthSha256 string
param location string = resourceGroup().location
param expiry string
param environmentId string
param identityId string
param registryServer string
param image string
param syntheticSecretUri string
param syntheticAppKeySha256 string
param jitConfigSha256 string

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
  project: 'azure-gh-runners'
  issue: '9'
  purpose: 'init-container-secret-isolation-spike'
  expiresOn: expiry
}

var initScript = concat(
  'set -eu; test "$(id -u)" = "0"; test -n "$APP_KEY"; printf "%s" "$APP_KEY" | sha256sum | grep -q "^$CANARY_SHA256 "; ',
  'umask 077; printf "%s" "synthetic-jit-config" > /jit/config; chown 65532:65532 /jit /jit/config; chmod 700 /jit; chmod 400 /jit/config; ',
  'test "$(stat -c "%u:%g %a" /jit/config)" = "65532:65532 400"; ',
  'env | while IFS="=" read -r name value; do actual="$(printf "%s" "$value" | sha256sum | cut -d " " -f 1)"; if [ "$actual" = "',
  syntheticScaleAuthSha256,
  '" ]; then exit 1; fi; done; ',
  'printf "ASSERT_init_secret_ref_read=true\\nASSERT_init_secret_match=true\\nASSERT_scale_secret_value_absent_init=true\\nASSERT_jit_file_mode_owner=true\\n"'
)

var mainScript = loadTextContent('main_probe.py')
var mainBootstrap = 'import os,sys; os.setgroups([]); os.setgid(65532); os.setuid(65532); exec(compile(sys.argv[1], "<main-probe>", "exec"))'

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
            initScript
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
            'python3'
          ]
          args: [
            '-c'
            mainBootstrap
            mainScript
          ]
          env: [
            {
              name: 'EXPECTED_JIT_SHA256'
              value: jitConfigSha256
            }
            {
              name: 'EXPECTED_APP_KEY_SHA256'
              value: syntheticAppKeySha256
            }
            {
              name: 'EXPECTED_SCALE_AUTH_SHA256'
              value: syntheticScaleAuthSha256
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
