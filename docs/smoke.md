# Platform smoke test

The v1 definition of done: a workflow in the public `jonathan-vella/ghr-smoke` repository runs on the platform's
ACA runner (`runs-on: ghr-smoke`) and lists the empty `smoke` blob container in a storage account that has public
network access disabled. The runner can reach the account only through the blob private endpoint in
`snet-consumer-pe` (`10.60.0.128/26`).

Anonymous container access is not possible in this tenant: an inherited Azure Policy (Modify) forces
`allowBlobPublicAccess: false`, and shared-key access is disabled. The smoke job therefore uses the PRD consumer pattern
(SR-8): a consumer-owned Entra app with an exact-subject federated credential for the `smoke` environment and
`Storage Blob Data Reader` on the smoke storage account only. No secret is stored, and the runner container has no usable
managed identity (the identity environment variables are present, but no token is obtainable; see
[ADR-0004](adr/0004-runner-secret-isolation.md)). The platform deployment principal's RBAC is unchanged.

**Live result (2026-10-11):** [ghr-smoke run 38147983595](https://github.com/jonathan-vella/ghr-smoke/actions/runs/38147983595)
passed on the real ACA runner: the storage hostname resolved to private `10.60.0.132`, Entra OIDC login worked, and the
container listing succeeded over the private endpoint.

**Recovery after the resource group is recreated:** the Entra app, service principal and federated credential are tenant
objects and survive. Recreate the `Storage Blob Data Reader` assignment on the new storage account, and confirm
`SMOKE_STORAGE_ACCOUNT` still matches (the name is deterministic for the same resource group).

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
      - name: No usable managed identity in the runner container
        run: |
          set -u
          for v in IDENTITY_ENDPOINT IDENTITY_HEADER MSI_ENDPOINT MSI_SECRET; do
            if [ -n "${!v:-}" ]; then echo "$v is SET"; else echo "$v is unset"; fi
          done
          if [ -n "${IDENTITY_ENDPOINT:-}" ]; then
            for q in "" "&client_id=<platform user-assigned identity client id>"; do
              code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' -H "X-IDENTITY-HEADER: ${IDENTITY_HEADER:-}" "${IDENTITY_ENDPOINT}?resource=https://management.azure.com/&api-version=2019-08-01${q}" || true)"
              echo "token request (${q:-system-assigned}) HTTP status: ${code}"
              test "${code}" != "200"
            done
          fi
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

## Negative checks

These workflows prove the pre-job hook fails closed. They go in `jonathan-vella/ghr-smoke` **only on throwaway
branches**; never merge them to `main` and never widen `config/consumers/smoke.json` for them. The entry allows only
`workflow_dispatch`, so both a `push` and a `pull_request` job are outside the policy floor for a public consumer and
must be rejected with the hook reason `event outside policy`. (`event` is checked before `ref`, so a non-default-branch
`push` is rejected for its event, not its ref.)

**Status: not yet run.** The expected outcomes below follow from `image/pre-job-policy.py`, its Bats tests and GitHub's
documented hook behavior, not from a live run. Record the first run in the acceptance evidence before relying on it.
Run them one at a time (the entry has `maxExecutions: 1`) and not while the positive smoke is running.

### How a rejection is observed

The hook runs on the real runner after it accepts the job and before any user step. A rejected job therefore:

1. concludes `failure` (the first step, `Set up job`, fails; GitHub's documentation calls this step "Set up runner");
2. has the hook message in its log: `Consumer policy rejected job: event outside policy`;
3. never runs a user step: the canary step below has conclusion `skipped` or is absent, never `success` or `failure`,
   and its marker text `CANARY-USER-STEP-RAN` is absent from the log.

A job that stays `queued` with no ACA execution, or that is cancelled, is **inconclusive**: it does not demonstrate
hook enforcement. Wait up to 10 minutes before calling it inconclusive.

### (a) `push` to a non-default branch

Create branch `negative/push` containing `.github/workflows/negative-push.yml`; pushing it triggers the workflow from
that commit:

```yaml
name: negative-push
on:
  push:
    branches: [negative/push]
permissions:
  contents: read
jobs:
  must-be-rejected:
    runs-on: ghr-smoke
    timeout-minutes: 10
    steps:
      - name: Canary (must never run)
        run: |
          echo "CANARY-USER-STEP-RAN"
          exit 1
```

```bash
REPO=jonathan-vella/ghr-smoke
git clone "https://github.com/$REPO" && cd ghr-smoke
git switch -c negative/push
mkdir -p .github/workflows   # add negative-push.yml with the content above
git add .github/workflows/negative-push.yml && git commit -m "test: negative push check" && git push -u origin negative/push
RUN=$(gh run list --repo "$REPO" --workflow negative-push.yml --branch negative/push --limit 1 --json databaseId --jq '.[0].databaseId')
```

### (b) `pull_request` targeting the label

Create branch `negative/pr` with `.github/workflows/negative-pr.yml` and open a same-repository pull request into
`main` (a same-repository PR from the owner needs no fork approval, so the job is scheduled):

```yaml
name: negative-pr
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  must-be-rejected:
    runs-on: ghr-smoke
    timeout-minutes: 10
    steps:
      - name: Canary (must never run)
        run: |
          echo "CANARY-USER-STEP-RAN"
          exit 1
```

```bash
git switch main && git switch -c negative/pr
mkdir -p .github/workflows   # add negative-pr.yml with the content above
git add .github/workflows/negative-pr.yml && git commit -m "test: negative pull_request check" && git push -u origin negative/pr
gh pr create --repo "$REPO" --base main --head negative/pr --title "negative pull_request check (do not merge)" --body "Throwaway; close without merging."
RUN=$(gh run list --repo "$REPO" --workflow negative-pr.yml --branch negative/pr --limit 1 --json databaseId --jq '.[0].databaseId')
```

### Asserting (a) and (b)

```bash
# wait for completion; a failing conclusion is the expected result, so do not rely on the exit status
for i in $(seq 1 60); do
  [ "$(gh run view "$RUN" --repo "$REPO" --json status --jq .status)" = completed ] && break; sleep 10
done
gh run view "$RUN" --repo "$REPO" --json conclusion,jobs --jq '{run: .conclusion, job: .jobs[0].conclusion, steps: [.jobs[0].steps[] | {name, conclusion}]}'
gh run view "$RUN" --repo "$REPO" --log > run.log
test "$(gh run view "$RUN" --repo "$REPO" --json jobs --jq '.jobs[0].conclusion')" = failure
grep -q 'Consumer policy rejected job: event outside policy' run.log
! grep -q 'CANARY-USER-STEP-RAN' run.log
test "$(gh run view "$RUN" --repo "$REPO" --json jobs --jq '[.jobs[0].steps[] | select(.name | startswith("Canary")) | select(.conclusion == "success" or .conclusion == "failure")] | length')" = 0
test "$(gh api "repos/$REPO/actions/runners" --jq .total_count)" = 0   # the ephemeral runner is gone
```

All five assertions must pass. Cleanup: `git push origin --delete negative/push`; `gh pr close --repo "$REPO" --delete-branch negative/pr`
(never merge); optionally `gh run delete "$RUN" --repo "$REPO"`.

### (c) Identity check (existing workflow)

No new workflow: the `No usable managed identity in the runner container` step of `smoke.yml` already covers it
([ADR-0004](adr/0004-runner-secret-isolation.md)). Assert on the log of a successful dispatch run rather than the step
status, because the step's loop only fails if the **last** token request returns 200:

```bash
gh run view "$SMOKE_RUN" --repo "$REPO" --log > smoke.log
test "$(grep -c 'token request (.*) HTTP status: 400' smoke.log)" = 2   # system-assigned and user-assigned
! grep -q 'HTTP status: 200' smoke.log
```

The `IDENTITY_*`/`MSI_*` variables are reported as `SET` in the container; that is expected and is not the assertion.
Only a refused token request counts. Re-run this after any ACA platform or `identitySettings` change.

### Optional: exercising the ref check

Because the event check fires first, the `ref` rule is not exercised above. If wanted later, propose a **separate
throwaway** entry (for example `smoke-push`, allowing `push` on `refs/heads/main` only, with its own label and job) so
that a push to a non-default branch fails with `job ref outside policy`. Do not widen `smoke.json`; this is not required
for v1.0.

## Run order

1. Merge to `main`, then dispatch **Deploy platform** (`.github/workflows/deploy.yml`) on `main`. It builds and pushes
   both images to GHCR, deploys the foundation, checks network readbacks, imports the images into ACR by digest, and
   deploys `caj-ghr-smoke`, then runs the public-access check. Use `foundation_only` to stop after the foundation
   readbacks.
2. Copy `SMOKE_STORAGE_ACCOUNT` from the run summary and set it as a repository variable in `ghr-smoke`
   (`gh variable set SMOKE_STORAGE_ACCOUNT --repo jonathan-vella/ghr-smoke --body <name>`). Create the consumer
   identity and the `smoke` environment described above, and assign its role on that account.
3. Dispatch `smoke` in `ghr-smoke`. KEDA polls every 15 seconds; the job execution mints a JIT runner labelled
   `ghr-smoke`, the pre-job hook checks the registry policy, the job runs, and the execution exits.
4. Run the [negative checks](#negative-checks).
5. On failure, query the `ContainerAppSystemLogs` and `ContainerAppConsoleLogs` categories for the Container Apps
   environment in the platform Log Analytics workspace ([operations](operations.md#logs)).
