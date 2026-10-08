# ADR-0003: Egress requirements for KEDA polling

## Context

Backlog issue [#8](https://github.com/jonathan-vella/azure-gh-runners/issues/8) asked whether the Azure Container Apps
`github-runner` scaler's requests to `api.github.com` originate inside the customer VNet and traverse its subnet NSG and
NAT Gateway, or originate from the managed Container Apps platform.

The KEDA `github-runner` scaler documentation describes GitHub App authentication and the REST API query chain: list
workflow runs and, for queued runs, list jobs. The scaler source creates an HTTP client for those GitHub API calls.
Microsoft Learn documents that Container Apps workloads in a workload-profiles environment use the supplied VNet
subnet and that outbound workload traffic uses an attached NAT Gateway. Neither source identifies the network origin
of the managed scaler's polling requests. They do not prove which egress path this platform uses.

## Decision

Attach the NAT Gateway to the ACA subnet and allow outbound HTTPS (443) to the Internet from that subnet, after the
explicit allows for platform and consumer private-endpoint subnets and before the RFC1918 lateral-movement denies.
All runner and scaler destinations below are therefore reachable without enumerating GitHub IP ranges. Where the
managed KEDA scaler's polling originates (customer subnet or ACA platform) is **observational only** and is not an
acceptance criterion: the design works either way.

The function-based destination list for reference:

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

All listed connections are outbound HTTPS. Not every consumer workflow needs every destination. GitHub documents that
CNAME targets can change; do not freeze GitHub IP addresses.

This is the chosen default; no live evidence is claimed. The real `platform-prod` deployment and the `ghr-smoke`
smoke test will prove that the scaler wakes the job and the runner reaches GitHub through this path.

## Consequences

- The NAT Gateway public IP remains the only public IP resource and is outbound-only; no inbound endpoint is added.
- Tightening egress to an FQDN allowlist (for example, Azure Firewall) is a later option, not a v1 requirement.
- No further spike runs. The archival harness (`.github/workflows/spike-keda-egress.yml`, `tools/spikes/keda-egress/`)
  is not part of validation.

## Status

Accepted (default, pending live smoke), 2026-10-08.

## References

- [KEDA GitHub Runner scaler documentation](https://keda.sh/docs/2.20/scalers/github-runner/)
- [KEDA GitHub Runner scaler source](https://github.com/kedacore/keda/blob/main/pkg/scalers/github_runner_scaler.go)
- [Azure Container Apps networking](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- [Azure Container Apps virtual networks and NAT Gateway integration](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [GitHub self-hosted runner communication requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#communication)
- [GitHub Actions OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc)
- [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)
