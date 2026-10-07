# VMSS Flex spike: disabled code preparation

Issue [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60); **partial draft, do not merge until reviewed**.
The controller, isolated infrastructure and bounded executor are implemented for review, not execution-ready.
No cloud experiment, role write, App-key retrieval/seeding, image import or smoke-repository change was performed.
Keep #60 open and ADR-0006 Proposed. This does not select a backend or enable VMSS consumer onboarding.

## Delivered components

- `infra/subscription.bicep` creates the exact tagged RG and nests the AVM-pinned foundation in **one** top-level
  subscription deployment. `infra/worker.bicep` creates one deterministic VM/NIC/disk and protected CSE in **one**
  subsequent group deployment. There is no separate RG create, CSE create or automatic deployment retry.
- The official `actions/scaleset` **v0.4.0**, commit `6ce025902cd964747a078c2aabe7340ebc667eca`, is compiled and
  tested against its real client/listener interfaces. One repository scale set/custom label serves `ghr-smoke`.
  Demand comes from the official listener's `TotalAssignedJobs`, not speculative workflow/queue matching.
  The client uses verified ClientID `Iv23liLOmKrlxX0rFd2z`, never a numeric App-ID substitution.
  Personal-installation/default-group-1/custom-label behavior remains a live compatibility assertion.
  Approval pins the smoke `main` commit and workflow Git blob. Preflight rejects changed `main` and fetches
  the workflow at the immutable approved commit, comparing the exact blob ID. A root-owned spike-only
  pre-job wrapper requires both `GITHUB_WORKFLOW_SHA` and `GITHUB_SHA` to equal that reviewed commit before
  invoking the unchanged shared policy hook. A branch movement after preflight therefore cannot admit new code.
- The private controller persists its original clock, scale-set ID, captured runner ID, request ID and attempt
  reservation before mutation. Re-delivery is idempotent; a second job/request is rejected. Provisioning is
  asynchronous so CSE execution cannot block listener callbacks. Restarts recover/clean up; they never provision
  another worker. Outstanding worker deployment is canceled/reconciled before exact VM/NIC/disk absence checks.
  A missing deployment record after an ambiguous dispatch is not certified absent; whole-RG cleanup still runs.
- JIT is encoded only into the worker deployment's secure `jitProtectedScript` parameter/CSE
  `protectedSettings.script`, never an artifact, public setting, environment variable or CLI provisioning argument.
  CSE waits boundedly for the root-owned bootstrap marker, removes its exact handler script, protects agent files
  and invokes one nonroot job with a clean environment. Runner output is not copied into provider diagnostics.
  Internally the supported runner receives `--jitconfig`; this is not a claim of credential-free memory/argv.
- `Run.ps1` exposes offline Prepare/Inspect and separately gated Execute/Cleanup. The disabled workflow
  `.github/workflows/spike-vmss-flex.yml` is main-only, owner-dispatched and uses `platform-prod`. Its separate
  hosted-runner supervisor must have verified cleanup authority and be running before provisioning.
  It starts cleanup at the original three-hour work deadline, independent of the executor/controller.
  OIDC is refreshed boundedly using the same existing identity; no identity substitution or grant is implemented.
- Sanitized controller journal/outcomes are copied before RG deletion. Only named nonsecret artifacts are uploaded;
  private key, JIT, provider errors and extension logs are never uploaded. Diagnostic failure cannot skip cleanup.

Exact AVM pins: VM `0.22.0`, NSG `0.5.0`, NAT `2.1.0`, VNet `0.10.0`, private DNS `0.8.0`, Key Vault `0.14.0`.
The Flex shell/instance protection use documented Compute APIs; raw CSE is necessary because the VM module's
Custom Script surface does not expose inline `protectedSettings.script`. These are isolated spike exceptions,
not persistent-platform module choices.

## Immutable native bootstrap and offline validation

Use PowerShell **7.5 or newer**, existing Linux Docker, Node/npm and Azure CLI/Bicep:

```powershell
npm run validate:spike-vmss
npm run validate
$head = git rev-parse HEAD
.\spikes\vmss-flex\Run.ps1 -Action Prepare -Head $head -ManifestPath C:\operator-artifacts\vmss60.json
.\spikes\vmss-flex\Run.ps1 -Action Inspect -ManifestPath C:\operator-artifacts\vmss60.json
```

Prepare never overwrites a manifest and makes no cloud calls. Use an existing parent outside source control.
Each writer locks its state and commits atomically. The original four-hour clock cannot be reset on restart.

`Test-Client.ps1` uses Go 1.25.3, Linux/amd64 builder
`golang@sha256:414a753c2f67d0efccb01b5f58b3d3a8a2cbb7c012ce9e535418b5b3492b2c24`.
Its ten-minute subprocess and exact container cleanup are bounded. No shared-host Go installation is needed.
The controller uses a native checksum-pinned Go compiler, SHA256
`0335f314b6e7bfe08c3d0cfaa7c19db961b7b99fb20be62b0a826c992ad14e0f`, not Docker.

The cloud path accepts only an explicitly verified, non-`latest`
`Canonical:ubuntu-24_04-lts:server:<exact-version>` Gen2 Marketplace image in Sweden Central.
It imports/builds no boot image, Gallery or VM Image Builder. The exact regional version is an unresolved
preflight input; do not infer it from a daily build date. Supply an **existing owner-approved SSH public key**
for Azure OS provisioning; no key/password is generated and all inbound denies remain.
Controller admin is `ghrcontroller`, worker admin is `ghrworker`; the actual controller service is UID 1002 and
runner is UID/GID 1001. Account conflicts fail closed rather than silently remapping job privileges.

`native-image.json` pins Canonical Ubuntu 24.04 build **20260926** and its same-build rootfs solely as local
bootstrap evidence. The dated VHD is research evidence, **not** an imported/deployed image.
The runner archive is checksum-pinned to the shared `image/versions.json`. Native bootstrap authenticates Git's
PPA by full fingerprint, installs/checks every exact inherited package version, reuses the complete shared
installer/nonroot verifier and installs root-owned mode-0555 hooks. It does not require a matching container
rootfs or Docker. The shared installer only permits `dockerd` to be already absent (`rm -f`).
The real rootfs harness is bounded to twenty minutes; tool bootstrap/job execution each have a fifteen-minute bound.
**The job's 15-minute bound is smoke-specific, not a change to the registry's 360-minute policy.**

Go/native fixtures and Bicep builds do not prove Azure boot, agent/CSE readiness, kernel firewall enforcement,
private scheduling, managed-identity absence or deletion. Record those only from authorized runtime evidence.

## Exact envelope and cost controls

Fixed subscription `b47d2942-f5ad-4d3c-b28e-c23e4f83d97e` (`shared`), tenant
`30bac921-1547-4b1e-8445-72455da783f1`, region `swedencentral`, RG **`rg-ghrunners-spike-vmss-swc`**.
One `Standard_B2s`; ceiling two `Standard_D2ls_v5`; **four hours total**, final hour reserved for cleanup;
**$10 cap**, $8 prepared envelope, $2 contingency.

The literal cap is **TWO aggregate top-level deployment/create invocations**, including failed/ambiguous calls,
not two trials. Under it, this executor supports **one foundation + one worker**, advertises capacity one and
never dispatches slot two. Root and controller durably reserve the same worker invocation before dispatch;
reservations are never refunded. Read/delete/cancel/run-command actions do not dispatch additional deployments.
Workflow re-runs are denied. The exact subscription deployment's nonsecret history is retained and checked
before creation to reject replay of an original envelope after RG deletion; it is not an extra cloud resource.
Worker names use `vm-ghr-spike60-<first-25-run-id-characters>-1` to fit Flex's 44-character limit;
NIC is `nic-<VM-name>`, disk is `disk-<VM-name>-os`. All ownership tags retain the full run ID and exact head.

Planning retail evidence on 2026-10-07: B2s $0.0432/hour, D2ls v5 $0.091/hour, PIP $0.005/hour.
These are not refreshed account-specific quotes. Before execution, a reviewed USD meter record must prove:

| Reserved category | Ceiling |
| --- | ---: |
| Compute, three P4 disk hourly charges, NAT, PIP, two PEs, DNS and hourly margin | $0.50/hour x 4 = $2 |
| NAT/PE processing, outbound bytes and DNS query allowance | $1.50 |
| Logs contingency (no paid guest-log sink is deployed) | $1.50 |
| Image/staging contingency (no Azure image build/staging is deployed) | $2 |
| Disk/miscellaneous/DNS/KV contingency | $1 |
| **Total envelope / hard cap** | **$8 / $10** |

P4 32-GiB Premium_LRS disks avoid Standard SSD transaction charges. Root-owned IPv4 kernel quotas cap each
guest to **2 GiB ingress + 2 GiB egress**, including bootstrap; IPv6 is denied, UDP DNS is limited to
2 queries/second plus burst 20, TCP DNS is denied. With this invocation cap there are at most **two guests**.
The priced maximum is 8.589934592 GB NAT traffic, 4.294967296 GB outbound and 4.294967296 GB PE traffic.
No reboot/reset/retry to regain byte allowance is authorized. Automatic guest updates are disabled.
The native kernel/quota modules and package/download size fit remain runtime assertions; failure stops work.
Guest readiness also verifies the shared manifest's exact baseline jq/curl/Python package versions;
the pinned Canonical manifest confirms these packages for the local rootfs, not an unselected Marketplace image.
Cost Management latency is not treated as a spending cap.

## Authorization and operator gates

**No execution is authorized now.** The workflow defaults disabled unless the owner separately enables
`GHR_SPIKE60_EXECUTION_ENABLED=true` after review and exact coordinator direction. Flags/booleans are records
of that decision, not a substitute for it. Keep the PR draft/do-not-merge and #60 open.

1. Resolve the open #10 dependency/ADR-0005 gate or obtain an explicit dependency decision. Review/merge the
   runnable code and give exact direction for the tested main head; retain the original limits.
2. `jonathan-vella/ghr-smoke` had no `.github/workflows` directory at preparation time. A custom-label smoke
   workflow/dispatch needs **separate reviewed scope**; this PR neither edits nor dispatches another repository.
   Verify public visibility, default `main`, selected workflow ref and existing App installation ID.
3. Existing OIDC rights are production-RG scoped, not evidence of subscription deployment or spike RG
   creation/deletion rights. Preflight and independent supervisor require verifiable existing authority.
   Missing or conditional/uncertain permissions stop before creation. **Never broaden/recreate an identity.**
4. **The extra secret-reader grant is NOT approved.** Proposed vault `kv-ghr-spike60-swc`,
   secret `github-app-private-key`; controller system-MI principal is known only after approved foundation.
   Minimal reader is Key Vault Secrets User **`4633458b-17de-408a-b874-0445c86b69e6`** at ONLY
   `/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike-vmss-swc/providers/Microsoft.KeyVault/vaults/kv-ghr-spike60-swc/secrets/github-app-private-key`.
   No version suffix in the RBAC scope; retrieval uses an explicit approved version.
   Seeding is only existing `platform-prod` `GH_APP_PRIVATE_KEY` -> owner-only temporary secure parameter ->
   nested ARM secret creation -> private KV retrieval on controller. Never retrieve it on a local checkout.
   Owner approval must cover that exact path and **seven-day encrypted soft-delete retention**.
   Purge protection is disabled; a tombstone can block name reuse. No purge/grant code is delivered.
5. Controller VM Contributor **`9980e02c-c2be-4d73-94e8-173b1dc7cf3c`** and Network Contributor
   **`4d97b98b-1d4f-4787-a291-c67834d212e7`** are restricted to exact spike RG scope.
   Broader Contributor `b24988ac-6180-42a0-ab88-20f7382dd24c` is NOT authorized on the controller.
   This executor implements no role writes; owner completes exact bindings within its bounded gate.
   It rejects additional/broader controller assignments rather than silently accepting them.
6. Supply a verified Marketplace image version, existing public key, immutable reviewed source archive SHA256,
   refreshed retail meters and NIC/disk/NAT/PIP/PE/DNS headroom evidence. The executor also reads actual
   registered providers, regional SKU restrictions and B-series/Dlsv5/six-vCPU usage; it requests no quota.

The nonsecret `approval_json` has exactly these keys: `schemaVersion=1`, `reviewedHead`,
`executionDirectionConfirmed`, `secretReadApproved`, `canonicalUbuntuVersion`, `installationId`, `workflowRef`,
`smokeCommitSha`, `smokeWorkflowBlobSha` (both exact 40-character lowercase Git object IDs),
`archiveSha256`, `adminSshPublicKey` (no comment), `pricing`, `quota`. No key/token belongs in this record.
The two confirmations must be actual booleans and explicitly approved; defaults are not approval.

`pricing` contains `refreshedUtc` in round-trip UTC format and positive finite USD rates:
`b2sHourly`, `d2lsHourly`, `p4Hourly`, `natHourly`, `pipHourly`, `peHourly`, `dnsZoneHourly`,
`natGb`, `egressGb`, `peGb`, `dnsMillionQueries`. Evidence must be at most 24 hours old; hourly/byte math must
fit the ceilings above. `quota` contains exact `subscription`, `location`, `refreshedUtc` and integer headroom:
`networkInterfaces>=3`, `premiumDisks>=2`, `natGateways>=1`, `publicIps>=1`, `privateEndpoints>=1`,
`privateDnsZones>=1`. These operator records are prerequisites, not claims that current quota/prices were queried.

## Future reviewed protocol and remaining acceptance

After **all** gates, dispatch the disabled workflow with the exact reviewed main head, approval record and
`run-spike60-reviewed`. Validation precedes the clock. Separate cleanup authority/readiness precedes foundation.
The single foundation creates private controller/Flex-zero-capacity/network/KV; owner supplies exact roles.
Service stays stopped until bootstrap marker, role scope and explicit secret-version checks pass.
One queued approved smoke job creates one JIT/CSE worker; correlated completion triggers cancellation/reconciliation,
VM/NIC/disk/runner/set cleanup and nonsecret evidence capture. Controller and whole-RG cleanup remain bounded
inside the original reserve; already-absent RG is idempotent Azure success, **not** GitHub/acceptance proof.

One worker can test **allow OR reject**, not both separate one-job workers under the existing two-invocation cap.
Local rejection fixtures are not live hook coverage. Full #60 acceptance still requires actual private/NAT
job assertions, no-MI/no-sudo/no-Docker/secret-env checks, Azure boot/CSE/tool verification, exact deletion,
Flex protection and **guest-observed** termination notifications. A configured API profile is not notification proof.
Any private-PaaS data target needs a separately approved connectivity/authentication path; no speculative storage
resource or worker identity grant is added.

Controller/runner/whole-workflow loss, interrupted supervision and provider deletion failure are **unproved**.
Separate hosted jobs cover executor-process/host loss, but whole-workflow cancellation can kill both; do not cancel
the cleanup job. If controller destruction makes GitHub cleanup inaccessible, report it and use an owner-approved
protected recovery path, never a local App-key download. Do not label this partial prep execution-ready until the
operator's independent recovery authority/availability and these risks are reviewed.

Manual recovery only after exact coordinator cleanup direction:

```powershell
.\spikes\vmss-flex\Run.ps1 -Action Cleanup -ManifestPath C:\operator-artifacts\vmss60.json -ConfirmCoordinatorCleanupDirection
```

Cleanup verifies exact subscription/tenant/RG/location/full ownership tags before deleting. Absence is polled,
failure persisted, and recovery bounded to 45 minutes. A late recovery never resets the four-hour envelope or
authorizes new experimental work; it cannot certify that an already-exceeded lifetime was respected.
