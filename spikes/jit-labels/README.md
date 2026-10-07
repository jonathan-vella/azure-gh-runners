# Issue 10: JIT runner label experiment

This is a bounded, isolated experiment for [issue #10](https://github.com/jonathan-vella/azure-gh-runners/issues/10).
It does not deploy to production or change resources/work owned by issues 6 through 9. No resources are provisioned by
validation or by the PR.

## Prepared experiment

1. Build the two images from this directory using the pinned official GitHub Actions runner base. Publish them to the
   private registry in `rg-ghrunners-spike10-swc`; record immutable digest references for the init and runner images.
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

2. Prepare the dedicated, internal workload-profiles ACA environment, delegated infrastructure subnet, outbound-only
   NAT Gateway and single public IP, private Key Vault endpoint/secret, and user-assigned image-pull/Key Vault identity
   in the same spike resource group. Keep PaaS public access disabled. Do not reuse another spike's resources.
3. Have a maintainer review and land the scaffolding on `main`. Then manually dispatch
   **Spike 10 - Deploy isolated JIT label job** from `main`, provide only resource IDs, secret URL and image digests,
   set capacity confirmation only after verifying `swedencentral` capacity, and approve the protected `platform-prod`
   environment. The workflow rejects non-spike resource IDs, unpinned images, a non-internal/publicly accessible ACA
   environment, a subnet not attached to the named NAT Gateway, or an unexpected NAT address.
4. Add the two workflow files under `spikes/jit-labels/ghr-smoke/.github/workflows/` to `ghr-smoke` through its
   separate reviewed change. They contain only trusted `workflow_dispatch` jobs and no secrets or third-party actions.
5. From an authenticated operator workstation, run
   `.\spikes\jit-labels\Observe-JitLabelScale.ps1` with Azure CLI and `gh` access to the isolated job and `ghr-smoke`.
   It dispatches the custom-label workflow and expects a successful run plus a new successful ACA execution; while
   the job is active, it records the actual GitHub runner labels. It then dispatches the `self-hosted`-only workflow,
   requires it to remain queued for two minutes with no new ACA execution, and cancels the queued run.
6. The observer checks that the unique ephemeral runner registration is removed. If it remains, the script removes
   only that captured test runner ID and verifies its removal. Stop any remaining named spike job executions using
   the documented Container Apps stop-execution API, then remove the dedicated spike resource group after verifying
   it contains only resources tagged `spike-id=10`.

The experiment intentionally has no automated trigger, production deployment path, or automatic test-workflow dispatch.
The protected deployment workflow cannot be run from this PR branch; its environment reviewer gate remains mandatory
after it is available on `main`. Do not deploy while the region capacity blocker is unresolved.

## Current evidence status

ADR-0005 is Proposed. GitHub documents default runner labels and custom-label matching. KEDA v2.21.0 source compares
all queued-job labels to the configured labels and, when `noDefaultLabels` is true, does not add reserved labels to
the scaler's matching set. Therefore the candidate matching workflow uses the custom label alone, while
`runs-on: self-hosted` is expected not to wake this custom-only rule. Neither behavior is accepted until the isolated
runtime experiment succeeds and its run URLs/observations are recorded in the ADR.

The isolated environment and private registry are inputs to the job template. No deployment, image publication,
App-key retrieval, or access to Azure resources occurs while preparing this scaffold.
