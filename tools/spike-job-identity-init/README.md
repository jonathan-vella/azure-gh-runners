# Issue #9: init-container secret-isolation spike

This spike is scoped to `rg-ghrunners-spike9-swc` in `swedencentral` in subscription
`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`. It verifies the ACA job secret/identity boundary with a synthetic random
canary, not the real GitHub App key. It does not change the approved region or production resource group.

## Run

Prerequisites: Azure CLI authenticated to the approved subscription, Bicep 0.48.1 or later, and permission to create
resources and scoped role assignments in the subscription. The script checks for a pre-existing resource group,
creates the uniquely named spike group, deploys the probe, and deletes that group in `finally`. Use `-Resume` only
when continuing the empty, issue-9-tagged group created by this spike.

```powershell
.\tools\spike-job-identity-init\run.ps1
```

The script sends secure values only as secure deployment parameters, never prints them, and writes
`evidence.json` only after every runtime assertion succeeds. It refuses cleanup if the group tags or its resource
inventory do not match this spike. The blocked 2026-10-07 attempt is recorded separately in `attempt.json`; it does
not claim any runtime criteria passed. Key Vault purge protection remains enabled; the script never purges a vault.

## Probe boundaries

- The init container resolves a Key Vault-backed `secretRef`, compares the synthetic value to a local SHA-256
  expectation, and writes only a fixed non-secret placeholder to a shared `EmptyDir` with mode `0400`.
- The main container verifies the file handoff, mode, absence of `IDENTITY_ENDPOINT` / `IDENTITY_HEADER`, and absence
  of the init/scale-only secret environment variables.
- The event rule references a synthetic secret only through its `auth` block. The probe does not test queue polling.
- A successful execution from the digest-pinned private ACR image, with the private Key Vault reference configured,
  is evidence for those platform paths. It is not evidence of real GitHub App authentication.

The infrastructure and job use the latest stable resource API versions reported for `swedencentral` by the approved
subscription's providers when authored: Container Apps `2026-07-01`, network `2026-05-01`, ACR `2025-11-01`, Key Vault `2025-05-01`,
managed identity `2024-11-30`, and private DNS `2024-06-01`. The current Bicep type bundle does not include schemas
for some of the latest network and ACR API versions, so Bicep emits `BCP081` warnings for those resources; the
deployment itself remains subject to Azure preflight validation.

## Current attempt

On 2026-10-07 the Container Apps environment failed preflight with
`ManagedEnvironmentCapacityHeavyUsageError` (`AKSCapacityHeavyUsage`) in `swedencentral`. The first preflight also
identified ACR API `2026-05-01` as unsupported for this region; the template now uses `2025-11-01`. The spike stopped
after the capacity error, did not try another region, and did not run a job. All runtime acceptance criteria remain
untested. Do not repeat the full deployment while the regional capacity error persists.

## Official references

- [Containers and init containers](https://learn.microsoft.com/en-us/azure/container-apps/containers)
- [Manage secrets and Key Vault references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Private ACR image pulls with managed identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity-image-pull)
- [Ephemeral `EmptyDir` storage](https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts)
- [Jobs REST API, version 2026-07-01](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/jobs/create-or-update?view=rest-resource-manager-containerapps-2026-07-01)
