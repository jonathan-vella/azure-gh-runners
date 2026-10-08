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
Workers must run one job as nonroot with no Docker/sudo/MI. A new spike-only key for the same GitHub App belongs
only on the private controller through approved private KV delivery; never use the production `platform-prod` key.
JIT belongs in protected CSE handoff settings, never logs or secret env.

Preparation compiles v0.4.0 and delivers isolated AVM-pinned infrastructure, bounded listener/controller,
protected CSE single-job bootstrap, durable original-envelope guards and an independent hosted cleanup job.
Deployment remains source-disabled. The owner-directed #81 supersession defines one full run as exact RG
bootstrap plus unique temporary app/SP/GA FIC/RG-only Owner, RG-scoped foundation, worker, test and verified cleanup.
The cap is two complete sequential runs within one original four-hour/$10 envelope; run 2 requires verified
resource/identity/environment cleanup and exact prior key revocation. No per-step retry is permitted.
Native Ubuntu bootstrap preserves the shared tool manifest/hook rather than reproducing a container rootfs.
No cloud experiment was performed; implementation is not runtime proof or an accepted backend decision.
Reviewed smoke commit/blob pins and a spike-only pre-job commit guard prevent mutable `main` from admitting
unreviewed workflow code; the shared consumer policy schema and hook remain unchanged.

## Consequences

- Personal-installation support, runner group and custom-label routing still require live proof.
- Native Ubuntu 24.04 build 20260926 supplies the checksum-pinned local rootfs evidence. The cloud path instead
  requires an exact verified Gen2 Marketplace version and existing owner-approved public key; it imports/builds
  no image. Actual boot/package/kernel/agent/CSE readiness remains unproved. Gallery/VMI Builder is later scope.
- Complete positive refreshed meters, both-run bootstrap traffic, peak resources and explicit cleanup/image/log/KV/
  miscellaneous reserves must fit strictly below $10. Native byte/DNS quotas and Premium_LRS disks bound variable
  costs; enforcement and actual runtime fit still require authorized evidence.
- Controller authorization must remain limited to exact-RG VM/Network Contributor and the owner-approved
  Key Vault Secrets User grant at the one versionless secret scope for that ordinal's unique vault. The
  deployment path waits for exact owner-created assignments and performs no role writes.
- Keep #60 open. Record real private/NAT paths, policy rejection/allow, identity/privilege assertions, one-job
  deletion, Flex protection/notifications and failure recovery only after the authorized experiment.
- Every outcome requires exact-owned RG deletion and absence verification. Diagnostics cannot skip cleanup.
  The owner accepts seven-day soft-delete retention with purge protection disabled; vault names are derived from
  the immutable original envelope run ID plus full-run ordinal, and deleted vaults must expire naturally without
  purge, recovery, or reuse.
  Loss of both controller/workflow recovery remains unproved. Offline tests select no backend.
- Dedicated main-only `spike-vmss` uses an exact immutable GA environment subject; flexible/reusable trust is
  rejected. Another reviewed main workflow can reference the environment: the owner accepts this residual, not
  cryptographic caller-workflow pinning. Repository-wide customization and production trust remain unchanged.
- Approved coordinator automation handles ONE new App 5224898 spike key, only the dedicated environment secret,
  exact-key revocation and temporary-copy deletion. Manual-only handling is superseded; safe tooling remains
  blocked. A two-run ceiling does not authorize key two. Paid cleanup never waits for key revocation.
- Canonical delete intent/acknowledgement and crash locks fail closed on ambiguous/late outcomes. The independent
  hosted backstop remains source-disabled; canonical cross-host cleanup coordination and demonstrated available
  recovery are required before enabling anything. Workstation-only recovery is not approved for execution.
- No external IP echo. NAT evidence is ARM configuration plus successful GitHub/job completion, not byte-level
  source-IP measurement or private-PaaS connectivity proof.

## Status

**Proposed; incomplete for cloud execution.** #10/dependency direction, safe scoped-key tooling, exact Marketplace
guest verification, complete effective pricing/quota and actually available reviewed recovery remain gates.
Offline client/native tests and template builds are not feasibility or live acceptance evidence.
