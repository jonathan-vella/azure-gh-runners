# Security model and threat analysis

## Scope and assurance

This document describes the shared Azure runner platform and the controls in this repository. The ACA platform is
**deployed** in `rg-ghrunners-prod-swc` and a real smoke run passed on 2026-10-11 ([smoke evidence](smoke.md)); the
design decisions in the [ADR index](adr/README.md) were live-verified for function that day. This is a lab-grade
assurance statement: one deployment, one smoke consumer, and no independent security assessment.

Assurance levels used below:

- **Live-verified**: observed on the real deployment.
- **Implemented**: present in source and covered by offline validation (`npm run validate`).
- **IaC-defined**: configuration is checked in; not separately confirmed against the deployed resource.
- **Not yet run**: an automated or manual check exists but has no recorded live result.

| Control | Level | Evidence |
| --- | --- | --- |
| Storage, Key Vault and ACR public network access disabled; ACA environment internal and not publicly reachable | Live-verified at deploy time | Deploy read-back assertions in `deploy.yml` (`publicNetworkAccess == Disabled`, environment `internal`), 2026-10-11 |
| Only public IP is the NAT gateway's, and no inbound endpoint | Implemented; live check not yet run | `tools/check-public-access.mjs` runs after every deploy and in `npm run validate` against fixtures; its first live result is the next deploy run |
| Private endpoint name resolution from a runner | Live-verified | Smoke storage resolved to `10.60.0.132` inside the runner |
| Consumer authenticates with its own Entra identity, no usable managed identity in the job | Live-verified (one run) | OIDC login and container listing succeeded; identity token requests returned HTTP 400 ([ADR-0004](adr/0004-runner-secret-isolation.md)) |
| App key reaches only Key Vault and the init container | Live-verified for function | Key Vault reference resolved over the private endpoint and the init container minted a JIT runner ([ADR-0002](adr/0002-key-vault-secret-references.md)); absence from the runner container is by configuration, not exhaustively tested |
| Pre-job hook rejects disallowed events, refs and workflows | Implemented (Bats and fixtures); live rejection not yet run | Negative workflows and assertions in [smoke.md](smoke.md#negative-checks) |
| Registry validator rejects policy-floor violations | Implemented | `npm run validate` |
| Staged deploy, image import by digest, jobs by digest | Live-verified | Successful `platform-prod` run ([ADR-0001](adr/0001-image-build-path.md)) |
| NSG denies lateral RFC1918 traffic outside the platform and consumer endpoint subnets | IaC-defined | `infra/modules/network.bicep`; no live deny test |
| Runner deregistered and scaled to zero after the job | Live-verified | Scale 0 to 1 to 0 observed; no registration remained |
| Windows backend controls | Live-verified (one run) | [ADR-0007](adr/0007-windows-vmss-isolated-runners.md); smoke run 38176888808 (repository since removed): job ran as a non-admin account on a Trusted Launch VM, got no managed identity token, could not reach the ACA platform network, and the VM, NIC, disk and runner registration were gone afterwards |

Residual risks are in the threat table, the shared-network section and the list at the end of this document.
See the [implementation plan](plan.md) for design context.

## Trust boundaries

- GitHub workflow authors and maintainers decide which jobs request the consumer-specific runner label. A runner job
  executes repository workflow code and can reach the network destinations allowed to its ACA environment.
- The GitHub App key and any Azure identities are platform credentials, not job credentials. The design keeps the App
  key in Key Vault and the init/scaling path, and keeps secrets and usable managed identity out of the main runner.
  Function was live-verified once ([ADR-0004](adr/0004-runner-secret-isolation.md)).
- Consumer private endpoints share `snet-consumer-pe`; jobs also share `snet-aca`. Private networking limits paths but
  does not by itself authorize access to a service or isolate one consumer from another.
- Platform deployment and job-start authority are trusted operator capabilities. They must not be delegated to
  consumer workflows or repository contributors.

## Threats and controls

| Threat | Controls in the repository | Assurance and residual risk |
| --- | --- | --- |
| Fork pull request runs untrusted code on a private-network runner | The registry policy and pre-job hook reject `pull_request` for public consumers; private consumers must explicitly opt in. The hook additionally requires an open, same-repository, non-fork PR, matching merge refs, an allowed base branch, and an allowlisted workflow. `pull_request_target` and `workflow_run` are always rejected. Invalid or missing policy/context fails closed. | Hook and registry logic are implemented and locally tested; a live smoke run accepted a permitted dispatch, but no live rejection of a disallowed event is recorded yet (see [negative checks](smoke.md#negative-checks)). The hook runs before user steps, not before action downloads; action source can be downloaded before rejection. Consumer fork-approval settings are an onboarding responsibility, not platform enforcement; at the time of writing the smoke repository uses GitHub's default approval policy, not `all_external_contributors`. |
| Compromised consumer job reaches another consumer's resources | The ACA NSG allows outbound HTTPS to the shared platform and consumer private-endpoint subnets, then denies other RFC1918 destinations. Service-side Azure RBAC and data-plane authentication remain essential. | Network rules are IaC-defined, not live-verified: a live deny test has not been run, although allowed private-endpoint access was observed. All jobs share the ACA subnet, and all consumer private endpoints share a subnet reachable on port 443; there is no per-consumer network boundary. A workflow with its own credentials, or a target service with overly broad authorization, can still access another consumer's data. |
| PR code runs on an isolated Windows worker (scoped exception, ADR-0007, PRD SR-9; backend live-verified for `workflow_dispatch`) | Workers are ephemeral, have no managed identity or secrets, sit in their own resource group and VNet with no link to the ACA platform, and are bounded by `maxRunners`, per-VM expiry, a janitor and self-shutdown (an optional budget only alerts). The consumer entry needs an explicit acknowledgement flag; the hook accepts only open same-repository (non-fork) PRs; `pull_request_target` and `workflow_run` stay rejected; fork-PR approval for all outside collaborators must be enabled and verified. | Infrastructure, orchestrator, deployment workflow and image are built and were exercised by one live smoke run (issues #93–#99); the `pull_request` path and the NSG outbound deny rules were not tested live. The worker NSG denies all inbound and all outbound internet ports except 443 and 80. A PR from a compromised collaborator account still runs its code on the worker; the residual is compute abuse and egress in a throwaway resource group. The orchestrator (an ACA job running only platform code) holds the GitHub App credential and VM-management rights and is the high-value component. |
| GitHub App private key is stolen from a runner or build path | The intended design stores the key in Key Vault, exposes it only to the init/scaling path, and hands the runner a single-use JIT configuration. The main runner is intended to have no secret environment variables or usable managed identity. | ADR-0004 and ADR-0002 are live-verified for function: the init container used the key to mint a JIT runner, and identity token requests from the runner returned HTTP 400. That is one run against one job, not a proof that no other route to a token exists. A compromised App key is high impact because its Administration write permission reaches every repository where the App is installed. Keep the installation limited to selected repositories and rotate the key through the [runbook](runbooks/github-app.md). |
| Unauthorized principal starts a secret-bearing ACA job | `Microsoft.App/jobs/start/action` can trigger a job execution and expose secrets available to that job. Production deployment uses the `platform-prod` environment, restricted to `main`; it does not require a human reviewer. Agents may merge only after repository validation passes and agent code review reports no blockers. | Do not grant job-start permission broadly or to consumer identities. Any necessary operator grant must be limited to the specific ACA job/resource scope, assigned only to a trusted operator identity, and used through an approved protected workflow with audit. Confirm effective permissions before enabling consumers; an RG-level deployment role is powerful and is not evidence that job-start authority is isolated. |
| Malicious or compromised runner image/tool dependency | `image/Dockerfile` pins the upstream runner base by digest. `image/versions.json` pins tool versions and SHA-256 checksums; installation verifies checksums before extraction. The image removes passwordless sudo membership and the Docker daemon, and the runner receives no Docker socket. | The image source is hardened and offline contract checks exist. The pipeline (GHCR build, `az acr import` by digest, ACA pull) ran live ([ADR-0001](adr/0001-image-build-path.md)), but that is not proof of image provenance or content. Digest/checksum pinning does not prove upstream content is benign. No image scanning or provenance attestation is in place; continue reviewed updates and assess scanning before sensitive use. |

## Shared-network residual risk and escalation

The initial design intentionally shares both the ACA runner subnet and consumer private-endpoint subnet. NSG rules
reduce reachability to explicitly allowed platform/consumer paths and HTTPS to private endpoints, but they do not
provide per-consumer segmentation. Consumer services must enforce their own identity, RBAC, and data-plane
authorization, and consumers must not assume that a private endpoint is isolated from other jobs on the platform.

If that residual risk is unacceptable, move the affected consumer to a dedicated subnet and preferably a dedicated
ACA environment with its own narrowly scoped network rules, identity and resource assignments, and deployment boundary.
Update DNS and private-endpoint placement accordingly, then verify the separation with a cross-consumer reachability
test before treating it as a control. This is an architecture change, not a registry-only setting.

## RBAC and operational safeguards

- Never assign `Microsoft.App/jobs/start/action` at subscription, resource-group, or broad platform scope to consumer
  principals. Where job-start is necessary for an operator workflow, scope it to the exact job and keep that workflow
  behind the main-only `platform-prod` workflow and audit its use; the environment does not require a human reviewer.
- Keep PR what-if and production deployment identities separate. The what-if identity is Reader-only; never reuse it
  for deployment. Do not add permissions to the existing production identity as a workaround for a blocked operation.
- The Linux VMSS controller-RBAC grant (issue #69) was withdrawn with [ADR-0006](adr/0006-vmss-flex-spike.md); do not
  add `Virtual Machine Contributor` or `Network Contributor` to the production identity. The deploy identity keeps
  `Contributor` plus the constrained `Role Based Access Control Administrator` (it can delegate only `AcrPull`, `AcrPush`
  and `Key Vault Secrets User`) at the platform resource group. The isolated Windows backend gets its own identity
  scoped to its own resource group ([ADR-0007](adr/0007-windows-vmss-isolated-runners.md)). Stop on any unexpected
  identity, scope, condition or assignment.
- Do not place App keys, Azure credentials, tokens, or JIT configuration in consumer policy, logs, generated artifacts,
  or job environment variables. The JIT configuration is sensitive bootstrap material and must not be logged or
  persisted outside the runner handoff.
- Preserve the documented Log Analytics exception: standard Azure Monitor ingestion and query endpoints are enabled
  without AMPLS; workspace local authentication is disabled and Entra/Azure RBAC governs access. This is not an
  inbound workload endpoint and must not be described as blanket private-endpoint-only access.
- Unresolved dependency audit findings remain a release concern. Assess and remediate them through the repository's
  dependency-maintenance process before release. This document does not claim a clean dependency scan.
- Automated public-access verification: `tools/check-public-access.mjs` is a post-deploy gate; see
  [operations](operations.md#public-access-check).

## Residual risks (v1)

- Consumers share `snet-aca` and `snet-consumer-pe`; there is no per-consumer network boundary.
- The App key's Administration write scope reaches every installed repository; limit the installation.
- The deploy environment has no human reviewer; `main` merges are gated by validation and one agent code review.
- Hook rejection, the NSG deny path and the public-access check have no recorded live result yet.
- Single-run evidence for identity-token refusal; the identity environment variables are present in the container.
- Outbound HTTPS to the internet is open by design; there is no FQDN allowlist.
- Log Analytics has public ingestion and query endpoints by documented exception.
- No image scanning or provenance attestation, and no independent security assessment.

## Related material

- [Architecture](architecture.md), [operations](operations.md) and [consumer onboarding](onboarding-consumer.md)
- [PRD security requirements](prd.md#7-security-requirements) and [platform plan](plan.md)
- [Consumer registry and policy contract](consumer-registry.md)
- [Runner image controls and verification limits](../image/README.md)
- [Runner secret-isolation ADR](adr/0004-runner-secret-isolation.md) and [JIT-label ADR](adr/0005-runner-labels.md)
- [Identity bootstrap and RBAC boundaries](runbooks/bootstrap-identity.md)
- [Log Analytics network exception and diagnostics](observability.md)
