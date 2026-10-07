# Issue 10 operator procedure

This procedure prepares and tears down only the temporary JIT-label diagnostic deployment. It does not create or use
production runner resources, change the production deployment identity, read the GitHub App private key, or deploy
anything while the capacity blocker or separate explicit spike-authorization gate remains unresolved. The
`platform-prod` environment is main-only and does not require a human reviewer.

## Temporary deployment identity

The current production Azure identity is scoped to the production resource group and must not be used for this spike.
After the isolated environment, private ACR, private Key Vault, and runner pull identity exist, an authorized operator
may prepare a dedicated Entra app/service principal for one spike run. Authenticate `az` to tenant
`30bac921-1547-4b1e-8445-72455da783f1` and subscription `b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`; the script verifies
the `shared` subscription, `swedencentral`, exact spike-10 resource group, and pull identity scope.

Do not use a name-only subject or the subject from a different workflow. The verified repository customization is
`use_default: true`, `use_immutable_subject: true`, with prefix
`repo:jonathan-vella@25802147/azure-gh-runners@1408821667`; the GitHub environment suffix remains the standard
`:environment:platform-prod`. This verified immutable-ID subject is sufficient for the temporary FIC; a separate
claims-diagnostic workflow is not a prerequisite. The preparation script reads the live GitHub OIDC customization
metadata with `gh` and stops if the template differs from the verified values. It also reads the created FIC back
from Entra and checks the exact subject/audience before assigning any role. The optional gated diagnostic can
corroborate runtime claims without printing the JWT, but must not be used to infer a different subject.

Choose a unique lowercase alphanumeric suffix, 4–16 characters. This creates a credential-free workload identity,
with one FIC using the exact immutable-ID subject and exactly two RBAC assignments: Contributor on
`rg-ghrunners-spike10-swc` and Managed Identity Operator on the issue-10 pull identity. It does not grant role-assignment
administration. The authorized operator must already have permissions to create that app/FIC and those scoped grants.
Preparation aborts if the app name already exists or if any unexpected assignment is found.

```powershell
.\spikes\jit-labels\Prepare-Cleanup-SpikeIdentity.ps1 `
  -Action Prepare `
  -RunSuffix 20261007a `
  -PullIdentityResourceId '/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike10-swc/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ghr-spike10'
```

Record the displayed `ClientId`; it is not a credential. Do not create a client secret or certificate. Supply this
client ID as the workflow input. The workflow uses the fixed approved tenant/subscription and independently checks
that the client ID has only the expected Contributor and Managed Identity Operator grants. Before deployment, the
user-assigned pull identity must have exactly `AcrPull` on the dedicated ACR and `Key Vault Secrets User` on the
dedicated Key Vault; the workflow verifies both assignments. Prepare those two grants only after confirming the
identity has no other assignments:

```powershell
$pullIdentity = az identity show --ids '<spike-10-pull-identity-resource-id>' --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e --output json | ConvertFrom-Json
$existingAssignments = az role assignment list --assignee-object-id $pullIdentity.principalId --all --include-inherited --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e --output json | ConvertFrom-Json
if (@($existingAssignments).Count -ne 0) { throw 'Pull identity already has assignments; stop for authorized review.' }

$acr = az acr show --name '<spike-10-acr-name>' --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e --output json | ConvertFrom-Json
$vault = az keyvault show --name '<spike-10-key-vault-name>' --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e --output json | ConvertFrom-Json
az role assignment create --assignee-object-id $pullIdentity.principalId --assignee-principal-type ServicePrincipal --role AcrPull --scope $acr.id --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e
az role assignment create --assignee-object-id $pullIdentity.principalId --assignee-principal-type ServicePrincipal --role 'Key Vault Secrets User' --scope $vault.id --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e
```

GH App secrets are available to the deployment run through the protected `platform-prod` environment on `main`.
Because the environment has no required reviewer, record the owner's explicit authorization for the exact bounded
spike in issue #10 before dispatch; environment branch protection is not that authorization.

## Deploy, observe, clean up

1. Before dispatch, verify `swedencentral` capacity is available. If the ACA environment cannot provision, stop; do
   not change regions or relax private networking. The environment must be internal, workload-profile based,
   public-disabled, provisioned successfully, and attached to the delegated spike subnet. The subnet must use the
   dedicated NAT Gateway, have an NSG with no Internet/wildcard inbound allow, and have only the expected NAT public
   IP. ACR and Key Vault must be in the spike-10 resource group with public access disabled. All images must use
   immutable digests.
2. Land the reviewed scaffold on `main` without closing #10. Prepare the temporary deployment identity using the
   verified immutable-ID subject after the script validates the live repository template. Add the two trusted files under
   `spikes/jit-labels/ghr-smoke/.github/workflows/` to `ghr-smoke` through its separate reviewed change. The files are
   dispatch-only and the runner image's job-start hook additionally permits only those two workflows, the exact
   `ghr-smoke` repository, `workflow_dispatch`, and `refs/heads/main`.
3. After the owner has explicitly authorized this bounded spike in issue #10, manually dispatch
   **Spike 10 - Deploy isolated JIT label job** from `main`. The environment's main-only branch policy remains in
   force but does not require a reviewer; do not treat that policy as spike authorization. Enter the temporary `ClientId`, exact
   resource IDs, versionless Key Vault secret URL, immutable image references, and an observation window from 5 to 45
   minutes. Select capacity confirmation only after checking capacity. No resources may be deployed before the
   explicit spike authorization and capacity preflight are complete.
4. Once the deployment run enters its bounded observation window, run the observer from PowerShell 7 (`pwsh`) on an
   operator workstation authenticated to the fixed shared subscription and `ghr-smoke`:
   `.\spikes\jit-labels\Observe-JitLabelScale.ps1 -DeploymentRunId <deployment-run-id>`. Use the numeric GitHub Actions run ID from the
   deployment URL. Before it acts on executions, the observer verifies that the named ACA job's run-ownership tag
   matches this exact ID; it rechecks the marker before cleanup. The observer correlates each dispatch by a unique
   nonce, requires the matching
   workflow's exact custom-only runner label, reads the registered JIT labels while the job is active, and requires
   exactly one successful ACA execution. Its negative control checks the actual queued job has only the `self-hosted`
   label, remains unassigned/queued for at least two minutes, and starts no ACA execution. The observer cancels the
   queued run and confirms GitHub reports the cancelled terminal state.
5. Capture workflow URLs, the JIT label set, the positive execution, the no-wake interval, and cleanup results. Do not
   update ADR-0005 to Accepted or check issue criteria without this evidence.

The deployment workflow tags the job with its owning GitHub run ID, refuses to overwrite an existing job, and keeps
the key-bearing scaler available only for the bounded observation window. Every Azure CLI call is timeout-bounded;
deployment setup has a 30-minute step limit, the observation hold is capped at 50 minutes for a maximum 45-minute
requested window, cleanup has its own 10-minute step limit, and the job has a 105-minute ceiling to leave runner
startup/step-transition margin. Cleanup is attempted on success, failure, timeout, or cancellation, and deletes only
if the run-ID ownership marker matches. If the cleanup step is interrupted or reports failure, use the following
external cleanup after confirming the run's `spike-deployment-run-id` tag equals the cancelled/failed workflow run ID:

```powershell
az containerapp job delete `
  --name caj-ghr-spike10-jit-labels `
  --resource-group rg-ghrunners-spike10-swc `
  --subscription b47d2942-f5ad-4d3c-b28e-c23e4f83d97e `
  --yes
```

Verify the job is absent, no test runner remains registered, and no owned execution remains active. Then remove the
temporary identity by its exact `ClientId`; cleanup is safe to rerun after the spike resource group or pull identity
has already been removed, accepts only zero-to-two remaining expected role grants and zero-to-one exact FIC, rejects
unexpected roles/credentials, and verifies app/service-principal absence. It supports `-WhatIf`:

```powershell
.\spikes\jit-labels\Prepare-Cleanup-SpikeIdentity.ps1 `
  -Action Cleanup `
  -RunSuffix 20261007a `
  -ClientId '<temporary-client-id>' `
  -PullIdentityResourceId '<exact-spike-10-pull-identity-resource-id>' `
  -WhatIf
```

After reviewing the WhatIf output, repeat without `-WhatIf`. Remove remaining spike-only Azure resources and the
dedicated resource group only after verifying it contains exclusively issue-10 resources. Do not remove anything
owned by issues 6–9.
