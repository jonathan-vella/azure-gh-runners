# Agent operating guide

This public repository defines a shared Azure platform for ephemeral, private-network GitHub Actions runners. The
platform is still being built; use the accepted design and issue dependencies rather than assuming planned components
already exist. Ordinary platform pull-request validation runs on GitHub-hosted runners. The stricter trigger policy
below applies to consumer jobs that target this platform's self-hosted runners.

## Start here

1. Read the [PRD](docs/prd.md), [plan](docs/plan.md), [roadmap](docs/roadmap.md), and [backlog](docs/backlog.md).
2. Work on an issue only after its dependencies are closed. Keep each branch and pull request scoped to one issue.
3. For M1 spikes, record the result as an accepted ADR in `docs/adr/` before implementing work that depends on it.
   Later changes must follow accepted ADRs.
4. Check the relevant runbook before touching identity or GitHub App setup. These describe existing production resources;
   do not recreate them or change Azure/GitHub settings as part of ordinary repository work.
5. Run `npm run validate` after repository changes. Do not deploy the platform from a local checkout.

## Repository map

| Path | Responsibility |
| --- | --- |
| `.github/` | Repository automation and policy configuration. `workflows/` is the home for CI and the gated deployment workflow; `CODEOWNERS` and Dependabot configuration are at this level. |
| `config/consumers/` | The sole source of consumer onboarding declarations, one `<name>.json` per repository. |
| `config/schema/` | Schema for validating consumer declarations. |
| `docs/` | Product requirements, implementation plan, roadmap, backlog, research, architecture and operational guidance. |
| `docs/adr/` | Accepted architecture decisions, including outcomes of M1 spikes. |
| `docs/runbooks/` | Carefully scoped bootstrap procedures for Azure OIDC identities and the GitHub App. |
| `image/` | Runner image definition, initialization/entrypoint scripts, and pre-job policy hook. |
| `infra/` | Resource-group Bicep entrypoint and parameter file; reusable Bicep modules belong in `infra/modules/`. |
| `tools/` | Registry validation and generation tooling. |
| Root config and manifests | `package.json` defines validation commands; `package-lock.json` pins Node dependencies; `bicepconfig.json`, `.markdownlint-cli2.jsonc`, `.editorconfig`, and `.gitignore` define repository tooling and conventions. |

Some directories currently contain only placeholders. Implement functionality in its assigned area as the related
issue is taken up; do not treat an empty scaffold as evidence that the design requirement is optional.

## Local validation

Prerequisites: Node.js/npm and Azure CLI with Bicep available. From the repository root, run:

```powershell
npm ci
npm run validate
```

`npm run validate` builds the Bicep template and parameter file, runs Bicep lint, and checks Markdown with the
repository's Markdown configuration. It does not deploy resources or require an Azure login. Add future validators to
the existing `validate` script so it remains the single documented local check.

## Non-negotiable security and platform invariants

- **No inbound public endpoints.** PaaS resources must have public network access disabled. The NAT Gateway egress IP
  is the only public resource; it is outbound-only.
- **Registry-only onboarding.** Onboard or remove a consumer only through `config/consumers/<name>.json`, validated
  by the registry tooling. Do not add ad hoc jobs or consumer-specific deployment parameters outside that flow.
- **Never relax the consumer policy floor.** Public consumer repositories may run only `workflow_dispatch`, `schedule`,
  and `push` on the default branch. Reject `pull_request`, `pull_request_target`, and `workflow_run` for public
  consumers; `pull_request_target` and `workflow_run` are never allowed. Private consumers may opt into
  `pull_request` only where the documented policy permits it. Registry entries may narrow, never widen, the floor.
  Enforce policy in both registry validation and the runner's pre-job hook. These restrictions do not prohibit ordinary
  GitHub-hosted platform PR validation.
- **Keep runner job code unprivileged.** The main runner container must receive no secret environment variables and no
  usable managed identity. GitHub App credentials are for the init/scaling path, not job steps.
- **Never commit or print secrets, keys, or tokens.** Do not put credentials in source, generated artifacts, logs, or
  command output.
- **Pin dependencies.** Pin GitHub Actions by full commit SHA and container images by digest. Bicep must use
  Azure Verified Modules at exact versions.
- **Preserve platform conventions.** Deploy to the approved `shared` subscription, in `swedencentral`, using CAF
  naming and governance tags. Do not change approved scopes or conventions without an explicit decision.
- **Keep deployment gated.** Production deployment belongs only to the protected `platform-prod` workflow. Do not
  deploy from a local checkout or another workflow. The sole exception is an explicitly approved, time-boxed spike in
  a separate spike resource group, which must be deleted afterward.
- **Protect job-start permissions.** Never grant `Microsoft.App/jobs/start/action` broadly; it can expose job secrets.

## Documentation and runbooks

- [README](README.md) — project overview and local validation.
- [PRD](docs/prd.md) — goals, requirements, security and success criteria.
- [Plan](docs/plan.md) — approved architecture and implementation approach.
- [Roadmap](docs/roadmap.md) and [backlog](docs/backlog.md) — milestone gates, issues and dependencies.
- [Research: Azure runner options](docs/research-azure-runner-options.md) and
  [research: public repositories with private endpoints](docs/research-public-repo-private-endpoints.md) — design
  background.
- [ADR index](docs/adr/README.md) — decision record format and planned spike outcomes.
- [OIDC identity bootstrap](docs/runbooks/bootstrap-identity.md) — exact existing identity scope, verification, and
  GitHub bindings. Stop on unexpected state; do not recreate or expand permissions.
- [GitHub App runbook](docs/runbooks/github-app.md) — App permissions, installation scope, key handling, and rotation.

Architecture, consumer onboarding, operations, and security guides are tracked as documentation issues in the backlog.
Add links here when those files exist; do not create speculative or duplicate instructions in this guide.

## Change conventions

- Use one issue per branch and pull request; reference it in the PR body (for example, `Closes #3`).
- Use concise Conventional Commit messages.
- Keep changes within the issue's scope, follow existing scripts and naming, and update directly related documentation.
- Never use a local Azure deployment as a substitute for validation or for the protected deployment workflow.
