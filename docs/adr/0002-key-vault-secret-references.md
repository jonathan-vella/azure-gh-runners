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
- [Workload profiles in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-overview)
- [Zone redundancy in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/how-to-zone-redundancy)
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
The secure parameter file `%TEMP%\\issue7-kvref-696be5.parameters.json` was also removed. The reusable, sanitized
experiment is now in `infra/spike7/main.bicep` with the bounded local runner in `infra/spike7/Invoke-Spike.ps1`.
`tools/validate-spike7.mjs` checks local artifact invariants without Azure access.

### Authorized D4 invocation: validation accepted, no deployment write

The single authorized D4 Deploy was invoked at `2026-10-07T19:52:11.8518132Z` from merged source
`e90e2ad18dd45a2032e1f5fd8e3bf32cd14fc564`, requesting `minimumCount=0`, `maximumCount=3`,
`zoneRedundant=false`, and no zone pinning. It created the exact tagged `rg-ghrunners-spike7-swc`, then the bounded
deployment CLI returned an unclassified failure. Its original stderr was discarded; the specific local cause remains
unknown. A local bounded Bicep build subsequently exited 0, which does not diagnose that CLI failure.

Supplied Azure activity evidence shows deployment **validate** Started at `2026-10-07T19:52:36.502117Z` and
Accepted at `2026-10-07T19:52:40.9865282Z`, correlation `e966fd8b-8aa2-489a-9e1a-fd8b8b0e1ce5`, plus a policy
append for the planned NAT IP. Deployment and resource counts were both zero: no deployment write or ACA
environment write was observed. Environment creation was therefore not observed as requested; validation of a planned
environment is not a create request. **This invocation is not an ACA capacity failure.** No Test ran, no new vault
was created, and no private-endpoint resolution or D4 node allocation was tested.

The original outer command attempted to list operations for the nonexistent deployment inside `finally`; that
diagnostic threw before Cleanup could run. The operator immediately positively verified the exact tagged empty group
and ran the reviewed Cleanup successfully: deletion was accepted at `2026-10-07T19:53:50.7002181Z`, then the group
was verified absent. No second Deploy is authorized by this correction.

## Consequences

- Keep this behavior as a blocker for dependent platform decisions. Do not claim the `keyVaultUrl` private-endpoint
  path works or that trusted-services bypass is required or unnecessary.
- Keep production networking and Key Vault policy unchanged. The spike never enabled public network access.
- The read-only regional profile listing included Dedicated `D4` and `E4` profiles in `swedencentral`. The operator
  has authorized one isolated alternative-profile attempt with `D4`, `minimumCount=0`, `maximumCount=3`, and
  `zoneRedundant=false`, with no zone pinning. This authorization is not confirmation that regional capacity recovered
  and is not evidence of capacity recovery. The D4 CLI invocation above did not produce a deployment record or job
  execution. Because
  `minimumCount=0` can provision the managed environment without allocating any D4 node, environment provisioning
  must be recorded separately from successful D4 job placement and execution; only execution evidence can show that a
  D4 node was actually allocated. The job's `workloadProfileName` and the environment's profile/count/zone readback
  must match before comparison; `D4` provides 4 vCPU and 16 GiB per node in Sweden Central, and
  `zoneRedundant=false` is explicit with no zone pinning
  ([workload profiles](https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-overview);
  [zone redundancy](https://learn.microsoft.com/en-us/azure/container-apps/how-to-zone-redundancy)). Consumption
  remains non-zonal as in the original template's effective default; its profile counts and separate
  capacity-recovery gate are unchanged.
- The reusable experiment pins AVM modules to exact stable versions: public IP `0.13.0`, NAT Gateway `2.1.1`,
  NSG `0.5.3`, VNet `0.10.2`, private DNS zone `0.8.1`, user-assigned identity `0.6.0`, Key Vault `0.14.2`,
  private endpoint `0.12.1`, ACA managed environment `0.16.0`, and ACA job `0.7.2`. These are the latest stable tags
  checked in the public Bicep registry when the artifact was authored. The native private-DNS link and Key Vault
  secret resource APIs are pinned to `2024-06-01` and `2026-02-01`; the latter was confirmed in the approved
  subscription's `Microsoft.KeyVault` provider API versions and `Sweden Central` locations. The diagnostic image is
  pinned to Azure CLI `2.91.0` digest
  `sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044`, verified from the MCR manifest.
- The ACA subnet has the test's only NAT egress IP and an attached NSG: narrowly allow ACA platform-subnet traffic,
  Key Vault PE HTTPS, platform DNS, and HTTPS egress before explicit RFC1918 denies. The private-endpoint subnet has
  no public egress association. No inbound public endpoint is created.
- Re-run the controlled comparison in `swedencentral` when ACA capacity is available: use a synthetic secret, verify
  its value in the job using a non-secret comparison result, and compare Key Vault bypass `None` with
  `AzureServices` while keeping public network access disabled. Each bypass leg creates a new, uniquely named ACA job
  on the selected profile only after the managed environment's exact profile/count/zone settings have been read back
  and that leg's Key Vault policy verified, so success cannot come from reusing a pre-existing
  job's cached secret reference. A terminal job failure is recorded as that leg's failed result and the second leg
  still runs. Provisioning failure continues only when every failed ARM operation targets that fresh job and its
  structured error tree has only documented Key Vault `ForbiddenByFirewall` leaves, with only
  `DeploymentFailed`, `ResourceDeploymentFailure`, or `Forbidden` wrappers. The runner follows the linked AVM job
  child deployment only within the owned resource group to inspect the actual resource operation. This code means the client address is
  unauthorized and the caller is not a trusted service
  ([official error-code reference](https://learn.microsoft.com/en-us/azure/key-vault/general/common-error-codes)).
  No provider evidence currently establishes how ACA propagates this code; message-only errors, generic
  `KeyVaultSecretRefIdentityError`, unknown codes, capacity, template, authentication, and RBAC errors remain
  operational failures and abort. No new runtime evidence is claimed. Start/polling/stopped-execution errors also
  abort. The bypass is restored to `None` in `finally`. If neither leg succeeds, the experiment fails and reports
  both terminal statuses.
  Test requires `-EvidencePath` pointing to a new JSON file: each comparison leg persists its fresh job name,
  deployment name, execution name (null when job provisioning failed), environment provisioning state, exact
  workload-profile readback, job workload-profile readback, UTC timestamp, status, stage, and sanitized code before
  acceptance is evaluated. Resource-group deployment failures, `job-provisioning`, and `execution` are reported as
  separate stages; successful environment provisioning by itself is not reported as node allocation. Operational
  failures are recorded too; raw provider
  messages, secrets, and container logs are never persisted. Local mocks exercise the actual profile readback guard,
  structured network denial versus unrelated deployment failures, and terminal-status cases.
- Only after separate coordinator direction for a new attempt, use the D4 lifecycle command shown below.
  This explicit D4 confirmation does not mean capacity recovered. For a later Consumption retry, continue to require
  the coordinator's separate capacity-recovery confirmation and `-ConfirmCapacityRecovered`. Use `-Action Cleanup`
  only for the exact tagged issue-7 resource group after the attempt; each ARM command supplies the approved
  subscription explicitly. Deploy requires the exact absent
  resource group, creates a random synthetic value into an ACL-restricted temporary secure parameter file, and removes
  that file in a `finally` block. The test action is bounded, emits only sanitized statuses, stages, codes, and profile
  readback metadata, and restores bypass to `None` without ever enabling public access.
- Every Azure CLI subprocess in the spike runner, including account/scope checks, deployment diagnostics, environment
  and job readbacks, Key Vault updates, resource-group existence/deletion, and cleanup polling, goes through one
  wrapper using the shared KEDA bounded-process helper. Each subprocess is limited by the remaining action deadline;
  redirected output is drained, timed-out process trees are killed and termination confirmed, streams/process handles
  are disposed, and CLI diagnostics are reduced to an allowlisted error code or suppressed. Cleanup treats an exact
  resource-group absence as idempotent success, while a failed/ambiguous existence read or ownership mismatch stops
  without deletion. Local tests exercise a real synthetic hanging subprocess and assert runtime call paths cannot
  bypass the wrapper.
- `Invoke-Lifecycle.ps1` requires the approved scope, profile authorization, and positively absent group before
  entering the lifecycle. Deploy/Test, diagnostics, and Cleanup are independent: diagnostic failure cannot skip
  Cleanup, and an aggregate error retains original, diagnostic, and cleanup errors in order. The deployment wrapper
  retains the original CLI exit, fixed safe category, allowlisted error code and structured correlation ID when
  available; absent/failed readback is supplemental, never a replacement. No raw arguments or provider messages are
  printed or stored. Categories distinguish Bicep, local file, CLI arguments, authentication, validation, ARM, and
  unclassified failures; they do not invent a cause for the invocation above.
- Cleanup independently checks exact ownership and deployment inventory. Positive group absence is idempotent success;
  positive deployment absence requires an explicitly empty owned group. Failed/invalid inventory is not absence.
  Existing deployments must be `Succeeded`, `Failed`, or `Canceled` before deletion; active/unknown states are polled
  within the cleanup deadline, then fail closed. A timed-out client does not establish ARM completion. There is no
  automatic retry or cancellation, and cleanup failure remains visible even when diagnostics or Deploy failed.

  ```powershell
  .\infra\spike7\Invoke-Lifecycle.ps1 `
      -SubscriptionId b47d2942-f5ad-4d3c-b28e-c23e4f83d97e `
      -ResourceGroupName rg-ghrunners-spike7-swc `
      -Profile D4 -ConfirmD4ProfileAttempt `
      -EvidencePath .\issue7-d4-comparison.json
  ```

- Leave issue #7 open until all acceptance criteria are supported by job-execution evidence and the isolated spike
  resources are confirmed deleted.

## Status

**Blocked — unverified.** The earlier Consumption attempt failed on ACA capacity. The later authorized D4 invocation
reached accepted ARM validation but no deployment/environment write; its original CLI cause is unknown, not capacity.
The dedicated issue-7 resource group was deleted and verified absent. The test Key Vault `kvghr7696be5` remains as a
soft-deleted tombstone with purge protection enabled; it was not purged. No resources in production or issue #6's spike
resource group were accessed or changed.
