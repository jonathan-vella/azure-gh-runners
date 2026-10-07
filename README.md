# azure-gh-runners

Shared, private-endpoint-only Azure platform that runs **ephemeral self-hosted GitHub Actions runners** as Azure
Container Apps jobs for any onboarded repository.

> Status: pre-implementation. Work is tracked in [GitHub issues](https://github.com/jonathan-vella/azure-gh-runners/issues)
> grouped by [milestones](https://github.com/jonathan-vella/azure-gh-runners/milestones).

## Start here

| Document | Purpose |
| --- | --- |
| [PRD](docs/prd.md) | What and why: goals, requirements, security floor, success metrics |
| [Roadmap](docs/roadmap.md) | Milestones M0–M6 and exit criteria |
| [Backlog](docs/backlog.md) | Every work item with acceptance criteria and linked issue |
| [Plan](docs/plan.md) | Approved implementation plan and target architecture |
| [Identity bootstrap](docs/runbooks/bootstrap-identity.md) | Approved Azure identities, constrained RBAC, and GitHub OIDC configuration |
| [ADRs](docs/adr/README.md) | Decisions, including spike outcomes |
| [AGENTS.md](AGENTS.md) | Rules for AI agents working in this repo |

Background research: [runner options on Azure](docs/research-azure-runner-options.md) and
[public repo + private-endpoint-only constraints](docs/research-public-repo-private-endpoints.md).
Both were written while evaluating `apex-vnext` as the first consumer.

## Local validation

Install Node.js/npm, the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), PowerShell 7, and Python 3.
Then run:

```powershell
npm ci
npm run validate
```

`npm run validate` builds and lints the Bicep scaffold, compiles the issue-9 spike templates, runs its offline
PowerShell/Python unit tests, and checks all Markdown with the repository's `.markdownlint-cli2.jsonc` configuration.
The production Bicep entrypoints are intentionally empty until their infrastructure issues are implemented.

## At a glance

- One shared VNet, internal ACA environment, private ACR Premium and Key Vault, NAT Gateway egress in `swedencentral`.
- One event-driven ACA job per consumer repo, declared in `config/consumers/<name>.json`.
- Single-use JIT runners. A GitHub App key is used only in an init container, and job code gets no managed identity.
- A pre-job hook enforces the policy floor. Public repos may only run `workflow_dispatch`, `schedule`, and default-branch `push`.
- Consumers reach their own private resources through private endpoints in the shared `snet-consumer-pe` subnet.
