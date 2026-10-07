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

Preparation compiles v0.4.0 and delivers isolated AVM-pinned infrastructure, bounded listener/controller,
protected CSE single-job bootstrap, durable original-envelope guards and an independent hosted cleanup job.
Deployment remains disabled. One subscription foundation deployment nests RG/foundation resources; one worker
deployment nests CSE. The literal two-invocation cap is not two trials and cannot cover separate allow/reject workers.
Native Ubuntu bootstrap preserves the shared tool manifest/hook rather than reproducing a container rootfs.
No cloud experiment was performed; implementation is not runtime proof or an accepted backend decision.

## Consequences

- Personal-installation support, runner group and custom-label routing still require live proof.
- Native Ubuntu 24.04 build 20260926 supplies the checksum-pinned local rootfs evidence. The cloud path instead
  requires an exact verified Gen2 Marketplace version and existing owner-approved public key; it imports/builds
  no image. Actual boot/package/kernel/agent/CSE readiness remains unproved. Gallery/VMI Builder is later scope.
- The $8 envelope requires refreshed meters/headroom evidence; native byte/DNS quotas and Premium_LRS disks bound
  variable costs. Enforcement and actual runtime fit still require authorized evidence.
- Extra MI authorization covers only exact-RG VM/Network Contributor, not KV secret-reader grants.
- Keep #60 open. Record real private/NAT paths, policy rejection/allow, identity/privilege assertions, one-job
  deletion, Flex protection/notifications and failure recovery only after the authorized experiment.
- Every outcome requires exact-owned RG deletion and absence verification. Diagnostics cannot skip cleanup.
  KV seven-day soft-delete retention/name reuse and loss of both controller/workflow recovery are explicit
  owner-review gates, not authority for purge or broader roles. Offline tests select no backend.

## Status

**Proposed; incomplete for cloud execution.** #10, smoke scope, private credential authorization, exact Marketplace
version, refreshed pricing/quota and existing deployment/recovery authority remain gates.
Offline client/native tests and template builds are not feasibility or live acceptance evidence.
