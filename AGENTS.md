# AGENTS.md

Seed guide for AI agents. Backlog item `docs-agents` expands this once the layout exists.

## Before you start

1. Read [docs/prd.md](docs/prd.md) and [docs/plan.md](docs/plan.md).
2. Pick an open issue whose dependencies are closed; see [docs/backlog.md](docs/backlog.md) for the dependency list.
3. Spikes (milestone M1) end with an ADR in `docs/adr/`; later items must follow accepted ADRs.

## Invariants (never violate)

- No inbound public endpoints. Every PaaS resource keeps public network access disabled; the only public resource is
  the NAT Gateway egress IP.
- Consumers are onboarded **only** through `config/consumers/<name>.json` validated by the registry validator.
- Never relax the policy floor: public repos run only `workflow_dispatch`, `schedule`, and default-branch `push`;
  `pull_request_target` and `workflow_run` are never allowed.
- The main runner container never receives secret environment variables or a usable managed identity.
- No secrets, keys, or tokens committed to the repository.
- Bicep uses Azure Verified Modules at exact versions; region `swedencentral`; CAF naming; governance tags.
- Actions are pinned by full commit SHA; container images by digest.

## Working conventions

- Conventional Commits; one issue per PR; reference the issue (`Closes #N`).
- Do not deploy to Azure outside the gated `platform-prod` workflow, except time-boxed spikes in a separate spike
  resource group that is deleted afterwards.
