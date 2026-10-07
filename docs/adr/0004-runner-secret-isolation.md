# ADR-0004: Runner secret isolation

## Context

Backlog issue [#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9) requires proving that an Azure Container
Apps job can provide an application secret to an init container, hand off only a JIT configuration through an
`EmptyDir`, and keep container managed identity unavailable when `identitySettings` uses lifecycle `None`. A secret
used only by scale-rule authentication must not be exposed to either container.

The spike harness in `tools/spike-job-identity-init/` creates a dedicated, internal-only workload-profiles environment,
private ACR and Key Vault endpoints, and a user-assigned identity. It uses a randomly generated synthetic canary, never
the GitHub App key. The probe image is imported into private ACR and pinned by digest. The init container checks the
canary against a locally computed hash without printing it, then writes a non-secret placeholder JIT document to an
`EmptyDir` file with mode `0400`. The main container checks the file and verifies that its identity endpoint and
secret-related environment variables are absent.

The harness does not call GitHub or test a real App key or JIT configuration. Those checks require the protected
`platform-prod` secrets and belong behind the gated deployment path.

## Decision

**No production decision is accepted.** The 2026-10-07 deployment attempt stopped at Container Apps environment
provisioning with `ManagedEnvironmentCapacityHeavyUsageError` / `AKSCapacityHeavyUsage` in `swedencentral`. ARM
preflight also rejected ACR API `2026-05-01` as unsupported in this region; the harness now pins ACR to the latest
stable version reported for this region, `2025-11-01`. No job ran and none of the issue's runtime acceptance criteria
were demonstrated. Do not repeat the full resource deployment until the regional capacity blocker changes; do not
switch regions.

The private ACR and Key Vault are reachable only through private endpoints; public network access is disabled. The
Container Apps environment is internal with public network access disabled. The UAMI has only `AcrPull` on the
spike ACR and `Key Vault Secrets User` on the spike vault. The harness's bounded cleanup wait timed out, after which
the exact issue-9 environment and resource group were deleted and both resource groups were verified absent. Key Vault
purge protection is not bypassed.

## Consequences

- A successful job execution proves that the init secret reference resolved, the private image pull succeeded, and
  the init-to-main `EmptyDir` handoff passed its file-mode and content checks.
- `identitySettings.lifecycle: None` is accepted for this pattern only if the main container reports that
  `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are absent.
- The scale-only secret is verified in scale-rule auth and absent from both containers' environment declarations and
  runtime checks. This does not validate scaler polling or GitHub App authentication.
- The synthetic canary is not evidence that the real GitHub App key works. Production App authentication remains
  unverified until tested through the protected platform path.
- Deleting the spike resource group does not purge the Key Vault soft-delete tombstone; no vault purge is attempted.

## Status

**Proposed — blocked by regional ACA capacity.** The current run has no successful runtime evidence; see the
sanitized, criterion-by-criterion record in `tools/spike-job-identity-init/attempt.json`.
