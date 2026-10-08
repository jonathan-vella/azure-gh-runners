# ADR-0004: Runner secret isolation

## Context

Backlog issue [#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9) asked how an Azure Container Apps job can
give the GitHub App key to an init container, hand off only a JIT configuration through an `EmptyDir`, keep container
managed identity unavailable with `identitySettings` lifecycle `None`, and keep a scale-rule-only secret out of both
containers.

The 2026-10-07 spike harness (`tools/spike-job-identity-init/`, now archival) stopped at Container Apps environment
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

This is the chosen default; no live evidence is claimed. The real `platform-prod` deployment and the `ghr-smoke` smoke
test will prove it, including that no managed-identity token is obtainable inside the job.

## Consequences

- A compromised job step cannot read the App key or obtain an Azure token from the main container.
- The App key remains high value; keep the GitHub App installation limited to selected repositories and rotate it.
- `Microsoft.App/jobs/start/action` must not be granted broadly because it can expose job secrets.

## Status

Accepted (default, pending live smoke), 2026-10-08.
