# Issue #9: init-container secret-isolation spike

This spike is scoped to `rg-ghrunners-spike9-swc` in `swedencentral` in subscription
`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`. It verifies the ACA job secret/identity boundary with a synthetic random
canary, not the real GitHub App key. It does not change the approved region or production resource group.

## Run

Prerequisites: Azure CLI authenticated to the approved subscription, Bicep 0.48.1 or later, PowerShell 7 on Windows,
Python 3, and permission to create resources and scoped role assignments in the subscription. The probe image must already be
present under the `probe` repository in the isolated spike ACR through the approved issue-6 private build/transfer
path; pass its immutable digest.
The script rejects a missing or mutable digest before any Azure call. It does not use `az acr import` or query ACR's
private data plane from outside the VNet. Use `-Resume` only when continuing the empty, issue-9-tagged group created
by this spike.

```powershell
.\tools\spike-job-identity-init\run.ps1 -ProbeImageDigest 'sha256:<preloaded-image-digest>'
```

Synthetic secrets are passed through temporary ARM parameter files under a current-user-only ACL. The files are
deleted immediately after deployment and again in `finally`; secret values are never command-line arguments or
printed. ARM deployments are polled with bounded timeouts and canceled on timeout before cleanup. The script writes
`evidence.json` only after every runtime assertion succeeds and refuses cleanup unless the full approved governance
tag contract and resource inventory match. The blocked 2026-10-07 attempt is recorded separately in `attempt.json`;
it does not claim any runtime criteria passed. Key Vault purge protection remains enabled; the script never purges a
vault.

The spike resource group and taggable resources use the approved ownership tags: `application=ghrunners`,
`environment=spike`, `workload=gh-runners`, `owner=jonathan-vella`, `costcenter=platform-engineering`,
`tech-contact=jonathan-vella`, `technical-contact=jonathan-vella`, `sla=development`,
`backup-policy=none`, and `maint-window=none`. Diagnostic tags `project`, `issue`, `purpose`, and `expiresOn` are
additional, not replacements.

## Probe boundaries

- The init container resolves a Key Vault-backed `secretRef`, compares the synthetic value to a local SHA-256
  expectation, and writes only a fixed non-secret placeholder to a shared `EmptyDir`, owned by UID/GID 65532 and
  mode `0400`.
- The main process drops to UID/GID 65532 before inspection, verifies file ownership/mode, reads and deletes the
  handoff file, checks identity endpoint variables are absent, and verifies that an IMDS token request fails.
- Both containers hash environment values and fail if any equals the scale-only synthetic canary. The main process
  also checks for the init app-key canary by hash. The raw canaries and their values are not logged; the main process
  has no secret references or secret environment variables.
- The event rule references a synthetic secret only through its `auth` block. The probe does not test queue polling.
- The diagnostic ACA subnet NSG allows required Azure platform egress, private endpoint HTTPS, and Azure DNS, then
  denies RFC1918 lateral ingress and egress. No public inbound endpoint is enabled; NAT remains outbound-only.
- A successful execution from the preloaded, digest-pinned private ACR image, with the private Key Vault reference
  configured, is evidence for those platform paths. It is not evidence of real GitHub App authentication.
- The image-transfer dependency is issue #6's approved private agent-pool/build-transfer path. The harness refuses
  to start without the resulting immutable digest and does not bypass ACR private-network policy with public access,
  trusted-service import, or an out-of-VNet data-plane query.

Run the no-cloud unit tests with `npm run validate:spike`; they exercise digest rejection, canary-hash leak detection,
deployment failure assertions, governance-tag checks, and strict cleanup inventory ownership.

The infrastructure and job use the latest stable resource API versions reported for `swedencentral` by the approved
subscription's providers when authored: Container Apps `2026-07-01`, network `2026-05-01`, ACR `2025-11-01`, Key Vault
`2026-05-15`, managed identity `2024-11-30`, and private DNS `2024-06-01`. The current Bicep type bundle does not
include schemas for some of the latest network and ACR API versions, so Bicep emits `BCP081` warnings for those
resources; deployment remains subject to Azure preflight validation.

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
