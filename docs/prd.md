# PRD: Shared Azure self-hosted GitHub Actions runner platform

| Field | Value |
| --- | --- |
| Product | `azure-gh-runners` |
| Owner | @jonathan-vella |
| Status | Draft v1 |
| Related | [Plan](plan.md) · [Roadmap](roadmap.md) · [Backlog](backlog.md) · [Research: options](research-azure-runner-options.md) · [Research: public repo + private endpoints](research-public-repo-private-endpoints.md) |

## 1. Summary

A single, private-endpoint-only Azure platform that runs ephemeral self-hosted GitHub Actions runners for any of the
owner's GitHub repositories. Runners execute as Azure Container Apps (ACA) event-driven jobs inside a dedicated VNet so
consumer workflows can reach Azure resources that expose **only private endpoints**. Repositories opt in through a typed
consumer registry in this repo; nothing is project-specific.

## 2. Problem

- The owner's repositories are public and live under a personal GitHub account.
- The target Azure environment only permits private endpoints; PaaS public network access is denied.
- GitHub-hosted runners have no private network path, so jobs that need data-plane access (for example Terraform state
  in Blob Storage) cannot run. Workarounds that temporarily open public access are not allowed.
- GitHub-hosted larger runners with Azure VNet injection require a GitHub organization (Team or Enterprise Cloud).
- Personal accounts cannot share self-hosted runners across repositories; each runner registers to exactly one repo.
- GitHub warns that self-hosted runners on public repositories can be abused by fork pull requests.

## 3. Goals

1. Provide private-network runners to any onboarded repository without per-project infrastructure in this repo.
2. Expose nothing publicly inbound; the only public resource is the NAT Gateway egress IP.
3. Make runners ephemeral (one job, then destroyed) with no long-lived secret or managed identity reachable by job code.
4. Enforce a platform policy floor that makes public-repository use safe against fork pull requests.
5. Make onboarding deterministic and documented well enough for an AI agent to execute it end to end.
6. Keep idle cost near the fixed network and registry baseline (scale to zero).

## 4. Non-goals

- Replacing GitHub-hosted runners for ordinary CI (lint, test, PR checks) — those stay free on GitHub.
- Windows runners, Docker-in-Docker, GPU, or jobs above 4 vCPU / 8 GiB.
- npm trusted publishing / provenance (unsupported on self-hosted runners).
- Hosting consumer application infrastructure; consumers own their own private endpoints and resources.
- Onboarding any specific consumer (for example `apex-vnext`) — tracked separately in that consumer's repo.
- Migrating repositories into a GitHub organization.

## 5. Users

| Persona | Needs |
| --- | --- |
| Platform maintainer | Deploy, patch, rotate secrets, onboard/offboard consumers through PRs and gated workflows. |
| Consumer repository | A `runs-on` label that lands trusted jobs on a private-network runner. |
| AI agent | Unambiguous docs, typed contracts, and validators to onboard a repo or change the platform safely. |

## 6. Functional requirements

| ID | Requirement |
| --- | --- |
| FR-1 | One shared platform: VNet, internal ACA workload-profiles environment, ACR Premium, Key Vault, Log Analytics, NAT Gateway, private DNS zones. |
| FR-2 | One ACA event-driven job per onboarded repository, generated from `config/consumers/<name>.json`. |
| FR-3 | Scaling via the KEDA `github-runner` scaler using GitHub App authentication, repo scope, custom labels only (`noDefaultLabels`). |
| FR-4 | Each execution registers a single-use JIT runner, runs exactly one job, and terminates. |
| FR-5 | A pre-job hook rejects any job outside the platform floor and the consumer's allowlist before user steps run. |
| FR-6 | Consumers reach their private resources through private endpoints they create in the shared `snet-consumer-pe` subnet, resolved through platform-owned private DNS zones. |
| FR-7 | One generic runner image (git, jq, curl, az CLI, Bicep, Terraform, Node LTS, Python 3, pwsh), built on a GitHub-hosted runner, pushed to private GHCR, and imported by digest into private ACR (ADR-0001). |
| FR-8 | Platform deployed from this repo by GitHub-hosted workflows using OIDC: validation on PR, staged deploy (foundation with `deployJobs=false`, image import, then jobs with `deployJobs=true`) only through the main-only `platform-prod` workflow into the existing `rg-ghrunners-prod-swc`. |
| FR-9 | Weekly image rebuild and scheduled GitHub App key rotation reminders. |
| FR-10 | Platform outputs (subnet IDs, DNS zone IDs, labels) published for consumers. |

**Observability network exception:** The Log Analytics workspace uses standard Azure Monitor endpoints with
`publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` enabled; no AMPLS is deployed. Workspace local
authentication is disabled and Azure RBAC controls data access. These managed service endpoints are not inbound
runner/workload endpoints; this explicit exception is part of the architecture.

## 7. Security requirements

| ID | Requirement |
| --- | --- |
| SR-1 | No inbound workload endpoints. ACA environment internal with public network access disabled; ACR and Key Vault private-endpoint-only. Log Analytics is the documented exception: standard ingestion and query use enabled Azure Monitor service endpoints without AMPLS, with local authentication disabled and Azure RBAC controlling access. |
| SR-2 | Policy floor — public consumer repos: only `workflow_dispatch`, `schedule`, `push`, on the default branch. `pull_request`, `pull_request_target`, `workflow_run` always rejected. Private repos may opt into `pull_request`, never `pull_request_target`. Entries may only narrow the floor. |
| SR-3 | Floor enforced twice: by the registry validator in CI and by the runner pre-job hook at runtime (fail closed). |
| SR-4 | GitHub App private key lives only in Key Vault and the init container; the main runner container has no secret environment variables and no managed identity. |
| SR-5 | Runner subnet NSG denies traffic to private ranges other than the platform and consumer PE subnets. |
| SR-6 | Least-privilege RBAC; `Microsoft.App/jobs/start/action` never granted broadly. |
| SR-7 | All actions pinned by SHA; images pinned by digest; diagnostic logs for all resources. |
| SR-8 | Consumers must use GitHub Environments restricted to the default branch and exact-subject Entra federated credentials. |

## 8. Non-functional requirements

| ID | Requirement |
| --- | --- |
| NFR-1 | Region `swedencentral`; approved subscription `shared` (`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`); RG `rg-ghrunners-prod-swc`. |
| NFR-2 | Bicep with Azure Verified Modules at exact versions; CAF naming; governance-contract tags. |
| NFR-3 | Queue-to-start latency within the scaler polling interval plus container start (target: under 2 minutes). |
| NFR-4 | Idle compute cost zero (scale to zero); fixed baseline ≈ USD 110/month (network, private endpoints, ACR Premium). |
| NFR-5 | Every change validated by a single local command and a required PR check. |

## 9. Constraints and assumptions

- v1 uses ACA jobs only; VMSS Flex is rejected for v1 ([ADR-0006](adr/0006-vmss-flex-spike.md)). No further spikes are
  planned.
- ADR-0001 to ADR-0005 record default decisions (GHCR → `az acr import` image path, Key Vault references, NAT egress,
  init-container isolation, custom-label routing). They are proven by the real deployment and the smoke test, not by
  separate spikes; each ADR names its fallback.
- Consumer jobs share the runner subnet and the consumer PE subnet; isolation between consumers relies on RBAC and
  data-plane authentication (accepted residual risk for v1).

## 10. Success metrics

- Definition of done: a smoke workflow in public repo `jonathan-vella/ghr-smoke` runs on the real ACA runner and lists an
  anonymous-read, empty blob container in a storage account with public network access disabled, reached only through a
  private endpoint in `snet-consumer-pe` (backlog item `smoke-consumer`).
- Zero PaaS resources with public network access enabled (automated post-deploy check).
- An agent onboards a new repo using only `docs/onboarding-consumer.md`.
- No runner registration persists after its job completes.

## 11. Risks

| Risk | Mitigation |
| --- | --- |
| Fork PR runs code on a runner | Policy floor (validator + hook), custom labels only, fork-approval setting, environment branch rules, exact OIDC subjects. |
| App key compromise grants repo admin on all installed repos | Key only in KV + init container, selected-repo installation, rotation cadence. |
| Image import into private ACR fails | ADR-0001: GHCR digest import with ACR trusted-services bypass; failures stop the staged deploy before jobs. |
| Cross-consumer lateral movement | NSG lateral deny, RBAC; escalation path to per-consumer subnet/environment. |
| Undocumented platform behaviour | Default ADRs with recorded fallbacks, proven by the real deploy and `ghr-smoke` smoke test. |

## 12. Release criteria (v1.0)

See [Roadmap](roadmap.md) milestone M6 and backlog item `acceptance`.
