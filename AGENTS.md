# Agent operating guide

This public repository defines a shared Azure platform for ephemeral, private-network GitHub Actions runners. The
platform is still being built; use the accepted design and issue dependencies rather than assuming planned components
already exist. Ordinary platform pull-request validation runs on GitHub-hosted runners. The stricter trigger policy
below applies to consumer jobs that target this platform's self-hosted runners.

## Start here

1. Read the [PRD](docs/prd.md), [plan](docs/plan.md), [roadmap](docs/roadmap.md), and [backlog](docs/backlog.md).
2. Work on an issue only after its dependencies are closed. Keep each branch and pull request scoped to one issue.
3. v1 is Azure Container Apps (ACA) jobs for Linux. Windows runners use a separate, isolated VMSS Flex
   backend ([ADR-0007](docs/adr/0007-windows-vmss-isolated-runners.md), tracked in #93; built, not yet live-verified); a Linux VMSS
   Flex backend in the private network stays rejected. No further spikes are planned. Follow the default decisions in
   `docs/adr/`; the real `platform-prod` deployment and the `ghr-smoke` smoke test prove them.
4. Check the relevant runbook before touching identity or GitHub App setup. These describe existing production resources;
   do not recreate them or change Azure/GitHub settings as part of ordinary repository work.
5. Run `npm run validate` after repository changes. Do not deploy the platform from a local checkout.
6. Lean merge bar: CI build plus `npm run validate` pass and one agent code review reports no blocking findings; the
   agent may then merge. Production deployment remains exclusive to the `platform-prod` workflow on `main`; the
   environment is main-only and does not require a human reviewer. The merge bar does not authorize local deployment.

## Repository map

| Path | Responsibility |
| --- | --- |
| `.github/` | Repository automation and policy configuration. `workflows/` is the home for CI and the gated deployment workflow; `CODEOWNERS` and Dependabot configuration are at this level. |
| `config/consumers/` | The sole source of consumer onboarding declarations, one `<name>.json` per repository. |
| `config/schema/` | Schema for validating consumer declarations. |
| `docs/` | Product requirements, implementation plan, roadmap, backlog, research, architecture and operational guidance. |
| `docs/adr/` | Architecture decisions (ACA-only defaults for Linux; ADR-0006 Linux VMSS rejected; ADR-0007 isolated Windows VMSS). |
| `docs/runbooks/` | Carefully scoped bootstrap procedures for Azure OIDC identities and the GitHub App. |
| `image/` | Runner image definition, initialization/entrypoint scripts, and pre-job policy hook. |
| `infra/` | Resource-group Bicep entrypoint and parameter file; reusable Bicep modules belong in `infra/modules/`. |
| `tools/` | Registry validation and generation tooling. |
| Removed spikes | The archival spike harnesses (`spikes/`, `infra/spike7/`, `tools/spike*`, `tools/spikes/`, spike workflows) no longer exist in the tree. They remain in git history at commit [`25c0519`](https://github.com/jonathan-vella/azure-gh-runners/tree/25c0519b2a5cf9bf718091b18d0451b52af79aae); do not restore or extend them. |
| Root config and manifests | `package.json` defines validation commands; `package-lock.json` pins Node dependencies; `bicepconfig.json`, `.markdownlint-cli2.jsonc`, `.editorconfig`, and `.gitignore` define repository tooling and conventions. |

Some directories currently contain only placeholders. Implement functionality in its assigned area as the related
issue is taken up; do not treat an empty scaffold as evidence that the design requirement is optional.

## Local validation

Prerequisites: Node.js/npm and Azure CLI with Bicep available, plus the test prerequisites in README.
Hook fixtures require Bash, git, jq, and curl on Linux, or Linux Docker on Windows. From the repository root, run:

```powershell
npm ci
npm run validate
```

`npm run validate` runs consumer schema, registry, and generator tests; validates active consumer entries against
GitHub visibility/default-branch metadata; checks generated consumer parameters for drift; builds and lints
`infra/main.bicep`, `infra/main.bicepparam`, and `infra/modules/network.bicep`; runs network tests, observability and
diagnostic-category checks, offline image contract tests, and pre-job hook tests; and lints Markdown with the
repository configuration. The PR workflow `.github/workflows/validate.yml` runs the same command on GitHub-hosted
runners. Use `npm run generate:consumers` to update
`infra/generated/consumers.json` after changing the registry. An empty registry passes without GitHub access; active
entries require GitHub CLI access to every registered repository. The command does not deploy resources or require an
Azure login. The live diagnostic-category check is a separate required preflight before setting
`enableDiagnostics=true`. Add future validators to the existing `validate` script so it remains the single documented
local check.

## Non-negotiable security and platform invariants

- **No inbound workload endpoints.** Workload PaaS resources must have public network access disabled. Log Analytics
  is the documented exception: standard ingestion/query endpoints remain enabled without AMPLS, while local
  authentication is disabled and Azure RBAC governs access. The NAT Gateway egress IP is the only public IP resource
  and is outbound-only.
- **Registry-only onboarding.** Onboard or remove a consumer only through `config/consumers/<name>.json`, validated
  by the registry tooling. Do not add ad hoc jobs or consumer-specific deployment parameters outside that flow.
- **Never relax the consumer policy floor.** Public consumer repositories may run only `workflow_dispatch`, `schedule`,
  and `push` on the default branch. Reject `pull_request`, `pull_request_target`, and `workflow_run` for public
  consumers; `pull_request_target` and `workflow_run` are never allowed. Private consumers may opt into
  `pull_request` only where the documented policy permits it. Registry entries may narrow, never widen, the floor.
  Enforce policy in both registry validation and the runner's pre-job hook. These restrictions do not prohibit ordinary
  GitHub-hosted platform PR validation. **The only authorized exception** (owner decision 2026-10-11, ADR-0007, PRD
  SR-9) applies to the isolated Windows backend alone (built, not yet live-verified): a public consumer may opt into `pull_request` when workers
  are ephemeral with no identity or secrets and no link to the ACA platform, the entry sets an explicit acknowledgement
  flag, the hook accepts only open same-repository (non-fork) pull requests, and fork-PR approval for all outside
  collaborators is enabled and verified. `pull_request_target` and `workflow_run` stay rejected everywhere, and the
  floor is unchanged for ACA. Any other relaxation needs an explicit owner decision.
- **Keep runner job code unprivileged.** The main runner container must receive no secret environment variables and no
  usable managed identity. GitHub App credentials are for the init/scaling path, not job steps.
- **Never commit or print secrets, keys, or tokens.** Do not put credentials in source, generated artifacts, logs, or
  command output. The lab owner accepts sharing secrets in chat, but that never permits committing them or printing
  them in logs.
- **Pin dependencies.** Pin GitHub Actions by full commit SHA and container images by digest. Bicep must use
  Azure Verified Modules at exact versions.
- **Preserve platform conventions.** Deploy to the approved `shared` subscription, in `swedencentral`, using CAF
  naming and governance tags. Do not change approved scopes or conventions without an explicit decision.
- **Keep deployment gated.** Production deployment belongs only to the protected `platform-prod` workflow. Do not
  deploy from a local checkout or another workflow. The workflow is restricted to `main`; its environment does not
  require a human reviewer. It deploys directly into the existing `rg-ghrunners-prod-swc` in stages: GitHub-hosted
  image build to private GHCR, foundation with `deployJobs=false`, `az acr import` by digest into ACR, then jobs with
  `deployJobs=true`. There is no spike-resource-group exception. The isolated Windows backend (ADR-0007) deploys only
  through its own protected `deploy-windows` workflow (main-only, dispatch-only), which reuses the `platform-prod`
  environment but signs in with the separate identity in `vars.WINDOWS_AZURE_CLIENT_ID`, scoped to its own resource
  group (`rg-ghrunners-win-swc`); never through the `platform-prod` workflow, never with the Linux identity, and never
  from a local checkout.
- **Keep RBAC changes exact.** Preserve the existing `AcrPull`, `AcrPush`, and Key Vault Secrets User role-assignment
  allowlist for `sp-ghrunners-platform-prod` at `rg-ghrunners-prod-swc`; stop on any unexpected state. The VMSS
  controller-RBAC authorization (issue #69) is withdrawn with ADR-0006. The Windows backend gets its own deploy identity (Owner on its own
  resource group only, so it can create the orchestrator role assignments) and an orchestrator identity with Virtual Machine
  Contributor, Network Contributor, AcrPull and Reader on its gallery only; do not widen `sp-ghrunners-platform-prod` for it. Do not change scopes, roles, identities, or
  conditions without an explicit decision.
- **Protect job-start permissions.** Never grant `Microsoft.App/jobs/start/action` broadly; it can expose job secrets.

## Documentation and runbooks

- [README](README.md) — project overview and local validation.
- [PRD](docs/prd.md) — goals, requirements, security and success criteria.
- [Plan](docs/plan.md) — approved architecture and implementation approach.
- [Roadmap](docs/roadmap.md) and [backlog](docs/backlog.md) — milestone gates, issues and dependencies.
- [Research: Azure runner options](docs/research-azure-runner-options.md) and
  [research: public repositories with private endpoints](docs/research-public-repo-private-endpoints.md) — design
  background.
- [ADR index](docs/adr/README.md) — decision record format and v1 decisions.
- [OIDC identity bootstrap](docs/runbooks/bootstrap-identity.md) — exact existing identity scope, verification, and
  GitHub bindings. Stop on unexpected state; do not recreate or expand permissions.
- [GitHub App runbook](docs/runbooks/github-app.md) — App permissions, installation scope, key handling, and rotation.
- [Observability](docs/observability.md) — Log Analytics network exception and diagnostic-settings contract.
- [Architecture](docs/architecture.md) — components, trust boundaries, network/DNS flow, staged deployment.
- [Consumer onboarding](docs/onboarding-consumer.md) — deterministic checklist to onboard a repository to the ACA backend.
- [Operations](docs/operations.md) — deploy, image rebuild, key rotation, recovery after resource-group deletion,
  troubleshooting.
- [Security model](docs/security.md) — threats, controls, residual risks, scoped Windows exception.
- [Smoke test](docs/smoke.md) — positive and negative smoke checks and how outcomes are observed.
- [Adopting this project](docs/adopting.md) — what to replace and the bootstrap order when you fork the repository.
- [Contributing](CONTRIBUTING.md) and [security policy](SECURITY.md) — contribution workflow and private vulnerability
  reporting.

## Change conventions

- Use one issue per branch and pull request; reference it in the PR body (for example, `Closes #3`).
- Use concise Conventional Commit messages.
- Keep changes within the issue's scope, follow existing scripts and naming, and update directly related documentation.
- Never use a local Azure deployment as a substitute for validation or for the protected deployment workflow.
