# ADR-0004: Runner secret isolation

## Context

Backlog issue [#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9) asked how an Azure Container Apps job can
give the GitHub App key to an init container, hand off only a JIT configuration through an `EmptyDir`, keep container
managed identity unavailable with `identitySettings` lifecycle `None`, and keep a scale-rule-only secret out of both
containers.

The 2026-10-07 spike harness ([`tools/spike-job-identity-init/`](https://github.com/jonathan-vella/azure-gh-runners/tree/25c0519b2a5cf9bf718091b18d0451b52af79aae/tools/spike-job-identity-init), since removed from the tree; see git history at commit [`25c0519`](https://github.com/jonathan-vella/azure-gh-runners/tree/25c0519b2a5cf9bf718091b18d0451b52af79aae)) stopped at Container Apps environment
provisioning with `ManagedEnvironmentCapacityHeavyUsageError` / `AKSCapacityHeavyUsage` in `swedencentral`. No job ran;
its resource groups were deleted and verified absent. No further spikes will run.

## Decision

- The **init container** receives the GitHub App key through a job secret (see
  [ADR-0002](0002-key-vault-secret-references.md)), mints a single-use repository JIT configuration, and writes it to an
  `EmptyDir` volume readable only by the runner user. It never logs the key or the JIT configuration.
- The **main runner container** has no secret environment variables and no usable managed identity. It reads and
  deletes the JIT file, then runs the runner with that configuration.
- The job's user-assigned identity uses `identitySettings.lifecycle: None`, so neither container can obtain a
  managed-identity token; the platform still uses the identity for image pull and Key Vault reference resolution.
- The scale-rule authentication references the App key secret without exposing it as container environment.

This is the chosen default. **Live evidence (2026-10-11):** on the real deployment, with `lifecycle: None`, the identity
environment variables (`IDENTITY_ENDPOINT`, `IDENTITY_HEADER`, `MSI_ENDPOINT`, `MSI_SECRET`) are still **set** inside the
main container, contrary to the Microsoft documentation, so a "variables are unset" assertion fails. What matters is
that no token is obtainable: from inside the runner, a token request to `IDENTITY_ENDPOINT` returned HTTP 400 both for
the system-assigned identity and for the platform's user-assigned identity requested explicitly by client ID
(ghr-smoke run 38147983595 (repository since removed)). The smoke workflow
therefore asserts "no usable managed identity" (no 200 token), not variable absence. This is one run against one job;
it is not a proof that no other route to an Azure token exists.

## Consequences

- A compromised job step cannot read the App key or obtain an Azure token from the main container.
- The identity variables being present is harmless only while the platform keeps refusing tokens; re-run the smoke
  check after any ACA platform or `identitySettings` change.
- The App key remains high value; keep the GitHub App installation limited to selected repositories and rotate it.
- `Microsoft.App/jobs/start/action` must not be granted broadly because it can expose job secrets.

## Status

Accepted, live-verified once on 2026-10-11 (token refused for both identities); see the evidence above.
