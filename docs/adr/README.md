# Architecture Decision Records

Record significant decisions as `NNNN-short-title.md`, using sections Context, Decision, Consequences, and Status.

v1 is Azure Container Apps (ACA) jobs only, and no further spikes are planned. ADR-0001 to ADR-0005 record default
decisions; the real `platform-prod` deployment and the `ghr-smoke` smoke test provide the live evidence.

| ADR | Topic | Status | Backlog item |
| --- | --- | --- | --- |
| [0001](0001-image-build-path.md) | Image path: GitHub-hosted build → private GHCR → `az acr import` by digest | Accepted (default, pending live smoke), 2026-10-08 | `spike-acr-agentpool` |
| [0002](0002-key-vault-secret-references.md) | Key Vault secret references via one UAMI; ARM secure secret fallback | Accepted (default, pending live smoke), 2026-10-08 | `spike-kv-ref-pe` |
| [0003](0003-egress-requirements.md) | Egress: NAT Gateway, outbound 443 to Internet | Accepted (default, pending live smoke), 2026-10-08 | `spike-keda-egress` |
| [0004](0004-runner-secret-isolation.md) | Runner secret isolation (init container, EmptyDir, no main-container MI) | Accepted (default, pending live smoke), 2026-10-08 | `spike-job-identity-init` |
| [0005](0005-runner-labels.md) | Custom label only; `runs-on: ghr-<name>` | Accepted (default, pending live smoke), 2026-10-08 | `spike-jit-labels` |
| [0006](0006-vmss-flex-spike.md) | VMSS Flex backend | Rejected (deferred for v1), 2026-10-08 | [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60) |
