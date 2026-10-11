# Roadmap

Milestones are sequential gates. Each one has exit criteria and maps to a GitHub milestone. Work items for each
milestone are listed in the [backlog](backlog.md) and tracked as GitHub issues.

```mermaid
graph LR
  M0[M0 Foundation] --> M1[M1 Default decisions]
  M0 --> M2[M2 Platform infrastructure]
  M1 --> M2
  M1 --> M3[M3 Runner image and consumer jobs]
  M2 --> M3
  M3 --> M4[M4 Platform CI/CD]
  M3 --> M5[M5 Documentation]
  M4 --> M5
  M4 --> M6[M6 v1.0 acceptance]
  M5 --> M6
  M1 -.-> M7[M7 Isolated Windows runners]
```

| Milestone | Goal | Exit criteria |
| --- | --- | --- |
| **M0 - Foundation** | Repository, identities, and GitHub App exist; agents can work in the repo. | Branch protection active; layout scaffolded; `AGENTS.md` complete; OIDC credentials and `platform-prod` environment configured; GitHub App created with runbooks. |
| **M1 - Default decisions** | Record v1 decisions without further spikes. | ADR-0001 to ADR-0005 accepted as defaults pending live smoke; ADR-0006 (Linux VMSS Flex) rejected for v1; ADR-0007 (isolated Windows VMSS Flex) accepted as a direction. |
| **M2 - Platform infrastructure** | Private-endpoint-only shared foundation deploys cleanly. | Network, observability, Key Vault, ACR, and internal ACA environment build/lint cleanly and deploy with `deployJobs=false`; no inbound access and NAT-only public IP. |
| **M3 - Runner image and consumer jobs** | Hardened image and registry-driven ACA jobs. | Image imported into ACR by digest; one ACA job per registry entry deploys with `deployJobs=true`; registry accepts only the `aca` backend. |
| **M4 - Platform CI/CD** | The repo runs itself through its protected workflows. | Required PR validation (`validate.yml` running `npm run validate`); main-only `platform-prod` staged deployment (`deploy.yml`) with post-deploy assertions; weekly maintenance workflow. |
| **M5 - Documentation** | An agent can operate and onboard without extra context. | Architecture, onboarding, operations, and security guidance are complete and linked from `AGENTS.md`. |
| **M6 - v1.0 acceptance** | Prove ACA end to end. | A smoke workflow in public `jonathan-vella/ghr-smoke` runs on the real ACA runner and lists an empty blob container (consumer OIDC identity with Storage Blob Data Reader) in a storage account with public network access disabled, reached only through a private endpoint in `snet-consumer-pe`; automated no-public-endpoint check is green; `v1.0.0` tagged. #74 is not a v1.0 dependency. |
| **M7 - Isolated Windows runners** | Ephemeral Windows runners on VMSS Flex, isolated from the ACA platform ([ADR-0007](adr/0007-windows-vmss-isolated-runners.md)). Does not gate v1.0. | `apex-vnext` `windows-package-tests` passes on the Windows runner with wall time and cost recorded against the ~46-minute hosted baseline; workers are ephemeral with no identity or secrets and no link to the ACA platform; fork-PR approval verified; teardown leaves no VMs or registrations. |

## v1 decisions (2026-10-08)

- v1 uses Azure Container Apps jobs only. Deploy directly into the existing empty `rg-ghrunners-prod-swc` through the
  `platform-prod` OIDC workflow: GitHub-hosted image build → private GHCR → foundation (`deployJobs=false`) →
  `az acr import` by digest into ACR (trusted-services bypass on) → jobs (`deployJobs=true`).
- No further spikes. Archival spike harnesses stay on disk but are not part of `npm run validate`.
- Merge bar: CI build, `npm run validate`, and one agent code review with no blocking findings, then agent merge.

**Historical (superseded):** the dual-backend plan (tracker #59, VMSS issues #60–#72, #81, #84), the D4 evidence rule,
and the Linux VMSS controller design in the private network are superseded by the ACA-only decision for Linux; see
[ADR-0006](adr/0006-vmss-flex-spike.md). Those issues are closed.

## Windows runners (2026-10-11)

ACA cannot run Windows. Windows jobs use a separate, isolated VMSS Flex backend with no link to the ACA platform
([ADR-0007](adr/0007-windows-vmss-isolated-runners.md)); work is milestone M7 in the [backlog](backlog.md), tracked by
[#93](https://github.com/jonathan-vella/azure-gh-runners/issues/93). It does not gate v1.0.

## Status (2026-10-11)

The ACA platform deployment is **paused**. The foundation deployed (network, Key Vault, ACR, identity, Log Analytics,
smoke storage); the ACA environment kept failing with `AKSCapacityHeavyUsage` because the AVM module defaulted to
`zoneRedundant: true`. #92 sets `zoneRedundant: false` but never got a clean run. The owner deletes
`rg-ghrunners-prod-swc`, and the next step is a full plan review and a non-zonal retry. Handoff:
[#34 comment](https://github.com/jonathan-vella/azure-gh-runners/issues/34#issuecomment-6068366703).

## After v1.0 (not scheduled)

- Onboard `apex-vnext` as the first real consumer (separate plan in that repository).
- Optional per-consumer subnet or environment isolation for high-sensitivity consumers.
- Optional additional image variants if consumers need tools beyond the generic set.
- Revisit a Linux VMSS Flex backend in the private network only if ACA proves insufficient ([ADR-0006](adr/0006-vmss-flex-spike.md)).
- Revisit GitHub organization + larger runners with VNet injection if repositories move into an organization.
