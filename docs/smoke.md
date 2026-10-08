# Platform smoke test

The v1 definition of done: a workflow in the public `jonathan-vella/ghr-smoke` repository runs on the platform's
ACA runner (`runs-on: ghr-smoke`) and lists the empty `smoke` blob container in a storage account that has public
network access disabled. The runner can reach the account only through the blob private endpoint in
`snet-consumer-pe` (`10.60.0.128/26`).

Anonymous container access is not possible in this tenant: an inherited Azure Policy (Modify) forces
`allowBlobPublicAccess: false`, and shared-key access is disabled. The smoke job therefore uses the PRD consumer pattern
(SR-8): a consumer-owned Entra app with an exact-subject federated credential for the `smoke` environment and
`Storage Blob Data Reader` on the smoke storage account only. No secret is stored, and the runner container still has
no managed identity. The platform deployment principal's RBAC is unchanged.

The consumer is registered in [`config/consumers/smoke.json`](../config/consumers/smoke.json), which allows only
`workflow_dispatch` of `.github/workflows/smoke.yml` on `refs/heads/main`. The pre-job hook rejects anything else.

## Consumer identity (one-time, owner operator)

| Item | Value |
| --- | --- |
| Entra app | `ghr-smoke-consumer` |
| Federated credential subject | `repo:jonathan-vella@25802147/ghr-smoke@1408911254:environment:smoke` |
| Role | `Storage Blob Data Reader` on the smoke storage account |
| GitHub environment | `smoke` in `ghr-smoke`, deployment branch policy `main` only |
| Repository variables | `SMOKE_STORAGE_ACCOUNT`, `SMOKE_AZURE_CLIENT_ID`, `SMOKE_AZURE_TENANT_ID` |

## Smoke workflow

`jonathan-vella/ghr-smoke` contains `.github/workflows/smoke.yml` on `main`:

```yaml
name: smoke
on: workflow_dispatch
permissions:
  id-token: write
jobs:
  smoke:
    runs-on: ghr-smoke
    environment: smoke
    timeout-minutes: 15
    env:
      ACCOUNT: ${{ vars.SMOKE_STORAGE_ACCOUNT }}
      AZURE_CLIENT_ID: ${{ vars.SMOKE_AZURE_CLIENT_ID }}
      AZURE_TENANT_ID: ${{ vars.SMOKE_AZURE_TENANT_ID }}
    steps:
      - name: Blob endpoint resolves to the consumer private endpoint subnet
        run: |
          set -euo pipefail
          host="$ACCOUNT.blob.core.windows.net"
          ip="$(getent hosts "$host" | awk '{print $1}' | head -n1)"
          echo "$host -> $ip"
          case "$ip" in 10.60.0.*) ;; *) echo "::error::not a private 10.60.0.x address"; exit 1 ;; esac
      - name: No managed identity in the runner container
        run: test -z "${IDENTITY_ENDPOINT:-}" && test -z "${IDENTITY_HEADER:-}"
      - name: Azure login with GitHub OIDC
        run: |
          set -euo pipefail
          token="$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)"
          az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
            --federated-token "$token" --allow-no-subscriptions -o none
      - name: List private container through the private endpoint
        run: az storage blob list --account-name "$ACCOUNT" --container-name smoke --auth-mode login -o table
```

## Run order

1. Merge to `main`, then dispatch **Deploy platform** (`.github/workflows/deploy.yml`) on `main`. It builds and pushes
   both images to GHCR, deploys the foundation, checks network readbacks, imports the images into ACR by digest, and
   deploys `caj-ghr-smoke`. Use `foundation_only` to stop after the foundation readbacks.
2. Copy `SMOKE_STORAGE_ACCOUNT` from the run summary and set it as a repository variable in `ghr-smoke`
   (`gh variable set SMOKE_STORAGE_ACCOUNT --repo jonathan-vella/ghr-smoke --body <name>`). Create the consumer
   identity and the `smoke` environment described above, and assign its role on that account.
3. Dispatch `smoke` in `ghr-smoke`. KEDA polls every 15 seconds; the job execution mints a JIT runner labelled
   `ghr-smoke`, the pre-job hook checks the registry policy, the job runs, and the execution exits.
4. On failure, query the `ContainerAppSystemLogs` and `ContainerAppConsoleLogs` categories for the Container Apps
   environment in the platform Log Analytics workspace.
