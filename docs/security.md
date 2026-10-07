# Security model and threat analysis

## Scope and assurance

This document describes the intended shared Azure runner platform and the controls present in this repository. It is
not a claim that the platform is deployed or production-verified: the repository currently has no active consumer, and
the ACA foundation and network are IaC definitions rather than proof of a live deployment. The secret-isolation,
private Key Vault reference, and JIT-label ADRs remain Proposed; their ACA runtime acceptance criteria have not passed.
See the [ADR index](adr/README.md) and [implementation plan](plan.md).

Controls described as **implemented** are present in source and covered by the repository's offline validation where
applicable. **IaC-defined** means the configuration is checked in but has not been confirmed against deployed Azure
resources. **Pending runtime proof** means a protected, isolated Azure/GitHub test is still required. Static tests do
not establish runtime behavior.

## Trust boundaries

- GitHub workflow authors and maintainers decide which jobs request the consumer-specific runner label. A runner job
  executes repository workflow code and can reach the network destinations allowed to its ACA environment.
- The GitHub App key and any Azure identities are platform credentials, not job credentials. The design keeps the App
  key in Key Vault and the init/scaling path, and keeps secrets and usable managed identity out of the main runner.
  This isolation pattern remains **pending runtime proof**.
- Consumer private endpoints share `snet-consumer-pe`; jobs also share `snet-aca`. Private networking limits paths but
  does not by itself authorize access to a service or isolate one consumer from another.
- Platform deployment and job-start authority are trusted operator capabilities. They must not be delegated to
  consumer workflows or repository contributors.

## Threats and controls

| Threat | Controls in the repository | Assurance and residual risk |
| --- | --- | --- |
| Fork pull request runs untrusted code on a private-network runner | The registry policy and pre-job hook reject `pull_request` for public consumers; private consumers must explicitly opt in. The hook additionally requires an open, same-repository, non-fork PR, matching merge refs, an allowed base branch, and an allowlisted workflow. `pull_request_target` and `workflow_run` are always rejected. Invalid or missing policy/context fails closed. | Hook and registry logic are implemented and locally tested, but no live ACA hook execution or consumer smoke test is recorded. The hook runs before user steps, not before action downloads; action source can be downloaded before rejection. Consumer fork-approval settings are an onboarding responsibility, not evidence of platform enforcement. |
| Compromised consumer job reaches another consumer's resources | The ACA NSG allows outbound HTTPS to the shared platform and consumer private-endpoint subnets, then denies other RFC1918 destinations. Service-side Azure RBAC and data-plane authentication remain essential. | Network rules are IaC-defined, not live-verified. All jobs share the ACA subnet, and all consumer private endpoints share a subnet reachable on port 443; there is no per-consumer network boundary. A workflow with its own credentials, or a target service with overly broad authorization, can still access another consumer's data. |
| GitHub App private key is stolen from a runner or build path | The intended design stores the key in Key Vault, exposes it only to the init/scaling path, and hands the runner a single-use JIT configuration. The main runner is intended to have no secret environment variables or usable managed identity. | ADR-0004 is Proposed and blocked on ACA capacity; no real App key/JIT run or main-container identity test has succeeded. A compromised App key is high impact because its Administration write permission reaches every repository where the App is installed. Keep the installation limited to selected repositories and rotate the key through the approved process. |
| Unauthorized principal starts a secret-bearing ACA job | `Microsoft.App/jobs/start/action` can trigger a job execution and expose secrets available to that job. The deployment identity is behind the protected, main-only `platform-prod` environment. | Do not grant job-start permission broadly or to consumer identities. Any necessary operator grant must be limited to the specific ACA job/resource scope, assigned only to a trusted operator identity, and used through an approved protected workflow with review and audit. Confirm effective permissions before enabling consumers; an RG-level deployment role is powerful and is not evidence that job-start authority is isolated. |
| Malicious or compromised runner image/tool dependency | `image/Dockerfile` pins the upstream runner base by digest. `image/versions.json` pins tool versions and SHA-256 checksums; installation verifies checksums before extraction. The image removes passwordless sudo membership and the Docker daemon, and the runner receives no Docker socket. | The image source is hardened and offline contract checks exist, but this is not proof of a published, deployed image or its runtime provenance. The ACR build-path ADR remains Proposed; the successful Git-context spike is not a production image pipeline. Digest/checksum pinning does not prove upstream content is benign. Continue reviewed updates and assess image provenance/scanning before production use. |

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
  behind the protected `platform-prod` approval and `main` branch policy.
- Keep PR what-if and production deployment identities separate. The what-if identity is Reader-only; never reuse it
  for deployment. Do not add permissions to the existing production identity as a workaround for a blocked operation.
- Do not place App keys, Azure credentials, tokens, or JIT configuration in consumer policy, logs, generated artifacts,
  or job environment variables. The JIT configuration is sensitive bootstrap material and must not be logged or
  persisted outside the runner handoff.
- Preserve the documented Log Analytics exception: standard Azure Monitor ingestion and query endpoints are enabled
  without AMPLS; workspace local authentication is disabled and Entra/Azure RBAC governs access. This is not an
  inbound workload endpoint and must not be described as blanket private-endpoint-only access.
- `npm ci` reported five high-severity dependency audit findings. Their package-level details were not assessed or
  remediated in this documentation change; track and resolve current findings through the repository's
  dependency-maintenance process before release. Do not interpret this document as a clean dependency scan.

## Related material

- [PRD security requirements](prd.md#7-security-requirements) and [platform plan](plan.md)
- [Consumer registry and policy contract](consumer-registry.md)
- [Runner image controls and verification limits](../image/README.md)
- [Runner secret-isolation ADR](adr/0004-runner-secret-isolation.md) and [JIT-label ADR](adr/0005-runner-labels.md)
- [Identity bootstrap and RBAC boundaries](runbooks/bootstrap-identity.md)
- [Log Analytics network exception and diagnostics](observability.md)
