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

- The deployment and test must use the real GitHub App credentials from the existing `platform-prod` environment.
  Do not copy, print, or retrieve the write-only private key.
- Run the test only from `main` through `platform-prod`, preserving its required reviewer and main-only branch policy.
  The workflow must be pinned and scoped to `rg-ghrunners-spike8-swc`; it must not broaden the production service
  principal's scope.
- Compare NAT Gateway metrics before and during real App-authenticated scaler polling, and run a short, recorded deny
  test against the resolved GitHub API destination if metrics alone are ambiguous. Test runner-container egress
  separately so it is not mistaken for scaler traffic. Record exact metric intervals, NSG rule, scaler/job errors or
  responses, and the final resource-group cleanup result.
- Keep the experiment bounded to 45 minutes. Delete only the dedicated issue #8 resource group and resources created
  for this spike. Do not touch the active issue #6/#7 spike groups or production resources.
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
