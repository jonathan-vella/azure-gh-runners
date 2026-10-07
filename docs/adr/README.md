# Architecture Decision Records

Record significant decisions as `NNNN-short-title.md`, using sections Context, Decision, Consequences, and Status.

Planned ADRs from the M1 spikes:

| ADR | Topic | Backlog item |
| --- | --- | --- |
| 0001 | Image build path (ACR Tasks agent pool vs fallback) | `spike-acr-agentpool` |
| 0002 | Key Vault secret references over private endpoints | `spike-kv-ref-pe` |
| [0003](0003-egress-requirements.md) | Egress requirements (KEDA polling path) | `spike-keda-egress` |
| 0004 | Runner secret isolation (init container, EmptyDir, identitySettings) | `spike-job-identity-init` |
| 0005 | Runner labels and `runs-on` syntax | `spike-jit-labels` |
