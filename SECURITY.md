# Security policy

## Supported versions

This is a small, single-maintainer project. There are no tagged releases yet, so only the current `main` branch is
supported. Fixes land on `main`; there are no backports.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately**. Do not open a public issue or pull request.

1. Go to the [Security tab](https://github.com/jonathan-vella/azure-gh-runners/security/advisories/new) and choose
   **Report a vulnerability** (GitHub private vulnerability reporting).
2. Describe the impact, the affected files or workflow, and reproduction steps. Never include live credentials,
   tokens, or private keys; describe where they would be exposed instead.

Expected response (best effort, no SLA):

- Acknowledgement within 7 days.
- A first assessment within 14 days, then updates as the fix progresses.
- Coordinated disclosure: a fix or mitigation is published first, then a GitHub security advisory crediting the
  reporter unless you prefer to stay anonymous.

If private reporting is unavailable for any reason, open a public issue that says only "I need to report a security
issue privately" and contains no details; the maintainer will arrange a private channel.

## Scope

In scope:

- The pre-job policy hook, consumer registry validation, and generated job parameters.
- The runner image and its entrypoint and initialization scripts.
- The Bicep in `infra/` and the workflows in `.github/workflows/`, including anything that weakens the invariants
  below.
- Documentation that would lead an adopter to an insecure setup.

Out of scope:

- Vulnerabilities in Azure, GitHub, the GitHub runner, or other upstream components. Report those upstream.
- Findings that require an attacker to already control the operator's Azure subscription, GitHub account, or
  GitHub App key.
- Misconfiguration of a fork or deployment that deviates from the documented setup.

## Security model in brief

The platform runs job code from GitHub repositories on self-hosted runners that sit in a private Azure network.
Self-hosted runners on **public** repositories are a well-known risk: anyone who can get a workflow to run executes
code in your network. The design therefore relies on several layers:

- **Policy floor.** Public consumer repositories may run only `workflow_dispatch`, `schedule`, and `push` on the
  default branch. `pull_request_target` and `workflow_run` are never allowed. The floor is enforced in registry
  validation and again in the runner's pre-job hook; a registry entry can narrow it, never widen it.
- **Ephemeral, unprivileged runners.** Each job gets a single-use runner. The job container receives no secret
  environment variables and no usable managed identity. The GitHub App key is confined to the init and scaling path.
- **No inbound endpoints.** Workload PaaS resources have public network access disabled. Log Analytics is the
  documented exception (standard endpoints, local authentication disabled, Azure RBAC). The NAT Gateway egress IP is
  outbound-only.
- **Scoped exception, not yet built.** The planned isolated Windows backend
  ([ADR-0007](docs/adr/0007-windows-vmss-isolated-runners.md)) may let a public consumer opt into `pull_request`
  for open same-repository pull requests only, on ephemeral workers with no identity or secrets and no link to the
  Linux platform. It is not implemented yet and does not change the floor for the Linux backend.

Residual risks remain: jobs on the same environment share a subnet, and the platform operator holds privileged
credentials. See [docs/security.md](docs/security.md) for the threat model, controls, and limits of assurance. That
document is being finalised for v1.0 and may lag the implementation.
