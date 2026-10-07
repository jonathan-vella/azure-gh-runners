# ADR-0006: Bounded VMSS Flex feasibility protocol

## Context

Issue [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60) investigates private single-job VMSS Flex
after ACA regional capacity failures. Azure VMSS Flex and GitHub runner scale sets are distinct resources;
`actions/scaleset` supplies GitHub integration, not Azure provisioning.
Existing PRD/plan/defaults remain unchanged until real evidence and a separately reviewed backend decision.

## Decision

**Proposed only.** Prepare the [bounded protocol](../../spikes/vmss-flex/README.md) at the exact owner limits:
shared subscription/tenant, Sweden Central, `rg-ghrunners-spike-vmss-swc`, one B2s, at most two D2ls v5,
two attempts, four hours and $10 total. Reserve the final hour for cleanup.
Workers must run one job as nonroot with no Docker/sudo/MI. App credentials belong only on the private controller
through approved private KV delivery; JIT belongs in protected CSE handoff settings, never logs or secret env.

Preparation compiles v0.4.0, tests sanitized compatibility-probe cleanup, and provides durable offline guards
and exact-owned RG cleanup. A proposed checksum-pinned Canonical native Ubuntu build and bounded bootstrap adapt
account/Git installation while preserving the shared tool manifest and verifier. It does not deliver Azure
VM provisioning or the full executor. A tested protected CSE payload encoder and nonroot single-job helper
are delivered as components, not a running controller. No cloud experiment was performed.

## Consequences

- Personal-installation support, runner group and custom-label routing still require live proof.
- Native Ubuntu 24.04 build 20260926 supplies a dated Azure VHD and same-build rootfs test artifact.
  VHD import/boot generation/CSE readiness remain live assertions; persistent Gallery/VMI Builder is later scope.
- The $8 planning envelope has unverified ancillary ceilings; refresh prices and bound usage before execution.
- Extra MI authorization covers only exact-RG VM/Network Contributor, not KV secret-reader grants.
- Keep #60 open. Record real private/NAT paths, policy rejection/allow, identity/privilege assertions, one-job
  deletion, Flex protection/notifications and failure recovery only after the authorized experiment.
- Every outcome requires exact-owned RG deletion and absence verification. Offline tests select no backend.

## Status

**Proposed; incomplete for cloud execution.** #10 is open, smoke workflows are absent, credential delivery/native
Azure VHD boot are unverified; Azure quota, capacity and effective deployment rights have not been queried.
The pinned integration compiles and fake-API tests pass; this is not runtime feasibility evidence.
