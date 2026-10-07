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
| [Consumer registry](docs/consumer-registry.md) | Consumer JSON contract, resource limits, and validation boundary |
| [Security model](docs/security.md) | Threats, implemented controls, assurance limits, and residual risks |
| [Observability](docs/observability.md) | Log Analytics network exception and diagnostic-settings contract |
| [Runner image](image/README.md) | Pinned generic toolset, local image checks, and remaining runtime contracts |
| [Identity bootstrap](docs/runbooks/bootstrap-identity.md) | Approved Azure identities, constrained RBAC, and GitHub OIDC configuration |
| [ADRs](docs/adr/README.md) | Decisions, including spike outcomes |
| [AGENTS.md](AGENTS.md) | Rules for AI agents working in this repo |

Background research: [runner options on Azure](docs/research-azure-runner-options.md) and
[public repo + private-endpoint-only constraints](docs/research-public-repo-private-endpoints.md).
Both were written while evaluating `apex-vnext` as the first consumer.

## Local validation

Install Node.js/npm, the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), PowerShell 7.5+, and Python 3.
Hook tests additionally require Bash, git, jq, and curl on Linux, or Linux Docker on Windows.
The [VMSS spike preparation](spikes/vmss-flex/README.md) client checks require Linux Docker on every host;
they compile the pinned Go integration inside a digest-pinned builder without installing Go locally.
Then run:

```powershell
npm ci
npm run validate
```

`npm run validate` runs consumer schema, policy, and generator tests; validates active `config/consumers/*.json`
entries against GitHub repository visibility and default-branch metadata; checks generated consumer parameters for
drift; builds and lints the Bicep deployment and modules; validates diagnostic categories against the configuration
consumed by the deployment; checks the offline image contract and executes the Bats policy-hook fixtures; and checks all Markdown with the repository's
`.markdownlint-cli2.jsonc` configuration.
Run `npm run generate:consumers` after editing the registry to update `infra/generated/consumers.json`. The generated
ARM parameters document contains typed consumer deployment fields and a serialized `policyJson`; `main.bicep` does
not consume it until consumer-job infrastructure is implemented. The registry currently has no active consumers, so
validation does not need GitHub access; when entries are added, install GitHub CLI and authenticate with access to
each registered repository. Files ending in `.sample` are examples, not active entries. It also compiles the issue-9
spike templates and runs its offline PowerShell/Python unit tests, plus issue-60 offline budget/cleanup tests
and the pinned Go client build/vet/tests. Validation does not deploy resources.

## At a glance

- One shared VNet, internal ACA environment, private ACR Premium and Key Vault, NAT Gateway egress in `swedencentral`.
- Log Analytics uses standard Azure Monitor ingestion/query endpoints with local authentication disabled; this is the documented exception to public-network-disabled workload endpoints.
- One event-driven ACA job per consumer repo, declared in `config/consumers/<name>.json`.
- Single-use JIT runners. A GitHub App key is used only in an init container, and job code gets no managed identity.
- A pre-job hook enforces the policy floor. Public repos may only run `workflow_dispatch`, `schedule`, and default-branch `push`.
- Consumers reach their own private resources through private endpoints in the shared `snet-consumer-pe` subnet.
