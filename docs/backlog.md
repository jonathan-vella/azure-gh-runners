# Backlog

Source of truth for work items. Each item maps to one GitHub issue. Pick items whose dependencies are closed.
See [Roadmap](roadmap.md) for milestone exit criteria and [PRD](prd.md) for requirements.

## Dual-backend planning

The planning tracker is [#59](https://github.com/jonathan-vella/azure-gh-runners/issues/59). The primary backend is
unresolved. The latest owner-authorized non-zonal D4 attempt used reviewed source
`e934066c3c1cb43fa33cf7ee835389f03de48389`. Observed activity shows the ARM validation action was asynchronously
accepted, with no deployment write or ACA managed-environment write observed and inventory confirming zero
deployments/resources. The original CLI exit was 1 (`Unclassified`); readback was `DeploymentNotFound`, and
independent diagnosis was `DeploymentAbsentOwnedGroupEmpty`. Offline mocks show that an accepted asynchronous
validation can later return an error before deployment creation, but this is only a possible control-flow explanation,
not evidence of what happened in the real attempt. The actual cause is unknown. Cleanup succeeded and the exact
`rg-ghrunners-spike7-swc` resource group was verified absent. No ACA environment create or job run occurred; this is
not evidence of ACA capacity failure. See
[the recorded D4 outcome](https://github.com/jonathan-vella/azure-gh-runners/issues/7#issuecomment-6045915111).
The additional D4 authorization has been consumed; no further retry is authorized. Apply the conditional rule in the
roadmap; do not set backend defaults, change the active consumer contract, or reprioritize/relabel ACA work until
evidence selects a primary.

The additive schema issue #63 may proceed independently of the D4 outcome and VMSS spike. It must not set a default or
alter existing ACA entries. All runtime/tooling changes and persistent VMSS implementation remain gated by the accepted
ADR. A failed or inconclusive VMSS spike blocks persistent VMSS implementation.

## M0 - Foundation

Repository, identities, and GitHub App exist; agents can work in the repo.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#1](https://github.com/jonathan-vella/azure-gh-runners/issues/1) | `repo-create` | Harden the repository settings | setup | — |
| [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) | `repo-layout` | Scaffold the repository layout and tooling | setup | [#1](https://github.com/jonathan-vella/azure-gh-runners/issues/1) |
| [#3](https://github.com/jonathan-vella/azure-gh-runners/issues/3) | `docs-agents` | Expand AGENTS.md into the full agent operating guide | docs | [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) |
| [#4](https://github.com/jonathan-vella/azure-gh-runners/issues/4) | `entra-oidc` | Bootstrap Entra OIDC identities for platform CI | setup, security | [#1](https://github.com/jonathan-vella/azure-gh-runners/issues/1) |
| [#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5) | `github-app` | Create and install the runner GitHub App | setup, security | [#1](https://github.com/jonathan-vella/azure-gh-runners/issues/1) |

## M1 - De-risk spikes

Preview and undocumented behaviours are proven or replaced; findings recorded as ADRs.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6) | `spike-acr-agentpool` | Spike: ACR Tasks agent-pool build against a private ACR | spike, image | [#4](https://github.com/jonathan-vella/azure-gh-runners/issues/4) |
| [#7](https://github.com/jonathan-vella/azure-gh-runners/issues/7) | `spike-kv-ref-pe` | Spike: ACA job Key Vault secret references over a private endpoint | spike, security | [#4](https://github.com/jonathan-vella/azure-gh-runners/issues/4) |
| [#8](https://github.com/jonathan-vella/azure-gh-runners/issues/8) | `spike-keda-egress` | Spike: KEDA github-runner scaler polling path | spike | [#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5) |
| [#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9) | `spike-job-identity-init` | Spike: init container, EmptyDir, and identitySettings on ACA jobs | spike, security | [#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5) |
| [#10](https://github.com/jonathan-vella/azure-gh-runners/issues/10) | `spike-jit-labels` | Spike: JIT runner labels and runs-on syntax | spike | [#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5) |
| [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60) | `spike-vmss` | Spike: prove VMSS Flex single-job runner lifecycle | spike, infra, security | [#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5), [#10](https://github.com/jonathan-vella/azure-gh-runners/issues/10), [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19), [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) |
| [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61) | `adr-dual-backend` | ADR: dual ACA and VMSS Flex backend decision | infra, docs, security | [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60) |

## M2 - Platform infrastructure

Private-endpoint-only network, observability, Key Vault, ACR and ACA environment deploy cleanly.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11) | `iac-network` | Network: VNet, subnets, NSGs, NAT Gateway, private DNS zones | infra, security | [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) |
| [#12](https://github.com/jonathan-vella/azure-gh-runners/issues/12) | `iac-observability` | Observability: Log Analytics and diagnostic settings | infra | [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) |
| [#13](https://github.com/jonathan-vella/azure-gh-runners/issues/13) | `iac-identity-kv` | Identity and Key Vault | infra, security | [#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11), [#7](https://github.com/jonathan-vella/azure-gh-runners/issues/7) |
| [#14](https://github.com/jonathan-vella/azure-gh-runners/issues/14) | `iac-acr` | Azure Container Registry Premium (private) | infra, security | [#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11), [#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6) |
| [#15](https://github.com/jonathan-vella/azure-gh-runners/issues/15) | `iac-aca-env` | Container Apps workload-profiles environment (internal) | infra, security | [#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11), [#12](https://github.com/jonathan-vella/azure-gh-runners/issues/12) |
| [#66](https://github.com/jonathan-vella/azure-gh-runners/issues/66) | `iac-network-vmss` | Network: add private controller and worker subnets | infra, security | [#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11), [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61) |

## M3 - Runner image and consumer jobs

Hardened runner image, consumer registry, and one runner backend per registry entry. ACA remains supported; the primary
backend and active defaults are set only after the D4 evidence rule is conclusive.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#16](https://github.com/jonathan-vella/azure-gh-runners/issues/16) | `registry-schema` | Consumer registry JSON Schema | registry | [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) |
| [#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17) | `registry-validator` | Consumer registry validator (policy floor) | registry, security | [#16](https://github.com/jonathan-vella/azure-gh-runners/issues/16) |
| [#18](https://github.com/jonathan-vella/azure-gh-runners/issues/18) | `registry-generator` | Consumer registry to Bicep params generator | registry | [#16](https://github.com/jonathan-vella/azure-gh-runners/issues/16) |
| [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19) | `image-dockerfile` | Runner image Dockerfile (generic toolset) | image | [#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2) |
| [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) | `image-prejob-hook` | Pre-job hook enforcing the consumer policy | image, security | [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19) |
| [#21](https://github.com/jonathan-vella/azure-gh-runners/issues/21) | `image-init-script` | Init-container JIT minting script | image, security | [#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9), [#10](https://github.com/jonathan-vella/azure-gh-runners/issues/10), [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19) |
| [#22](https://github.com/jonathan-vella/azure-gh-runners/issues/22) | `image-entrypoint` | Main-container runner entrypoint | image, security | [#21](https://github.com/jonathan-vella/azure-gh-runners/issues/21) |
| [#23](https://github.com/jonathan-vella/azure-gh-runners/issues/23) | `image-build-pipeline` | Image build pipeline | image, ci | [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19), [#14](https://github.com/jonathan-vella/azure-gh-runners/issues/14) |
| [#24](https://github.com/jonathan-vella/azure-gh-runners/issues/24) | `iac-runner-job-module` | Reusable per-consumer ACA runner job module | infra, security | [#15](https://github.com/jonathan-vella/azure-gh-runners/issues/15), [#13](https://github.com/jonathan-vella/azure-gh-runners/issues/13), [#8](https://github.com/jonathan-vella/azure-gh-runners/issues/8), [#22](https://github.com/jonathan-vella/azure-gh-runners/issues/22) |
| [#25](https://github.com/jonathan-vella/azure-gh-runners/issues/25) | `iac-consumers-loop` | Wire the consumer loop into main.bicep | infra | [#24](https://github.com/jonathan-vella/azure-gh-runners/issues/24), [#18](https://github.com/jonathan-vella/azure-gh-runners/issues/18) |
| [#63](https://github.com/jonathan-vella/azure-gh-runners/issues/63) | `registry-backend-schema` | Registry schema: add VMSS backend sizing contract | infra, registry | [#16](https://github.com/jonathan-vella/azure-gh-runners/issues/16); independent of D4 and #60 |
| [#64](https://github.com/jonathan-vella/azure-gh-runners/issues/64) | `registry-backend-tooling` | Registry tooling: validate and generate dual-backend consumers | registry, security | [#63](https://github.com/jonathan-vella/azure-gh-runners/issues/63), [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61) |
| [#65](https://github.com/jonathan-vella/azure-gh-runners/issues/65) | `iac-backend-flags` | IaC flags: independently gate ACA and VMSS backends | infra, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#63](https://github.com/jonathan-vella/azure-gh-runners/issues/63), [#64](https://github.com/jonathan-vella/azure-gh-runners/issues/64), conclusive D4 primary decision |
| [#67](https://github.com/jonathan-vella/azure-gh-runners/issues/67) | `iac-gallery-image` | Image: build VMSS worker image with VM Image Builder | image, infra, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19), [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20); reuse [#23](https://github.com/jonathan-vella/azure-gh-runners/issues/23) |
| [#68](https://github.com/jonathan-vella/azure-gh-runners/issues/68) | `iac-vmss-module` | IaC: reusable per-consumer VMSS Flex module | infra, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#63](https://github.com/jonathan-vella/azure-gh-runners/issues/63), [#64](https://github.com/jonathan-vella/azure-gh-runners/issues/64), [#65](https://github.com/jonathan-vella/azure-gh-runners/issues/65), [#66](https://github.com/jonathan-vella/azure-gh-runners/issues/66), [#67](https://github.com/jonathan-vella/azure-gh-runners/issues/67) |
| [#70](https://github.com/jonathan-vella/azure-gh-runners/issues/70) | `iac-controller` | IaC: provision the private VMSS controller | infra, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#66](https://github.com/jonathan-vella/azure-gh-runners/issues/66), [#13](https://github.com/jonathan-vella/azure-gh-runners/issues/13), [#65](https://github.com/jonathan-vella/azure-gh-runners/issues/65) |
| [#69](https://github.com/jonathan-vella/azure-gh-runners/issues/69) | `runbook-controller-rbac` | Runbook: controller managed-identity RBAC | docs, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#13](https://github.com/jonathan-vella/azure-gh-runners/issues/13), [#70](https://github.com/jonathan-vella/azure-gh-runners/issues/70); before first persistent controller deployment |
| [#71](https://github.com/jonathan-vella/azure-gh-runners/issues/71) | `controller-app` | Controller: implement VMSS Flex runner lifecycle service | infra, security, test | [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60), [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61), [#68](https://github.com/jonathan-vella/azure-gh-runners/issues/68), [#69](https://github.com/jonathan-vella/azure-gh-runners/issues/69), [#70](https://github.com/jonathan-vella/azure-gh-runners/issues/70), [#10](https://github.com/jonathan-vella/azure-gh-runners/issues/10) |
| [#72](https://github.com/jonathan-vella/azure-gh-runners/issues/72) | `worker-bootstrap` | Image: bootstrap one-job VMSS worker | image, security, test | [#67](https://github.com/jonathan-vella/azure-gh-runners/issues/67), [#71](https://github.com/jonathan-vella/azure-gh-runners/issues/71), [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) |

## M4 - Platform CI/CD

PR validation, gated deployment, and scheduled maintenance run from this repo.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#26](https://github.com/jonathan-vella/azure-gh-runners/issues/26) | `ci-validate` | PR validation workflow | ci | [#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17), [#25](https://github.com/jonathan-vella/azure-gh-runners/issues/25), [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) |
| [#27](https://github.com/jonathan-vella/azure-gh-runners/issues/27) | `ci-deploy` | Gated deployment workflow | ci, security | [#26](https://github.com/jonathan-vella/azure-gh-runners/issues/26), [#23](https://github.com/jonathan-vella/azure-gh-runners/issues/23) |
| [#28](https://github.com/jonathan-vella/azure-gh-runners/issues/28) | `ci-maintenance` | Scheduled maintenance workflow | ci | [#27](https://github.com/jonathan-vella/azure-gh-runners/issues/27) |

## M5 - Documentation

Agent-executable architecture, onboarding, operations, and security documentation.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#29](https://github.com/jonathan-vella/azure-gh-runners/issues/29) | `docs-architecture` | Architecture documentation | docs | [#25](https://github.com/jonathan-vella/azure-gh-runners/issues/25) |
| [#30](https://github.com/jonathan-vella/azure-gh-runners/issues/30) | `docs-onboarding` | Agent-executable consumer onboarding guide | docs | [#25](https://github.com/jonathan-vella/azure-gh-runners/issues/25) |
| [#31](https://github.com/jonathan-vella/azure-gh-runners/issues/31) | `docs-operations` | Operations runbook | docs | [#27](https://github.com/jonathan-vella/azure-gh-runners/issues/27) |
| [#32](https://github.com/jonathan-vella/azure-gh-runners/issues/32) | `docs-security` | Security model and threat analysis | docs, security | [#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) |
| [#62](https://github.com/jonathan-vella/azure-gh-runners/issues/62) | `docs-prd-plan` | Update shared platform design for dual backends | docs, security | [#61](https://github.com/jonathan-vella/azure-gh-runners/issues/61); reuse #29–#32 where applicable |

## M6 - v1.0 acceptance

Smoke-test consumer proves the platform end to end; v1.0 declared.

| Issue | ID | Title | Labels | Depends on |
| --- | --- | --- | --- | --- |
| [#33](https://github.com/jonathan-vella/azure-gh-runners/issues/33) | `smoke-consumer` | Smoke-test consumer repo end to end | test, security | [#27](https://github.com/jonathan-vella/azure-gh-runners/issues/27), [#30](https://github.com/jonathan-vella/azure-gh-runners/issues/30) |
| [#34](https://github.com/jonathan-vella/azure-gh-runners/issues/34) | `acceptance` | v1.0 acceptance and release | test | [#33](https://github.com/jonathan-vella/azure-gh-runners/issues/33), [#29](https://github.com/jonathan-vella/azure-gh-runners/issues/29), [#31](https://github.com/jonathan-vella/azure-gh-runners/issues/31), [#32](https://github.com/jonathan-vella/azure-gh-runners/issues/32), [#3](https://github.com/jonathan-vella/azure-gh-runners/issues/3) |

## Item details

### `repo-create` — Harden the repository settings ([#1](https://github.com/jonathan-vella/azure-gh-runners/issues/1))

The private repo exists. Finish repository hardening so all later work lands through reviewed PRs.

Acceptance criteria:

- Branch protection (or ruleset) on `main`: PR required, required status checks placeholder, no force push, linear history
- `CODEOWNERS` covers `/.github/`, `/infra/`, `/image/`, `/config/`
- Dependabot enabled for `github-actions` and `docker` ecosystems
- Secret scanning and push protection enabled
- Actions settings: default `GITHUB_TOKEN` permissions read-only; actions pinned by SHA policy documented

### `repo-layout` — Scaffold the repository layout and tooling ([#2](https://github.com/jonathan-vella/azure-gh-runners/issues/2))

Create the directory structure and baseline tooling every later item builds on.

Acceptance criteria:

- Directories: `infra/` (`main.bicep`, `main.bicepparam`, `modules/`), `image/`, `config/consumers/`, `config/schema/`, `tools/`, `docs/`, `.github/workflows/`
- `bicepconfig.json` with linter rules enabled; `.markdownlint` config; `.editorconfig`; `.gitignore`
- A single documented local validation command (e.g. `make validate` or `npm run validate`) that later items extend
- README links to PRD, roadmap, backlog, and plan

### `docs-agents` — Expand AGENTS.md into the full agent operating guide ([#3](https://github.com/jonathan-vella/azure-gh-runners/issues/3))

Expand the seed `AGENTS.md` so an agent can work in this repo without extra context.

Acceptance criteria:

- Repo map, ownership of each directory, and validation commands
- Non-negotiable invariants: no public inbound endpoints; onboarding only via the consumer registry; never relax the policy floor; no secrets in env of the main runner container
- Links to PRD, roadmap, backlog, ADRs, and docs/*

### `entra-oidc` — Bootstrap Entra OIDC identities for platform CI ([#4](https://github.com/jonathan-vella/azure-gh-runners/issues/4))

Create the resource group and two separate Entra applications/service principals used by this repo's workflows. Federated credentials are created via Microsoft Graph / az CLI (not Bicep). Record the commands as a runbook.

Acceptance criteria:

- Resource group `rg-ghrunners-prod-swc` in `swedencentral` in approved subscription `shared` (`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`, replacing the planned `apex-shared` name), tagged per governance contract
- Federated credential `repo:jonathan-vella/azure-gh-runners:environment:platform-prod` on `sp-ghrunners-platform-prod` with least-privilege deploy rights on the RG (Contributor + role-assignment write and delete constrained to AcrPull, AcrPush, and Key Vault Secrets User)
- Separate federated credential `repo:jonathan-vella/azure-gh-runners:pull_request` on `sp-ghrunners-whatif`, mapped only to Reader for what-if; repository variable `AZURE_WHATIF_CLIENT_ID`, no GitHub environment on the PR job
- GitHub environment `platform-prod`: deployment branch `main` only; holds `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. The required reviewer is currently removed under the owner's unattended automation decision; [#74](https://github.com/jonathan-vella/azure-gh-runners/issues/74) is an owner reminder, not a v1.0 gate or dependency.
- Runbook `docs/runbooks/bootstrap-identity.md` with exact, re-runnable commands

### `github-app` — Create and install the runner GitHub App ([#5](https://github.com/jonathan-vella/azure-gh-runners/issues/5))

Create a GitHub App owned by the personal account that the KEDA scaler and the init container use to observe queued jobs and mint JIT runner configs.

Acceptance criteria:

- App permissions: Repository Administration read/write, Actions read, Metadata read; no webhook; not public
- Installed with 'Only select repositories' (initially the smoke-test repo only)
- App ID, installation ID and private key stored as `platform-prod` environment secrets
- Runbook `docs/runbooks/github-app.md` covering creation, installation on a new repo, and key rotation

### `spike-acr-agentpool` — Spike: ACR Tasks agent-pool build against a private ACR ([#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6))

Prove that a GitHub-hosted runner can trigger an image build on an ACR Tasks dedicated agent pool (preview) in a VNet, with ACR Premium public network access disabled.

Acceptance criteria:

- Determine whether `az acr build --agent-pool` source-context upload works with public access disabled; if not, evaluate a git-context ACR task
- Confirm agent-pool subnet egress needed to pull `ghcr.io/actions/actions-runner` base image
- Confirm S1/S2 tier availability and quota in `swedencentral`
- Decision recorded in `docs/adr/0001-image-build-path.md`, including fallback (GitHub-hosted build -> private GHCR -> `az acr import` by digest) if the spike fails
- Spike resources deleted

### `spike-kv-ref-pe` — Spike: ACA job Key Vault secret references over a private endpoint ([#7](https://github.com/jonathan-vella/azure-gh-runners/issues/7))

Microsoft docs do not state whether ACA resolves `keyVaultUrl` secrets when Key Vault public access is disabled. Prove it.

Acceptance criteria:

- ACA job in a VNet-integrated workload-profiles environment resolves a `keyVaultUrl` secret from a Key Vault with public access disabled and a private endpoint
- Document whether 'Allow trusted Microsoft services' is required
- Decision recorded in `docs/adr/0002-key-vault-secret-references.md`
- Spike resources deleted

### `spike-keda-egress` — Spike: KEDA github-runner scaler polling path ([#8](https://github.com/jonathan-vella/azure-gh-runners/issues/8))

Determine whether the KEDA `github-runner` scale-rule polling to api.github.com originates from the customer subnet (traverses NAT/NSG) or from the platform.

Acceptance criteria:

- Evidence (NSG flow logs / NAT metrics / deny test) of where scaler traffic originates
- Required egress list for scaler + runner documented
- Decision recorded in `docs/adr/0003-egress-requirements.md`

### `spike-job-identity-init` — Spike: init container, EmptyDir, and identitySettings on ACA jobs ([#9](https://github.com/jonathan-vella/azure-gh-runners/issues/9))

Prove the secret-isolation pattern: init container holds the App key and writes a JIT config to an EmptyDir; main container has no secrets and no managed identity.

Acceptance criteria:

- Init container can read the App key secret via `secretRef`; main container env contains no secret values
- With `identitySettings` lifecycle `None`, `IDENTITY_ENDPOINT` is absent / token request fails in the main container while ACR pull and KV refs still work
- Secret referenced only by scale-rule auth is not visible in either container
- Decision recorded in `docs/adr/0004-runner-secret-isolation.md`

### `spike-jit-labels` — Spike: JIT runner labels and runs-on syntax ([#10](https://github.com/jonathan-vella/azure-gh-runners/issues/10))

Confirm which labels `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` registers and how consumers must write `runs-on` when the scaler uses `noDefaultLabels=true`.

Acceptance criteria:

- Documented label set of a JIT runner (including whether `self-hosted` is implicit)
- Confirmed `runs-on` form that both scales the KEDA rule and matches the JIT runner
- Confirmed a plain `runs-on: self-hosted` does not wake the pool
- Decision recorded in `docs/adr/0005-runner-labels.md`

### `iac-network` — Network: VNet, subnets, NSGs, NAT Gateway, private DNS zones ([#11](https://github.com/jonathan-vella/azure-gh-runners/issues/11))

Author the network module (AVM-first, exact version pins).

Acceptance criteria:

- VNet with `snet-aca` (/27+, delegated `Microsoft.App/environments`), `snet-acr-agents`, `snet-pe`, `snet-consumer-pe` (/26)
- NSG on `snet-aca` and `snet-acr-agents`: allow 443 to PE subnets and Internet, deny other RFC1918 ranges
- NAT Gateway + static Standard public IP attached to `snet-aca` and `snet-acr-agents`
- Private DNS zones from a config list (at least blob/file/queue/table/vault/acr) linked to the VNet; zone resource IDs output
- `bicep build` and `bicep lint` clean

### `iac-observability` — Observability: Log Analytics and diagnostic settings ([#12](https://github.com/jonathan-vella/azure-gh-runners/issues/12))

Log Analytics workspace (standard ingestion, no AMPLS) and a reusable diagnostic-settings pattern.

Acceptance criteria:

- Log Analytics workspace with local auth disabled
- Diagnostic settings (service log categories + AllMetrics) on every resource that supports them
- Workspace ID output for the ACA environment

### `iac-identity-kv` — Identity and Key Vault ([#13](https://github.com/jonathan-vella/azure-gh-runners/issues/13))

User-assigned managed identities and a private Key Vault holding the GitHub App key.

Acceptance criteria:

- UAMI for runner jobs (AcrPull + Key Vault Secrets User only)
- Key Vault: RBAC mode, public network access disabled, purge protection on, private endpoint in `snet-pe` with DNS zone group
- GitHub App private key written via ARM (`Microsoft.KeyVault/vaults/secrets`) from a `@secure()` parameter
- Per ADR-0002, trusted-services setting matches the proven configuration

### `iac-acr` — Azure Container Registry Premium (private) ([#14](https://github.com/jonathan-vella/azure-gh-runners/issues/14))

Private ACR for the runner image, implementing the build path chosen in ADR-0001.

Acceptance criteria:

- ACR Premium: public network access disabled, admin user disabled, ARM-audience tokens enabled, trusted services enabled
- Private endpoint (registry + data endpoint) in `snet-pe` linked to `privatelink.azurecr.io`
- Agent pool in `snet-acr-agents` (or ADR-0001 fallback resources)
- AcrPull role for the runner UAMI

### `iac-aca-env` — Container Apps workload-profiles environment (internal) ([#15](https://github.com/jonathan-vella/azure-gh-runners/issues/15))

VNet-integrated internal ACA environment that hosts all runner jobs.

Acceptance criteria:

- Workload-profiles environment in `snet-aca`, internal, `publicNetworkAccess: Disabled`
- Logs to the Log Analytics workspace
- Outputs environment resource ID

### `registry-schema` — Consumer registry JSON Schema ([#16](https://github.com/jonathan-vella/azure-gh-runners/issues/16))

Typed contract for `config/consumers/<name>.json`.

Acceptance criteria:

- Fields: `name`, `repo` (owner/name), `visibility` (public|private), `labels`, `cpu`, `memory`, `maxExecutions`, `replicaTimeoutSeconds`, `allowedEvents`, `allowedRefs`, `allowedWorkflows`, optional `notes`
- Schema in `config/schema/consumer.v1.json` with examples
- Example entry `config/consumers/example.json.sample` (not deployed)

### `registry-validator` — Consumer registry validator (policy floor) ([#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17))

Validator that enforces the schema and the platform policy floor.

Acceptance criteria:

- Fails on schema violations, duplicate names/labels, labels not matching `ghr-<name>`
- Public repos: rejects `pull_request`/`pull_request_target`/`workflow_run`; only `workflow_dispatch`, `schedule`, `push`; refs limited to default branch
- Private repos may opt into `pull_request` but never `pull_request_target`
- Rejects cpu/memory beyond consumption limits (4 vCPU / 8 GiB)
- Unit tests with passing and failing fixtures

### `registry-generator` — Consumer registry to Bicep params generator ([#18](https://github.com/jonathan-vella/azure-gh-runners/issues/18))

Generate the Bicep parameter payload consumed by `main.bicep` from the registry.

Acceptance criteria:

- Deterministic output file (e.g. `infra/generated/consumers.json`)
- Drift check mode used by CI (fails if generated output is stale)
- Policy JSON per consumer emitted for the pre-job hook

### `image-dockerfile` — Runner image Dockerfile (generic toolset) ([#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19))

Single generic runner image.

Acceptance criteria:

- `FROM ghcr.io/actions/actions-runner@sha256:<pinned>`
- Adds pinned versions of: git, jq, curl, az CLI, Bicep, Terraform, Node LTS, Python 3, pwsh
- Runs as non-root `runner`; no Docker daemon; hadolint clean
- Tool versions recorded in `image/versions.json`

### `image-prejob-hook` — Pre-job hook enforcing the consumer policy ([#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20))

`ACTIONS_RUNNER_HOOK_JOB_STARTED` script baked into the image; a non-zero exit stops the job before any user step.

Acceptance criteria:

- Reads per-consumer policy JSON from a non-secret env var
- Rejects when `GITHUB_REPOSITORY`, `GITHUB_EVENT_NAME`, `GITHUB_REF`, or `GITHUB_WORKFLOW_REF` falls outside the policy; fails closed on missing/invalid policy
- Clear rejection message in the 'Set up runner' log
- bats tests covering allow and deny cases (incl. fork PR payload)

### `image-init-script` — Init-container JIT minting script ([#21](https://github.com/jonathan-vella/azure-gh-runners/issues/21))

Init container mints a single-use JIT runner config using the GitHub App and hands it to the main container via EmptyDir.

Acceptance criteria:

- App JWT -> installation token -> `generate-jitconfig` with labels per ADR-0005 and a unique runner name
- Writes `encoded_jit_config` to the EmptyDir with restrictive permissions; never logs secrets
- Fails closed on any API error; retries with bounded backoff on 5xx/rate limit

### `image-entrypoint` — Main-container runner entrypoint ([#22](https://github.com/jonathan-vella/azure-gh-runners/issues/22))

Entrypoint for the main runner container.

Acceptance criteria:

- Reads the JIT file, deletes it, scrubs sensitive env, `exec ./run.sh --jitconfig ...`
- Sets `ACTIONS_RUNNER_HOOK_JOB_STARTED` to the baked hook
- Exits non-zero if the JIT file is missing

### `image-build-pipeline` — Image build pipeline ([#23](https://github.com/jonathan-vella/azure-gh-runners/issues/23))

Build and publish the runner image via the path chosen in ADR-0001.

Acceptance criteria:

- Image tagged with git SHA; digest captured as a workflow output and fed to deployment
- Base image and tool pins updated by Dependabot or a scheduled job
- Optional: build provenance attestation

### `iac-runner-job-module` — Reusable per-consumer ACA runner job module ([#24](https://github.com/jonathan-vella/azure-gh-runners/issues/24))

Bicep module (AVM `avm/res/app/job` where it supports the required properties) that deploys one event-driven runner job for a consumer.

Acceptance criteria:

- Event trigger; KEDA `github-runner` rule with App auth (`appKey` secretRef, `applicationID`, `installationID`), `runnerScope=repo`, `owner`, `repos`, `labels`, `noDefaultLabels=true`, `enableEtags=true`
- Init + main containers, EmptyDir volume, `identitySettings` per ADR-0004
- Image referenced by digest; cpu/memory/maxExecutions/replicaTimeout from registry
- Policy JSON env var for the hook; no secret env on the main container
- Job name `caj-ghr-<name>`

### `iac-consumers-loop` — Wire the consumer loop into main.bicep ([#25](https://github.com/jonathan-vella/azure-gh-runners/issues/25))

Deploy one runner job per registry entry.

Acceptance criteria:

- `main.bicep` loops over generated consumers
- Removing a registry entry removes its job on next deploy (documented mode)
- Outputs: per-consumer job name, labels; platform outputs (subnet IDs, DNS zone IDs) for onboarding docs

### `ci-validate` — PR validation workflow ([#26](https://github.com/jonathan-vella/azure-gh-runners/issues/26))

Required check for every PR.

Acceptance criteria:

- markdownlint, `bicep build` + `bicep lint`, registry validator + generator drift, bats hook tests, hadolint
- What-if against `rg-ghrunners-prod-swc` using the Reader OIDC credential; summary posted to the job summary
- Actions pinned by SHA; `permissions` least privilege; marked as required in branch protection

### `ci-deploy` — Gated deployment workflow ([#27](https://github.com/jonathan-vella/azure-gh-runners/issues/27))

`workflow_dispatch` deployment through the protected `platform-prod` environment.

Acceptance criteria:

- Runs only on `main` through `platform-prod`; unattended deployments remain enabled under the current owner decision. The workflow must not broaden its branch/ref scope.
- Builds image if changed, deploys Bicep with the image digest
- Post-deploy assertions: every PaaS resource has public network access disabled; job count equals registry entries; App key secret present
- Deployment outputs published to `docs/platform-outputs.md` via PR or job summary

### `ci-maintenance` — Scheduled maintenance workflow ([#28](https://github.com/jonathan-vella/azure-gh-runners/issues/28))

Keep the image patched and secrets fresh.

Acceptance criteria:

- Weekly image rebuild; opens a PR or requests a gated deploy
- Issue opened for GitHub App key rotation on a defined cadence
- Staggered cron documented

### `docs-architecture` — Architecture documentation ([#29](https://github.com/jonathan-vella/azure-gh-runners/issues/29))

`docs/architecture.md`.

Acceptance criteria:

- Diagram (Mermaid) of GitHub, VNet, subnets, PEs, ACA env, jobs, ACR, KV, LAW, NAT
- Trust boundaries and the public-exposure statement (only the NAT egress IP is public)
- Links to ADRs

### `docs-onboarding` — Agent-executable consumer onboarding guide ([#30](https://github.com/jonathan-vella/azure-gh-runners/issues/30))

`docs/onboarding-consumer.md` — a deterministic checklist an agent can follow without other context.

Acceptance criteria:

- Step 1: install the GitHub App on the consumer repo
- Step 2: add `config/consumers/<name>.json`, run validator + generator, open PR, run gated deploy
- Step 3: consumer workflow template using `runs-on` per ADR-0005, allowed triggers only, GitHub Environment restricted to `main`, `permissions` least privilege
- Step 4: Entra federated credential subject `repo:<owner>/<repo>:environment:<env>` guidance
- Step 5: create private endpoints in `snet-consumer-pe` with `privateDnsZoneGroup` pointing at platform zone IDs; Bicep and az CLI snippets using values from `docs/platform-outputs.md`
- Step 6: set the consumer repo fork-PR approval to 'Require approval for all external contributors'
- Step 7: verification checklist and troubleshooting table
- Platform constraints listed: Linux only, no Docker-in-Docker, max 4 vCPU / 8 GiB, npm trusted publishing unsupported on self-hosted

### `docs-operations` — Operations runbook ([#31](https://github.com/jonathan-vella/azure-gh-runners/issues/31))

`docs/operations.md`.

Acceptance criteria:

- Deploy, image rebuild, App key rotation, adding a private DNS zone, offboarding a consumer
- Troubleshooting: job not scaling, hook rejection, JIT failure, PE DNS resolution, ACR pull failure
- Cost model and budget alert

### `docs-security` — Security model and threat analysis ([#32](https://github.com/jonathan-vella/azure-gh-runners/issues/32))

`docs/security.md`.

Acceptance criteria:

- Threats: fork PR targeting runners, cross-consumer lateral movement, App key theft, `jobs/start` secret exposure, image supply chain
- Controls mapped to each threat; residual risks (shared subnet) and escalation path (per-consumer subnet/environment)
- RBAC guidance: never grant `Microsoft.App/jobs/start/action` broadly

### `smoke-consumer` — Smoke-test consumer repo end to end ([#33](https://github.com/jonathan-vella/azure-gh-runners/issues/33))

Create public throwaway repo `jonathan-vella/ghr-smoke` and onboard it using only `docs/onboarding-consumer.md`.

Acceptance criteria:

- `workflow_dispatch` on `main` runs on the platform and reads a blob from a test storage account via a PE in `snet-consumer-pe`
- `push` to a non-default branch is rejected by the hook
- A `pull_request` job targeting the label is rejected or never scheduled
- No managed-identity token obtainable inside the job
- Runner deregistered after the job; scale 0 -> 1 -> 0 observed
- Results captured in `docs/acceptance/smoke-results.md`

### `acceptance` — v1.0 acceptance and release ([#34](https://github.com/jonathan-vella/azure-gh-runners/issues/34))

Declare v1.0 of the platform.

Acceptance criteria:

- Automated check: no PaaS resource with public network access enabled; only public IP is the NAT egress IP
- An agent onboarded the smoke repo from docs alone (evidence linked)
- All M0-M5 issues closed; tag `v1.0.0` with release notes

## Dual-backend issue acceptance notes

The new issue bodies are the detailed acceptance source; this section keeps sequencing and cross-issue invariants
visible alongside the existing work items.

- **Spike #60:** exact authorized scope is `rg-ghrunners-spike-vmss-swc` in `shared` / `swedencentral`, one `Standard_B2s`
  controller, at most two `Standard_D2ls_v5` workers, four hours, $10, and two deployment attempts. Stop before any
  limit is exceeded. Verify private networking/NAT, hook rejection, no worker identity, one-job deletion, instance
  protection, and termination notifications. On every outcome delete and verify the entire spike RG; never widen
  permissions if the deployment identity is insufficient.
- **ADR #61 and shared docs #62:** record the reviewed spike outcome and exact D4 evidence rule. Only an actual
  environment and job success selects ACA primary; repeated actual capacity failure selects VMSS primary; any other
  evidence leaves primary/defaults unresolved. The latest authorized attempt's ARM validation action was
  asynchronously accepted; no deployment write, ACA managed-environment write, deployment inventory, or resource
  inventory was observed. Original CLI exit was 1 (`Unclassified`), readback was `DeploymentNotFound`, and independent
  diagnosis found `DeploymentAbsentOwnedGroupEmpty`. Offline mocks establish a possible validation-error-before-create
  path only, not the actual cause, which remains unknown. Cleanup succeeded and the exact
  `rg-ghrunners-spike7-swc` group was verified absent. No ACA environment/job was created, so this is not a capacity
  verdict. The additional D4 authorization has been consumed; no further retry is authorized.
- **Schema #63:** may proceed before the D4 decision and VMSS spike, but stays additive, has no default, and preserves
  current ACA entries. Tooling #64 and backend flags #65 depend on the accepted ADR; flags additionally require a
  conclusive primary decision before choosing defaults. An explicitly assigned consumer on a disabled backend must
  fail clearly rather than silently disappear.
- **Network/image/modules #66–#68 and controller #70:** workers have no public IP, inbound access, managed identity,
  Docker daemon, or default outbound access; use the private worker subnet, NAT egress, non-root execution, exact
  existing tool manifest/hook, immutable gallery image, and zero-idle per-consumer VMSS Flex. Do not deploy outside
  the protected main-only `platform-prod` path.
- **Controller RBAC #69:** Bicep may assign only Virtual Machine Contributor (`9980e02c-c2be-4d73-94e8-173b1dc7cf3c`)
  and Network Contributor (`4d97b98b-1d4f-4787-a291-c67834d212e7`) to the controller identity at
  `rg-ghrunners-prod-swc`. Do not grant the broader Contributor role. The existing platform deployment identity's constrained condition currently
  permits only AcrPull, AcrPush, and Key Vault Secrets User. After the controller-RBAC runbook PR merges, an agent may
  perform the one-time update to add only those two exact controller role IDs; verify and record the exact
  before/after state and stop on mismatch. Preserve all scope/action constraints. Persistent role assignments deploy
  only through the main-only `platform-prod` workflow; no subscription-wide grant, worker identity, or extra role is
  allowed.
- **Controller/runtime #71–#72:** pin `actions/scaleset` v0.4.0 behind an interface. Keep JIT data only in protected
  Custom Script Extension settings, never logs/arguments/source. Reconcile worker, NIC, disk, and extension cleanup
  after success, error, timeout, cancellation, and restart; surface cleanup failures as pending rather than success.
  Reuse the existing pre-job hook and fail closed.
- **Reuse existing issues:** #13 owns shared identity/Key Vault foundations; #10 owns JIT labels; #23 owns image
  pipeline integration; #26–#28 own validation, deployment, and maintenance; #29–#32 own architecture, onboarding,
  operations, and security docs; #33–#34 own smoke and release acceptance. Extend these rather than creating
  duplicates. No ACA issue state, milestone, or label is changed by this plan.
