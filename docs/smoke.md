# Platform smoke test

The v1 definition of done: a workflow in the public `jonathan-vella/ghr-smoke` repository runs on the platform's
ACA runner (`runs-on: ghr-smoke`) and anonymously lists the empty `smoke` blob container in a storage account that has
public network access disabled. The runner can reach the account only through the blob private endpoint in
`snet-consumer-pe` (`10.60.0.128/26`).

The consumer is registered in [`config/consumers/smoke.json`](../config/consumers/smoke.json), which allows only
`workflow_dispatch` of `.github/workflows/smoke.yml` on `refs/heads/main`. The pre-job hook rejects anything else.

## Smoke workflow

`jonathan-vella/ghr-smoke` contains `.github/workflows/smoke.yml` on `main`. It reads the account name from the
repository variable `SMOKE_STORAGE_ACCOUNT`:

```yaml
name: smoke
on: workflow_dispatch
permissions: {}
jobs:
  smoke:
    runs-on: ghr-smoke
    timeout-minutes: 15
    env:
      ACCOUNT: ${{ vars.SMOKE_STORAGE_ACCOUNT }}
    steps:
      - name: Blob endpoint resolves to the consumer private endpoint subnet
        run: |
          set -euo pipefail
          host="$ACCOUNT.blob.core.windows.net"
          ip="$(getent hosts "$host" | awk '{print $1}' | head -n1)"
          echo "$host -> $ip"
          case "$ip" in 10.60.0.1[2-9][0-9]|10.60.0.[0-9]*) ;; *) echo "::error::not a private 10.60.0.x address"; exit 1 ;; esac
      - name: List private container through the private endpoint
        run: |
          set -euo pipefail
          code="$(curl -sS -o body.xml -w '%{http_code}' "https://$ACCOUNT.blob.core.windows.net/smoke?restype=container&comp=list")"
          echo "HTTP $code"; head -c 400 body.xml; echo
          test "$code" = 200
          grep -q '<EnumerationResults' body.xml
      - name: No managed identity in the runner container
        run: test -z "${IDENTITY_ENDPOINT:-}" && test -z "${IDENTITY_HEADER:-}"
```

## Run order

1. Merge to `main`, then dispatch **Deploy platform** (`.github/workflows/deploy.yml`) on `main`. It builds and pushes
   both images to GHCR, deploys the foundation, checks network readbacks, imports the images into ACR by digest, and
   deploys `caj-ghr-smoke`. Use `foundation_only` to stop after the foundation readbacks.
2. Copy `SMOKE_STORAGE_ACCOUNT` from the run summary and set it as a repository variable in `ghr-smoke`
   (`gh variable set SMOKE_STORAGE_ACCOUNT --repo jonathan-vella/ghr-smoke --body <name>`).
3. Dispatch `smoke` in `ghr-smoke`. KEDA polls every 15 seconds; the job execution mints a JIT runner labelled
   `ghr-smoke`, the pre-job hook checks the registry policy, the job runs, and the execution exits.
4. On failure, query the `ContainerAppSystemLogs` and `ContainerAppConsoleLogs` categories for the Container Apps
   environment in the platform Log Analytics workspace.
