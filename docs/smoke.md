# Platform smoke test

The v1 definition of done: a workflow in the public `jonathan-vella/ghr-smoke` repository runs on the platform's
ACA runner (`runs-on: ghr-smoke`) and anonymously lists the empty `smoke` blob container in a storage account that has
public network access disabled. The runner can reach the account only through the blob private endpoint in
`snet-consumer-pe` (`10.60.0.128/26`).

The consumer is registered in [`config/consumers/smoke.json`](../config/consumers/smoke.json), which allows only
`workflow_dispatch` of `.github/workflows/smoke.yml` on `refs/heads/main`. The pre-job hook rejects anything else.

## Smoke workflow

Commit this file to `jonathan-vella/ghr-smoke` as `.github/workflows/smoke.yml` on `main`:

```yaml
name: smoke

on:
  workflow_dispatch:
    inputs:
      storage_account:
        description: Smoke storage account name from the platform deployment summary
        required: true
        type: string

permissions: {}

jobs:
  smoke:
    runs-on: ghr-smoke
    timeout-minutes: 10
    env:
      ACCOUNT: ${{ inputs.storage_account }}
    steps:
      - name: Assert no managed identity is exposed
        run: |
          if [[ -n "${IDENTITY_ENDPOINT:-}" || -n "${IDENTITY_HEADER:-}" ]]; then
            echo "::error::Managed identity endpoint is visible to job steps."
            exit 1
          fi

      - name: Assert the blob endpoint resolves to the consumer private endpoint
        run: |
          set -euo pipefail
          [[ "$ACCOUNT" =~ ^[a-z0-9]{3,24}$ ]] || { echo "::error::Invalid account name."; exit 1; }
          host="${ACCOUNT}.blob.core.windows.net"
          ip="$(getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }')"
          echo "$host -> $ip"
          [[ "$ip" =~ ^10\.60\.0\.([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 128 && BASH_REMATCH[1] <= 191 )) ||
            { echo "::error::Blob endpoint did not resolve into snet-consumer-pe."; exit 1; }

      - name: List the smoke container anonymously
        run: |
          set -euo pipefail
          code="$(curl -sS -o list.xml -w '%{http_code}' \
            "https://${ACCOUNT}.blob.core.windows.net/smoke?restype=container&comp=list")"
          [[ "$code" == 200 ]] || { echo "::error::Expected HTTP 200, got $code."; exit 1; }
          grep -q '<EnumerationResults' list.xml
          echo "Anonymous container listing succeeded through the private endpoint."
```

## Run order

1. Merge to `main`, then dispatch **Deploy platform** (`.github/workflows/deploy.yml`) on `main`. It builds and pushes
   both images to GHCR, deploys the foundation, checks network readbacks, imports the images into ACR by digest, and
   deploys `caj-ghr-smoke`. Use `foundation_only` to stop after the foundation readbacks.
2. Copy the smoke storage account name from the run summary.
3. Commit the workflow above to `jonathan-vella/ghr-smoke` `main`.
4. Dispatch `smoke` in `ghr-smoke` with `storage_account` set. KEDA polls every 15 seconds; the job execution mints a
   JIT runner labelled `ghr-smoke`, runs the job, and exits.
5. On failure, query the `ContainerAppSystemLogs` and `ContainerAppConsoleLogs` categories for the Container Apps
   environment in the platform Log Analytics workspace.
