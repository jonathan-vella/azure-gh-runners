# ADR-0003: Egress requirements for KEDA polling

## Context

Backlog issue [#8](https://github.com/jonathan-vella/azure-gh-runners/issues/8) asks whether the Azure Container Apps
`github-runner` scaler's requests to `api.github.com` originate inside the customer VNet and traverse its subnet NSG and
NAT Gateway, or originate from the managed Container Apps platform.

The KEDA `github-runner` scaler documentation describes GitHub App authentication and the REST API query chain: list
workflow runs and, for queued runs, list jobs. The scaler source creates an HTTP client for those GitHub API calls.
Microsoft Learn documents that Container Apps workloads in a workload-profiles environment use the supplied VNet
subnet and that outbound workload traffic uses an attached NAT Gateway. Neither source identifies the network origin
of the managed scaler's polling requests. They do not prove which egress path this platform uses.

## Decision

**No platform egress decision is accepted yet.** Do not conclude that `api.github.com` must be allowed from the runner
subnet, or that scaler polling is outside that subnet, until the protected, GitHub App-authenticated Azure spike has
produced network evidence.

The egress requirements to test and document are:

| Component | Destination | Purpose |
| --- | --- | --- |
| KEDA `github-runner` scaler | `api.github.com:443` | GitHub App authentication and queued workflow/job queries. |
| Runner, essential | `github.com:443`, `api.github.com:443`, `*.actions.githubusercontent.com:443` | Runner registration, job assignment, and Actions service communication. |
| Runner, action downloads | `codeload.github.com:443` | Download action source. |
| Runner, logs/artifacts/caches | `results-receiver.actions.githubusercontent.com:443`, `*.blob.core.windows.net:443` | Upload and download job results. |
| Runner, updates | `objects.githubusercontent.com:443`, `objects-origin.githubusercontent.com:443`, `github-releases.githubusercontent.com:443`, `github-registry-files.githubusercontent.com:443`, `release-assets.githubusercontent.com:443` | Runner updates and release assets, if enabled or used. |
| Runner, packages/images | `*.pkg.github.com:443`, `pkg-containers.githubusercontent.com:443`, `ghcr.io:443` | GitHub Packages and container images, only when workflows or image pulls use them. |
| Runner, optional workflow features | `github-cloud.githubusercontent.com:443`, `github-cloud.s3.amazonaws.com:443`, `dependabot-actions.githubapp.com:443` | Git LFS and Dependabot workflows, when used. |
| Runner, Azure access | `login.microsoftonline.com:443`, `management.azure.com:443`, plus the specific private endpoints used by a workflow | Azure identity and management/data-plane access, only for workflows that use Azure. |

All listed connections are outbound HTTPS. This is a function-based allowlist, not a claim that every consumer workflow
needs every destination. GitHub documents that CNAME targets can change and that workflows may require additional
destinations; use FQDN-aware egress controls where available rather than freezing GitHub IP addresses.

## Consequences

- The test uses the real GitHub App credentials from the existing `platform-prod` environment. The pinned workflow
  writes the protected key to the private spike Key Vault through a secure ARM parameter file; it never configures an
  ACA job secret with an inline value, prints the key, or retrieves it.
- Run the test only from `main` through `platform-prod`, preserving its required reviewer and main-only branch policy.
  Its OIDC credential is a separate issue #8 user-assigned identity with Contributor only at the spike resource-group
  scope and Key Vault Secrets Officer only at the spike vault. Do not broaden the existing production identity.
  The diagnostic ACA job has its own user-assigned identity with Key Vault Secrets User only at that vault, and its
  identity lifecycle is `None` so the container cannot obtain a managed-identity token.
- The prepared harness is `.github/workflows/spike-keda-egress.yml` and `tools/spikes/keda-egress/`. After the
  protected `oidc-preflight` workflow run, copy its bounded subject claim into
  `pwsh ./tools/spikes/keda-egress/bootstrap.ps1 -Mode Prepare -OidcSubject '<verified subject>'`. This creates the
  tagged issue #8-only prerequisites and isolated OIDC identity; do not guess or substitute the subject value. Run
  this Azure setup only after the separate issue #7 capacity blocker is resolved. The operator adds the printed
  client ID as the `platform-prod` environment secret `AZURE_SPIKE8_CLIENT_ID`; the tenant and subscription secrets
  remain the existing approved values. No Azure role is added to the production deployment identity.
- The `oidc-preflight` workflow mode runs only on `main` through the required `platform-prod` reviewer gate and makes
  no Azure calls. It decodes the ephemeral token in memory and logs only the allowlisted issuer, audience, and exact
  immutable repository/environment subject; it never logs the JWT. The verified subject is
  `repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod`. Use that observed subject to
  create the dedicated workflow identity's federated credential before selecting `test`.
- Before dispatching the gated test, place `synthetic-queue.yml` in the default branch of private `ghr-smoke`, dispatch
  that workflow, and confirm its `ghr-spike8-probe` job is queued. Pass that queued run's URL to the issue #8 workflow.
  Dispatch only from `main`, confirm `run-spike8`, and let the required `platform-prod` reviewer approve it; do not
  bypass the gate. The workflow captures KEDA system-log events and the scale-job execution correlated with the
  queued custom-label run in both GitHub API allow and deny phases, along with the separate workload probe and NAT
  metrics.
- The workflow deletes only named issue #8 resources and scoped role assignments. Afterward, remove the
  `AZURE_SPIKE8_CLIENT_ID` environment secret manually, then remove the now-empty group and its role assignment with
  `pwsh ./tools/spikes/keda-egress/bootstrap.ps1 -Mode CleanupGroup`. Do not delete resources from issue #6, issue #7,
  or production.
- Container Apps operations use the exact stable ARM API version `2026-07-01`; the environment is internal with
  `publicNetworkAccess` disabled, and the diagnostic image is digest-pinned. KEDA service events are read through the
  pinned Azure CLI Container Apps log-stream extension; no Log Analytics public query endpoint or additional PaaS
  workspace is introduced.
- Compare NAT Gateway metrics before and during the configured real-App-auth scale rule, and run a short, recorded deny
  test against the resolved GitHub API destination if metrics alone are ambiguous. Test runner-container egress
  separately so it is not mistaken for scaler traffic. Record exact metric intervals, NSG rule, scaler/job errors or
  responses, and the final resource-group cleanup result.
- The harness verifies the persisted Key Vault reference and identity lifecycle, collects sanitized KEDA system-log
  event metadata, records whether the scaler started an execution while the supplied synthetic run was queued, and
  compares those observations across allow and deny phases. The execution is service-level correlation, not a capture
  of an individual successful GitHub API response. NAT `ByteCount` remains aggregate subnet evidence and cannot by
  itself attribute bytes to KEDA or `api.github.com`; retain that distinction in any final conclusion.
- Keep the experiment bounded to 45 minutes. Delete only the dedicated issue #8 resource group and resources created
  for this spike. Do not touch the active issue #6/#7 spike groups or production resources.
- Do not provision the environment until the separate issue #7 regional Container Apps capacity blocker and the
  required `platform-prod` reviewer gate are resolved. Do not change regions or enable public access to work around
  capacity constraints.
- Until those observations exist, acceptance criterion 1 remains open and this ADR cannot be marked accepted.

## Status

**Proposed — empirical evidence is pending.** Official documentation and source inspection establish the API calls
and workload NAT behavior, but not the origin of the managed scaler's polling traffic. No Azure resources were created
for this record, and no acceptance criterion is claimed complete.

## References

- [KEDA GitHub Runner scaler documentation](https://keda.sh/docs/2.20/scalers/github-runner/)
- [KEDA GitHub Runner scaler source](https://github.com/kedacore/keda/blob/main/pkg/scalers/github_runner_scaler.go)
- [Azure Container Apps networking](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- [Azure Container Apps virtual networks and NAT Gateway integration](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [GitHub self-hosted runner communication requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#communication)
- [GitHub Actions OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc)
- [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)
