# Issue 10: JIT runner label experiment

This is a bounded, isolated experiment for [issue #10](https://github.com/jonathan-vella/azure-gh-runners/issues/10).
It does not deploy to production or change resources/work owned by issues 6 through 9. No resources are provisioned by
validation or by the PR.

See [OPERATIONS.md](OPERATIONS.md) for the temporary identity bootstrap, explicit spike authorization, bounded observation window,
and exact cleanup procedure.

## Prepared experiment

1. Build the two images from this directory using the pinned official GitHub Actions runner base. The init image
   resolves the runner account's UID/GID from that same base image before setting EmptyDir ownership; the runner image
   installs a fail-closed job-start hook allowing only the two exact dispatch workflows in `ghr-smoke` on `main`.
   Publish them to the private registry in `rg-ghrunners-spike10-swc`; record immutable digest references for the init
   and runner images.
   For example, from the repository root after signing in to the dedicated ACR:

   ```powershell
   $registry = '<dedicated-acr-name>.azurecr.io'
   docker build --file spikes/jit-labels/Dockerfile --target jit-init --tag "$registry/spike10/jit-init:v2.338.0" spikes/jit-labels
   docker build --file spikes/jit-labels/Dockerfile --target jit-runner --tag "$registry/spike10/jit-runner:v2.338.0" spikes/jit-labels
   docker push "$registry/spike10/jit-init:v2.338.0"
   docker push "$registry/spike10/jit-runner:v2.338.0"
   az acr manifest show-metadata --registry $registry --name spike10/jit-init:v2.338.0 --query digest --output tsv
   az acr manifest show-metadata --registry $registry --name spike10/jit-runner:v2.338.0 --query digest --output tsv
   ```

2. Prepare the dedicated internal workload-profiles ACA environment, delegated subnet/NSG, outbound-only NAT Gateway
   and single public IP, private ACR and Key Vault endpoint/secret, and user-assigned image-pull/Key Vault identity in
   the same spike resource group. Keep all PaaS public access disabled. Do not reuse another spike's resources.
3. Add the two workflow files under `spikes/jit-labels/ghr-smoke/.github/workflows/` to `ghr-smoke` through its
   separate reviewed change. They are dispatch-only, nonce-correlated, and contain no secrets or third-party actions.
4. Have a maintainer review and land the scaffolding on `main`. Prepare a temporary deployment identity using the
   verified immutable-ID `platform-prod` subject, with the scoped role grants in
   [OPERATIONS.md](OPERATIONS.md). Then manually dispatch
   **Spike 10 - Deploy isolated JIT label job** from `main` only after the owner has explicitly authorized this
   bounded spike in issue #10; the `platform-prod` environment is main-only and no longer requires a reviewer. Provide its client
   ID, resource IDs, versionless secret URL and image digests, and set capacity confirmation only after verifying
   `swedencentral` capacity. The workflow checks subscription/RG scope, temporary identity roles,
   supported Jobs API/location, private-network settings, delegated subnet/NSG/NAT, private registry/Key Vault, and
   image digests. It rejects a pre-existing job and tags the temporary job with its owning run ID.
5. From an authenticated operator workstation, run
   `.\spikes\jit-labels\Observe-JitLabelScale.ps1 -DeploymentRunId <deployment-run-id>` with Azure CLI and `gh`
   access to the isolated job and `ghr-smoke`; use the numeric ID from the deployment workflow URL. It verifies the
   job's deployment-run ownership tag before cleaning executions. It dispatches each workflow with a unique nonce
   and correlates the exact run, expects a successful custom-label
   run plus one successful ACA execution, and reads actual GitHub runner labels while active. It then dispatches the
   `self-hosted`-only workflow, verifies its actual job requests only `self-hosted`, remains queued/unassigned for at
   least two minutes with no new ACA execution, and cancels and verifies the queued run.
6. The observer checks that the unique ephemeral runner registration is removed. If it remains, the script removes
   only that captured test runner ID and verifies its removal. Stop any remaining named spike job executions using
   the documented Container Apps stop-execution API, then remove the dedicated spike resource group after verifying
   it contains only resources tagged `spike-id=10`.

The diagnostic job is automatically deleted after its bounded 5–45 minute observation window, including workflow
failure/cancellation when the run-ID ownership marker can be confirmed. Azure CLI calls have hard timeouts; deployment
setup, observation, and cleanup use separate bounded steps, with a job ceiling that leaves additional cleanup margin.
If that cleanup is interrupted, follow the explicit verification and external cleanup steps in
[OPERATIONS.md](OPERATIONS.md). The workflow uses a temporary spike-scoped identity, not the production deployment
identity. The protected deployment workflow cannot be run from
this PR branch; the main-only environment restriction remains after it is available on `main`, but it does not require
a human reviewer. Explicit owner authorization and the other spike gates remain mandatory. Do not deploy while the
regional capacity blocker is unresolved.

## Current evidence status

ADR-0005 is Proposed. GitHub documents default runner labels and custom-label matching. KEDA v2.21.0 source compares
all queued-job labels to the configured labels and, when `noDefaultLabels` is true, does not add reserved labels to
the scaler's matching set. Therefore the candidate matching workflow uses the custom label alone, while
`runs-on: self-hosted` is expected not to wake this custom-only rule. Neither behavior is accepted until the isolated
runtime experiment succeeds and its run URLs/observations are recorded in the ADR.

The JIT API requires `runner_group_id`; the request uses `1`, the default shown in GitHub's repository endpoint
example. Whether group `1` is accepted for this personal-account repository remains subject to live API confirmation.
No deployment, image publication, App-key retrieval, or Azure resource access occurs while preparing this scaffold.
