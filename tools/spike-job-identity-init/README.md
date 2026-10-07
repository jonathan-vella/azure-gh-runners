# Issue #9: init-container secret-isolation spike

This spike is scoped to `rg-ghrunners-spike9-swc` in `swedencentral` in subscription
`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`. It verifies the ACA job secret/identity boundary with a synthetic random
canary, not the real GitHub App key. It does not change the approved region or production resource group.

## Run

Prerequisites: Azure CLI authenticated to the approved subscription, Bicep 0.48.1 or later, PowerShell 7 on Windows,
Python 3, and permission to create resources and scoped role assignments in the subscription.

```powershell
.\tools\spike-job-identity-init\run.ps1 -Mode Prepare
```

`Prepare` requires the issue-9 resource group to be absent, creates only the tagged private network, ACR, Key Vault,
private endpoints, and scoped identity, then writes a non-secret `prepared.json` manifest. It intentionally does not
create an ACA environment. The manifest gives the exact issue-9 ACR destination for the approved private image
transfer and stores only the locally computed SHA-256 of the synthetic Key Vault canary; the raw canary is never
persisted in the manifest. Do not access or modify issue-6 resources; coordinate approval for use of its private
transfer path.

After that path transfers the image to the exact registry and privately reads back the destination digest, save a
receipt in this shape:

```json
{
  "issue": 9,
  "subscriptionId": "b47d2942-f5ad-4d3c-b28e-c23e4f83d97e",
  "resourceGroup": "rg-ghrunners-spike9-swc",
  "registryName": "<registryName from prepared.json>",
  "repository": "probe",
  "digest": "sha256:<64 lowercase hex characters>",
  "destinationDigestReadBack": "sha256:<same digest>",
  "privateEndpointApproved": true,
  "sourcePath": "issue-6-private-agent-pool-transfer",
  "verifiedBy": "<operator>",
  "verifiedAtUtc": "<UTC timestamp>"
}
```

The receipt is an operator-attested record from the approved private transfer/readback path; the local harness does
not query ACR's private data plane. It rejects a missing receipt, a mismatched registry/repository/digest, or an
unapproved private endpoint before creating any ACA resource. No public import, trusted-service bypass, or
out-of-VNet ACR query is used.

Only after independently confirming that the `swedencentral` ACA capacity blocker has recovered, run:

```powershell
.\tools\spike-job-identity-init\run.ps1 -Mode Test `
  -ProbeImageDigest 'sha256:<preloaded-image-digest>' `
  -ImageTransferReceipt '.\image-transfer-receipt.json' `
  -ConfirmCapacityRecovered
```

The explicit switch is a human capacity-recovery gate, not an automated capacity check. `Test` verifies the prepared
ARM resources, image receipt, private ACR/Key Vault access configuration, and resource-group ownership before
creating the ACA environment and job. It always runs bounded cleanup in `finally`. Use `Cleanup` to remove an
abandoned prepared group without running a test:

```powershell
.\tools\spike-job-identity-init\run.ps1 -Mode Cleanup
```

Synthetic secrets are passed through temporary ARM parameter files under a current-user-only ACL. Files are deleted
after deployment and again in `finally`; secret values are never command-line arguments or printed. Azure CLI
failures expose only the exit code and a fixed allowlisted Azure error code, never raw diagnostics. The script writes
`evidence.json` only after every runtime assertion succeeds. Cleanup refuses any resource group that violates the
approved issue-9 ownership tags or contains an unrecognized resource. Key Vault purge protection remains enabled;
the script never purges a vault.

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
  handoff file, checks identity endpoint variables are absent, and sends a valid IMDS token request with
  `Metadata: true` directly, bypassing environment proxies. Only an explicit `invalid_request` response identifying
  a missing identity counts as isolation evidence; a successful response, malformed-request error, or connectivity
  failure fails the probe.
- Both containers hash environment values and fail if any equals the scale-only synthetic canary. The main process
  also checks for the init app-key canary by hash. The raw canaries and their values are not logged; the main process
  has no secret references or secret environment variables.
- The event rule references a synthetic secret only through its `auth` block. The probe does not test queue polling.
- The diagnostic ACA subnet NSG allows required Azure platform egress, private endpoint HTTPS, and Azure DNS, then
  denies RFC1918 lateral ingress and egress. No public inbound endpoint is enabled; NAT remains outbound-only.
- A successful execution from the preloaded, digest-pinned private ACR image, with the private Key Vault reference
  configured, is evidence for those platform paths. It is not evidence of real GitHub App authentication.
- The image-transfer dependency is issue #6's approved private agent-pool/build-transfer path. Prepare targets the
  newly created issue-9 ACR so the operator-approved transfer must be directed there; Test requires its immutable
  digest and destination readback receipt before creating an ACA environment or job.

Run the no-cloud unit tests with `npm run validate:spike`; they exercise digest and receipt rejection, capacity
confirmation, canary-hash leak detection, deployment failure assertions, governance-tag and compiled NSG rule
checks, and cleanup inventory ownership. IMDS tests verify the request URL/header and proxy bypass, accept only the
explicit missing-identity response, and reject successful, malformed-request, and connectivity-failure outcomes.
On POSIX systems, the main probe tests also create a handoff file owned by UID/GID 65532 and run the reader as that
non-root identity, verifying the actual read and delete permissions. This integration test is skipped on Windows,
where POSIX UID/GID switching is unavailable.

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
untested. Do not run `Test` until the regional capacity error is independently confirmed recovered.

## Official references

- [Containers and init containers](https://learn.microsoft.com/en-us/azure/container-apps/containers)
- [Manage secrets and Key Vault references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Private ACR image pulls with managed identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity-image-pull)
- [Ephemeral `EmptyDir` storage](https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts)
- [Jobs REST API, version 2026-07-01](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/jobs/create-or-update?view=rest-resource-manager-containerapps-2026-07-01)
