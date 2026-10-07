# ADR-0002: Key Vault secret references over private endpoints

## Context

Issue [#7](https://github.com/jonathan-vella/azure-gh-runners/issues/7) asks whether an Azure Container Apps (ACA)
job in a VNet-integrated workload-profiles environment can resolve a `keyVaultUrl` secret from a Key Vault that has
public network access disabled and a private endpoint, and whether the Key Vault **Allow trusted Microsoft services**
bypass is required.

Microsoft Learn documents managed-identity Key Vault references for Container Apps, but that guidance alone does not
establish the private-endpoint behavior required by this platform:

- [Manage secrets in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Jobs in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/jobs)
- [Networking in an Azure Container Apps environment](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- [Configure virtual networks in Container Apps environments](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [Troubleshoot the AKSCapacityHeavyUsage error](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/error-codes/akscapacityheavyusage-error)
- [Manage Container Apps workload profiles with the Azure CLI](https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-manage-cli)

## Decision

**No architecture decision is made. The behavior and trusted-services requirement remain unverified.**

On 2026-10-07, an isolated deployment was attempted only in subscription `shared`
(`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`), tenant `30bac921-1547-4b1e-8445-72455da783f1`, region `swedencentral`,
and the dedicated resource group `rg-ghrunners-spike7-swc`. The first ACA managed-environment deployment failed with
`ManagedEnvironmentCapacityHeavyUsageError` / `AKSCapacityHeavyUsage`: the region had insufficient managed-environment
capacity. A subsequent deployment could not use the failed environment, which was in state `Failed`.

The partial deployment did create the Key Vault `kvghr7696be5` with `publicNetworkAccess: Disabled`,
`defaultAction: Deny`, trusted-services bypass `None`, RBAC authorization and purge protection enabled, plus an
approved private endpoint and a user-assigned identity. The identity's **Key Vault Secrets User** assignment was
scoped to that vault only. The ACA environment resource reported `internal: true` and `publicNetworkAccess: Disabled`,
but its provisioning failed; no job execution or Key Vault resolution test occurred. Because no execution could run,
the trusted-services bypass was not toggled and its necessity cannot be inferred.

The failed **Create or Update Managed Environment** activity is correlated by
`d956ba0b-85e6-489a-a515-0b2359cc44d4` at `2026-10-07T15:52:39.4587816Z`. The deployment response reported
`ManagedEnvironmentCapacityHeavyUsageError` / `AKSCapacityHeavyUsage` (tracking ID
`23e12942-55b9-4b47-a121-560f0927c91c`; service request ID `0020c404-b43b-43b4-a5bb-e3ce940a1639` at
`2026-10-07T15:52:31Z`). The service message explicitly identified high regional AKS usage. Microsoft's troubleshooting
guidance describes this code as limited regional capacity caused by increased demand, and suggests retrying later or
changing regions. No quota or template-configuration error was returned. A second deployment invocation was rejected
before a fresh environment create because the first environment remained in `Failed` state
(`ManagedEnvironmentNotReadyForAppCreation`); it did not re-test regional capacity.

The one-off source used was `infra/spike-kv-ref-pe.bicep`; it was removed after the isolated resource group was deleted.
The secure parameter file `%TEMP%\\issue7-kvref-696be5.parameters.json` was also removed. **No reusable deployment or
cleanup script/template is currently committed.**

## Consequences

- Keep this behavior as a blocker for dependent platform decisions. Do not claim the `keyVaultUrl` private-endpoint
  path works or that trusted-services bypass is required or unnecessary.
- Keep production networking and Key Vault policy unchanged. The spike never enabled public network access.
- The read-only regional profile listing included Dedicated `D4` and `E4` profiles in `swedencentral`. Although those
  profiles are supported, changing from Consumption to a paid Dedicated profile does not address the reported
  region-capacity error and would change the cost model. Do not treat it as a workaround; retry the Consumption
  environment only after capacity recovery is coordinated.
- Re-run the controlled comparison in `swedencentral` when ACA capacity is available: use a synthetic secret, verify
  its value in the job using a non-secret comparison result, and compare Key Vault bypass `None` with
  `AzureServices` while keeping public network access disabled.
- Leave issue #7 open until both acceptance criteria are supported by job-execution evidence and the isolated spike
  resources are confirmed deleted.

## Status

**Blocked — unverified.** ARM what-if validation succeeded, but the ACA capacity failure prevented the experiment.
The dedicated issue-7 resource group was deleted and verified absent. The test Key Vault `kvghr7696be5` remains as a
soft-deleted tombstone with purge protection enabled; it was not purged. No resources in production or issue #6's spike
resource group were accessed or changed.
