# Plan: Shared Azure self-hosted GitHub runner platform (`azure-gh-runners`)

## Problem

The GitHub repos are public, are owned by a personal account, and need jobs that reach Azure resources exposed **only through private endpoints**. GitHub-hosted runners have no private network path. Personal accounts can't share runners across repos, because each runner registers to exactly one repo.

## Approach (decided)

- **New private repo** `jonathan-vella/azure-gh-runners`, cloned to `~/repos/azure-gh-runners`. It is project-agnostic, and vnext is just one consumer.
- **One shared Azure platform**: VNet, internal ACA workload-profiles environment, ACR Premium, Key Vault, Log Analytics, NAT Gateway. Plus **one ACA event-driven runner job per onboarded repo**, generated from a typed consumer registry.
- **Location**: approved subscription `shared` (`b47d2942-f5ad-4d3c-b28e-c23e4f83d97e`, replacing the planned `apex-shared` name), region `swedencentral`, RG `rg-ghrunners-prod-swc`.
- **IaC**: Bicep with AVM modules (exact version pins), following apex conventions (CAF naming, governance tags, a single `uniqueSuffix`).
- **Image**: one generic image built **in Azure** on an **ACR Tasks dedicated agent pool** (preview) inside the VNet, pushed to private ACR Premium.
- **Auth to GitHub**: one GitHub App owned by the personal account and installed on selected repos. Its key is deployed to Key Vault through ARM (a Bicep secure param).
- **Platform CI**: GitHub-hosted runners with OIDC. What-if runs on PR; deploy runs on `workflow_dispatch` into a protected environment. This is all ARM, so no VNet is needed.
- **Consumer network path**: a shared `snet-consumer-pe` subnet plus platform-owned privatelink DNS zones. Consumers create their own private endpoints in that subnet. This is documented precisely enough for an agent to execute.
- **Public exposure**: no inbound workload endpoints. The NAT Gateway egress IP is the only public IP resource. Log Analytics is a documented exception: standard Azure Monitor ingestion and query endpoints stay enabled without AMPLS, while workspace local authentication is disabled and Azure RBAC governs data access.
- **Scope**: the platform, a generic onboarding contract, docs, and a throwaway smoke-test consumer repo. **vnext onboarding is a separate follow-up.**

## Target architecture

```text
VNet vnet-ghrunners-prod-swc (e.g. 10.60.0.0/22)
├─ snet-aca            /27+  delegated Microsoft.App/environments  → ACA env (internal, workload profiles)
├─ snet-acr-agents     /27   ACR Tasks agent pool
├─ snet-pe             /27   platform PEs: ACR (registry + data), Key Vault
└─ snet-consumer-pe    /26   consumer-owned PEs (blob/file/queue/table/vault/sql/...)
NAT Gateway + static PIP on snet-aca and snet-acr-agents (egress to GitHub, MCR, ghcr.io, Entra)
Private DNS zones (platform-owned, linked to the VNet): privatelink.{blob,file,queue,table}.core.windows.net,
  privatelink.vaultcore.azure.net, privatelink.azurecr.io, + extensible list in config
NSG on snet-aca: allow 443 to snet-pe/snet-consumer-pe + Internet; deny other RFC1918 (no lateral movement)
```

Per-consumer ACA job (`caj-ghr-<consumer>`):

- **Trigger**: event-driven, KEDA `github-runner` rule with GitHub App auth (`appKey`, `applicationID`, `installationID`), `runnerScope=repo`, `owner`, `repos`, `labels`, `noDefaultLabels=true`, `enableEtags=true`.
- **Init container**: mints a repo-scoped JIT config with the App key and writes it to an EmptyDir volume.
- **Main container**: has no secret env vars. It reads and deletes the JIT file, then runs `run.sh --jitconfig`.
- **Identity**: `identitySettings` lifecycle `None` for the pull and Key Vault identity, so there is no managed identity inside the job.
- **Pre-job hook**: `ACTIONS_RUNNER_HOOK_JOB_STARTED` enforces the platform floor plus the consumer's allowlist. The policy JSON reaches the job through a non-secret env var.

**Policy floor**:

- Public repos: only `workflow_dispatch`, `schedule`, and `push`, on the default branch.
- `pull_request` is always rejected for public repos.
- Private repos may opt in to `pull_request`.
- Registry entries can only narrow this floor.

## Workstreams & todos

### 0. Spikes (de-risk preview/undocumented behaviour first)

- **spike-acr-agentpool**: ACR Premium with public access disabled, an agent pool in a VNet subnet, and `az acr build --agent-pool` triggered from a GitHub-hosted runner. Check whether the source-context upload works, or whether a git-context task or a different approach is needed. Also check egress for the `ghcr.io` base-image pull.
- **spike-kv-ref-pe**: ACA job secret `keyVaultUrl` against a Key Vault with public access disabled and a private endpoint. Does secret resolution work?
- **spike-keda-egress**: does `github-runner` scaler polling cross the NAT/NSG path? Confirm the required egress.
- **spike-job-identity-init**: init container plus EmptyDir plus `identitySettings` on a job. Confirm the main container gets no `IDENTITY_ENDPOINT`, and confirm scale-rule-only secrets aren't injected into containers.
- **spike-jit-labels**: which labels `generate-jitconfig` registers, and how `runs-on` must be written with `noDefaultLabels`.

### 1. Repo bootstrap

- **repo-create**: private repo, default branch `main`, CODEOWNERS, branch protection (required checks, review), Dependabot (actions, docker, bicep where supported), `.gitignore`, LICENSE, `README.md`, `AGENTS.md`.
- **repo-layout**: `infra/` (main.bicep, modules/, main.bicepparam), `image/` (Dockerfile, scripts), `config/consumers/` + `config/schema/`, `tools/` (validators/generators), `docs/`, `.github/workflows/`.

### 2. Azure + GitHub identity bootstrap (one-time, documented runbook)

- **entra-oidc**: two separate Entra apps/SPs, created through Graph/CLI, not Bicep. `sp-ghrunners-platform-prod` trusts only `environment:platform-prod` (Contributor + RBAC Admin on the RG, with both role-assignment write and delete constrained to AcrPull, AcrPush, and Key Vault Secrets User). `sp-ghrunners-whatif` trusts only `pull_request` (Reader on the RG). Never put both credentials on one app: federated credentials authenticate the same SP and do not select different RBAC roles. The PR job has no GitHub environment and uses repository variable `AZURE_WHATIF_CLIENT_ID`; the deploy job uses protected `platform-prod` secrets. See [identity bootstrap](runbooks/bootstrap-identity.md).
- **github-app**: create the App on the personal account. Permissions: Administration RW, Actions R, Metadata R. No webhook. Install it on selected repos. Store App ID, installation ID, and private key as secrets in the runners repo's `platform-prod` environment.

### 3. Platform IaC (Bicep/AVM)

- **iac-network**: VNet, the 4 subnets, NSGs (lateral-deny rules), NAT Gateway + PIP, private DNS zones + VNet links (zone list from config).
- **iac-observability**: Log Analytics workspace and diagnostic settings for supported categories on existing network resources; later resource issues wire their own supported categories. Standard NAT flow logs require StandardV2, and NAT platform metrics are not exportable through diagnostic settings.
- **iac-identity-kv**: user-assigned MI(s). Key Vault (RBAC, public disabled, purge protection, PE). GitHub App key secret through ARM (`Microsoft.KeyVault/vaults/secrets`).
- **iac-acr**: ACR Premium (public disabled, admin off, ARM-audience tokens on, trusted services on, PE for registry + data endpoint), agent pool in `snet-acr-agents`, AcrPull for the job MI.
- **iac-aca-env**: workload-profiles environment, internal, `publicNetworkAccess: Disabled`, VNet-integrated, logs to LAW.
- **iac-runner-job-module**: reusable module for one consumer job (scale rule, init + main containers, EmptyDir, identitySettings, sizing, replica timeout, policy env).
- **iac-consumers-loop**: main.bicep loops over the generated consumer params, so there is one job per registry entry.

### 4. Consumer registry contract

- **registry-schema**: JSON Schema for `config/consumers/<name>.json`. Fields:
  - `repo`, `visibility`, `labels`, `cpu`/`memory`, `maxExecutions`, `replicaTimeoutSeconds`
  - `allowedEvents`, `allowedRefs`, `allowedWorkflows`
  - optional `notes`
- **registry-validator**: enforces the schema, the policy floor (public implies no `pull_request`, default branch only), unique labels, label naming `ghr-<name>`, and size limits (≤ 4 vCPU / 8 GiB consumption).
- **registry-generator**: emits a Bicep params JSON consumed by `main.bicep`. CI checks the generated output is not stale.

### 5. Runner image

- **image-dockerfile**: `FROM ghcr.io/actions/actions-runner@sha256:<pinned>` plus git, jq, curl, az CLI, Bicep (pinned), Terraform (pinned), Node LTS, Python 3, pwsh. Non-root, no Docker daemon.
- **image-init-script**: App JWT → installation token → `generate-jitconfig` (name, labels, `work_folder`) → write to `/jit/config` (EmptyDir, mode 0400 for the runner user). Fail closed.
- **image-entrypoint**: read and delete JIT, unset env, `exec ./run.sh --jitconfig`.
- **image-prejob-hook**: validate `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`, `GITHUB_REF` (default branch), and `GITHUB_WORKFLOW_REF` against the policy env. Exit non-zero to reject before any user step runs. Include unit tests (bats).
- **image-build-pipeline**: ACR task / `az acr build --agent-pool`, tagged by git SHA, with the digest recorded and fed to the deploy. Weekly rebuild.

### 6. Platform CI/CD (runners repo)

- **ci-validate**: on PR: markdownlint, `bicep build/lint`, registry validator + generator drift, hook tests, Dockerfile lint (hadolint), what-if (Reader OIDC).
- **ci-deploy**: `workflow_dispatch` → `platform-prod` environment (required reviewer, `main` only) → image build (if changed) → deploy → post-deploy checks (all resources public-disabled, job count equals registry entries).
- **ci-maintenance**: weekly image rebuild + redeploy-on-approval. App key rotation reminder issue.

### 7. Documentation (agent-actionable)

- **docs-architecture**: `docs/architecture.md`: diagram, components, trust boundaries, public-exposure statement.
- **docs-onboarding**: `docs/onboarding-consumer.md`: a deterministic checklist an agent can execute:
  1. Install the App on the repo.
  2. Add `config/consumers/<name>.json`.
  3. Run the validator and generator, open a PR, and deploy.
  4. In the consumer repo, set `runs-on: [self-hosted, ghr-<name>]`, put the job on `workflow_dispatch`/`schedule`/default-branch `push` only, use a GitHub Environment restricted to `main`, and set the Entra federated-credential subject `repo:<owner>/<repo>:environment:<env>`.
  5. Create PEs in `snet-consumer-pe` with `privateDnsZoneGroup` pointing at the platform zone IDs. Exact resource IDs come from deployment outputs and a published `docs/platform-outputs.md`. Include a Bicep snippet.
  6. Set the consumer repo's fork-approval setting to "all external contributors".
  7. Run the smoke workflow and verify.
- **docs-operations**: `docs/operations.md`: deploy, image rebuild, App key rotation, adding a DNS zone, scaling limits, troubleshooting (job not scaling, hook rejection, PE DNS), cost.
- **docs-security**: `docs/security.md`: threat model (fork PRs, cross-consumer lateral movement, `jobs/start` RBAC), controls, residual risks.
- **docs-agents**: `AGENTS.md`: repo map, invariants (no public endpoints, registry-only onboarding, never relax the policy floor), validation commands.

### 8. Smoke test & acceptance

- **smoke-consumer**: throwaway repo `jonathan-vella/ghr-smoke` (public, to exercise the strict floor) with a test storage account and a PE in `snet-consumer-pe`. The workflows must show:
  - dispatch on `main` runs and reads a blob over the private endpoint
  - `push` to a non-default branch is rejected by the hook
  - a `pull_request`-triggered job targeting the label is rejected, or never scheduled
  - no MI token is available inside the job
  - the runner is deregistered after the job
  - scale goes 0→1→0
- **acceptance**: all resources show `publicNetworkAccess` disabled (except the NAT PIP). Docs are verified by having an agent onboard the smoke repo from `docs/onboarding-consumer.md` alone.

## Notes & considerations

- **Cross-consumer isolation**: all jobs share `snet-aca` and `snet-consumer-pe`. Network reachability between one consumer's job and another's PEs exists, and is mitigated only by Azure RBAC and data-plane auth. This is documented as a residual risk. A per-consumer subnet or environment is the future escalation path.
- **Preview dependency**: ACR Tasks agent pools are preview, and the isolated tier quota defaults to 0, so use the standard S1/S2 tier. If the spike fails, the fallback is to build on a GitHub-hosted runner, push to private GHCR, and run `az acr import` by digest.
- **App key**: one App key gives Administration RW on every installed repo, which is high value. Keep it only in Key Vault and the init container, and rotate it on a schedule.
- `Microsoft.App/jobs/start/action` must not be granted broadly, because it exposes job secrets.
- ACA consumption limits are 4 vCPU / 8 GiB per replica, Linux only, with no Docker-in-Docker. Document these as platform constraints for consumers.
- npm trusted publishing does not work on self-hosted runners, so consumers must keep publish jobs on GitHub-hosted runners.
- Fixed cost is roughly $110/month for the network and ACR Premium, plus agent-pool compute while builds run.
- vnext follow-up (separate plan): consumer entry, a backend storage PE in `snet-consumer-pe`, workflow/validator changes, retiring the firewall exception, and the maintainer workstation access question.
