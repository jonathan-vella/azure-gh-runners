# ADR-0002: Key Vault secret references over private endpoints

## Context

Issue [#7](https://github.com/jonathan-vella/azure-gh-runners/issues/7) asked whether an Azure Container Apps (ACA)
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

Two isolated attempts on 2026-10-07 produced no job execution. The first failed ACA managed-environment provisioning
with `ManagedEnvironmentCapacityHeavyUsageError` / `AKSCapacityHeavyUsage` in `swedencentral`. A later D4 invocation
reached accepted ARM validation but no deployment or environment write; its cause is unknown and it is not a capacity
verdict. The spike resource group `rg-ghrunners-spike7-swc` was deleted and verified absent; the test vault
`kvghr7696be5` remains a soft-deleted tombstone with purge protection. No further spikes will run.

## Decision

Each runner job uses one user-assigned managed identity with only `AcrPull` on the ACR and **Key Vault Secrets User** on
the platform Key Vault. The GitHub App key is a job secret defined as a Key Vault reference (`keyVaultUrl`) resolved by
that identity. `identitySettings` sets the identity's `lifecycle` to `None`, so the main container gets no usable
managed identity (see [ADR-0004](0004-runner-secret-isolation.md)). The Key Vault keeps public network access disabled
and is reached through its private endpoint.

Fallback: if the live Key Vault reference deployment fails, set the App key as an ARM secure secret on the job
(`@secure()` parameter from `platform-prod`), keeping the same container isolation.

This is the chosen default; no live evidence is claimed. The real `platform-prod` deployment and the `ghr-smoke` smoke
test will prove it, including whether the Key Vault trusted-services bypass is needed.

## Consequences

- One identity for image pull and secret resolution keeps RBAC minimal and matches the existing deployment allowlist.
- Never enable Key Vault public network access to work around a failed reference; use the fallback.
- The archival spike harness under `infra/spike7/` and `tools/validate-spike7.mjs` is not part of validation.

## Status

Accepted (default, pending live smoke), 2026-10-08.
