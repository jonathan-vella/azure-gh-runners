# VMSS Flex spike: code preparation only

Issue [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60).
**Draft; do not merge until reviewed. No deployment command or worker backend is delivered yet.**
These are executable preparation utilities, not an end-to-end VMSS proof.
No Azure calls, role writes, App-key retrieval, GitHub scale-set creation or consumer edits were performed.
Existing architecture/defaults are unchanged; neither ACA nor VMSS is selected by this work.

## Runnable preparation

From the repository root, with PowerShell 7 and existing Linux Docker:

```powershell
npm run validate:spike-vmss
npm run validate

$head = git rev-parse HEAD
.\spikes\vmss-flex\Run.ps1 -Action Prepare -Head $head -ManifestPath C:\operator-artifacts\vmss60.json
.\spikes\vmss-flex\Run.ps1 -Action Inspect -ManifestPath C:\operator-artifacts\vmss60.json
```

Use an existing manifest parent directory outside source control. Prepare never overwrites a manifest.
Prepare/Inspect are offline. The strict manifest has no secrets or free-text provider output.
Run.ps1 takes an exclusive writer lock and replaces state atomically.
`Start-SpikeClock` and `Reserve-SpikeAttempt` are tested library functions for the future executor:
start once immediately before RG creation, reserve attempts durably **before** deployments, never reset on restart.
They are deliberately not exposed as deployment commands. A manifest is not an Azure spending cap or watchdog.

`Test-Client.ps1` compiles, vets and tests the actual pinned client with readonly dependency checks.
It uses Go 1.25.3 bookworm, Linux/amd64 digest
`sha256:414a753c2f67d0efccb01b5f58b3d3a8a2cbb7c012ce9e535418b5b3492b2c24`.
No Go installation or Docker runtime is added to workers.
The test subprocess is bounded to ten minutes and the exact named Docker container is removed in `finally`,
including when the Docker CLI times out.
`Test-Native.ps1` builds a checksum-pinned Canonical native Ubuntu root filesystem in Docker solely as a local
test harness, runs the native installer and the full shared verifier, and removes its exact temporary image tag.
Its build is bounded to twenty minutes; the guest bootstrap itself is bounded to fifteen minutes.

## Verified upstream contract

The official [v0.4.0 source](https://github.com/actions/scaleset/tree/v0.4.0) resolves to
`6ce025902cd964747a078c2aabe7340ebc667eca`; go.sum pins the module. Go 1.25.3 is required.
The library is Public Preview and supplies no Azure provisioning backend.

- `NewClientWithGitHubApp(ClientWithGitHubAppConfig, ...HTTPOption)` supports repository URLs.
  `GitHubAppAuth.ClientID` accepts the ClientID (source also permits numeric App ID).
  Authenticated public metadata for `jonathan-vella-gh-runners` returned ClientID `Iv23liLOmKrlxX0rFd2z`,
  App ID `5224898`, Administration write, Actions read and Metadata read. No key was requested.
- `CreateRunnerScaleSet` takes `RunnerScaleSet{Name, RunnerGroupID, Labels, RunnerSetting}`.
  Use one set per smoke consumer and one custom label. Default group `1` is a **live compatibility test**.
  Label type defaults to `System`; an absent set lookup returns `(nil, nil)`.
- `GenerateJitRunnerConfig(ctx, *RunnerScaleSetJitRunnerSetting{Name, WorkFolder}, scaleSetID)` returns
  `RunnerReference` and `EncodedJITConfig`, not the repository REST JIT contract.
  A compile-time interface checks the real signature; this probe deliberately **never mints JIT**.
- Future demand handling must use `listener.New`/`listener.Run` and the three `Scaler` callbacks,
  with `TotalAssignedJobs`, not workflow-list matching or message counts. Advertise capacity at most two;
  correlate lifecycle events by captured runner ID. No speculative queue matcher is implemented.

### Compatibility probe on the future private controller

The compiled command refuses Windows, root execution, invalid run IDs/deadlines and IMDS metadata outside
the exact subscription/RG/region/B2s/controller name `vm-ghr-spike60-controller`.
Only then does it read `/run/ghr-vmss/app.pem`, a regular mode-0400 file supplied by the approved
controller-only credential path. **Never retrieve this key locally or put it in env, builds or worker settings.**
The selected-repository installation ID is a nonsecret operator prerequisite.

```bash
./vmss-spike-probe \
  -execute-on-private-controller \
  -installation-id <existing-installation-id> \
  -run-id <manifest-run-id> \
  -work-deadline <manifest-work-deadline-in-RFC3339>
```

This creates a uniquely named custom-label repository scale set, verifies readback, deletes its captured ID,
and verifies absence. Pre-existing sets are refused. Ambiguous create failures resolve the unique owned name
using a separate cleanup context. API calls have 20-second timeouts and no automatic retries.
Only a scale-set ID and allowlisted outcome are printed; upstream errors/bodies/logs are suppressed.
The experiment has a one-minute deadline plus one minute for cleanup. Unverified cleanup fails explicitly.
The future executor must persist sanitized evidence and recover any recorded set ID.
This does **not** prove JIT registration, scheduling, worker isolation or Azure lifecycle.

### Protected worker handoff component

`workerProtectedSettings` is an offline-tested controller library component, not a VM provisioning command.
It uses the real v0.4.0 JIT method, validates the exact VM name/runner ID/set ID and narrow smoke policy,
and returns only a CSE `protectedSettings.script` payload plus the captured runner ID.
The [Linux CSE inline-script contract](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/custom-script-linux)
supports a base64 script in protected settings. The payload remains secret even though base64-encoded;
never log or persist it. The future Azure backend must send it directly over ARM HTTPS, handle ambiguous failures
and reconcile/remove the captured GitHub runner on all failure paths.

The root CSE script deletes its own exact handler script before starting the job, checks root-owned mode-0555
hook/helper files, passes JIT on stdin (not an environment variable or provisioning argument), and drops to
runner with a clean env and fifteen-minute timeout. `run-one-job.sh` verifies the nonroot UID/GID, consumes stdin,
and invokes the supported single-use JIT runner. Internally the runner necessarily receives `--jitconfig`;
protected delivery is not a claim that the runner never holds this credential in memory/argv.
No live JIT credential was minted. Real CSE settings-file permissions, hook behavior, MI absence and one-job
deletion remain runtime assertions; native bootstrap alone does not attest these Azure properties.

## Budget before execution

Hard limits: **$10 USD total**, **four hours overall**, **two attempts**, **one B2s**, **two D2ls v5**.
Reserve the final hour for cleanup; experimental work stops at start + three hours.

Public [Azure retail prices](https://prices.azure.com/api/retail/prices) on 2026-10-07 returned Sweden Central
non-Spot Linux rates: B2s $0.0432/hour, D2ls v5 $0.091/hour, E10 LRS Standard SSD $9.60/month plus operations,
and Standard IPv4 PIP $0.005/hour. These are planning evidence, not quota or account-specific quotes.

| Cost item | Conservative four-hour envelope |
| --- | ---: |
| One B2s plus two D2ls v5 continuously allocated | $0.91 |
| Three OS disks, ceil $0.03/hour combined | $0.12 |
| NAT resource, ceil $0.06/hour | $0.24 |
| Sole NAT PIP, ceil $0.01/hour | $0.04 |
| At most two PEs, ceil $0.04/hour combined | $0.16 |
| Hourly uncertainty margin (total hourly ceiling $0.50) | $0.53 |
| NAT/PE processing and outbound bytes | $1.50 |
| Log ingestion/retention | $1.50 |
| Image preparation, staging and storage | $2.00 |
| Disk transactions | $0.50 |
| DNS, KV transactions and miscellaneous | $0.50 |
| **Total reserved envelope** | **$8.00** |

Fixed reserve $6 plus hourly ceiling $0.50. Ancillary NAT/PE/log/image figures are **unverified ceilings**,
not retrieved meter prices. Refresh them and tie them to enforceable byte/log/storage limits before execution.
Cost Management latency cannot enforce the cap. The missing executor must conservatively bound usage,
stop before $8 is exhausted and retain $2 contingency. Unbounded downloads, logs, storage or retries invalidate
the budget. No extra image-builder VM is authorized.

## Actionable execution blockers

1. #10 remains open and ADR-0005 is Proposed. Close the dependency or obtain an explicit dependency decision.
   Merge/review preparation and receive exact coordinator execution direction; flags alone are not authorization.
2. `jonathan-vella/ghr-smoke` is public with default branch `main`; `.github/workflows` returns 404.
   Smoke jobs need **separate reviewed scope**. Do not install/dispatch workflows here. Positive/negative hook
   jobs need the same custom scale-set label; a negative job must actually reach the hook and run no user steps.
3. Verify selected App installation ID and private controller-only KV retrieval/delivery. The controller MI
   needs pre-authorized exact secret read access. **Key Vault Secrets User is outside the extra spike approval.**
   Existing deploy RBAC is production-RG-scoped and its delegated-role allowlist excludes VM/Network Contributor.
   Stop on missing exact spike-RG rights; do not broaden any deployment identity or add secret-reader grants.
   The minimal owner-authorized grant is Key Vault Secrets User
   (`4633458b-17de-408a-b874-0445c86b69e6`) for the controller's system-MI principal at the **single secret**
   `/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike-vmss-swc/providers/Microsoft.KeyVault/vaults/kv-ghr-spike60-swc/secrets/github-app-private-key`.
   Proposed exact vault name: `kv-ghr-spike60-swc`; secret: `github-app-private-key`. Name availability is unverified;
   stop rather than substituting a different name. Record final principal/version IDs after approved creation.
   Do not grant at vault/RG scope. Secret-level RBAC scope has no version suffix; the controller should retrieve
   an explicitly approved version over the private endpoint. Seed it only through the existing protected GitHub
   environment credential-to-ARM secure-parameter path, never by locally reading/downloading the key.
4. The proposed minimal native path is Canonical Ubuntu 24.04 LTS **20260926**, AMD64 Azure VHD:
   `https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-amd64-azure.vhd.tar.gz`,
   published SHA256 `3543723afd820d7a8a64ea7399376856a95ce15200439c38447170652a60a5f3`.
   Source: the dated official directory, SHA256SUMS and Azure VHD package manifest, not a `latest` image.
   `native-image.json` also pins the same-build rootfs test artifact and GitHub runner release archive.
   `native-bootstrap.sh` adapts native account creation, authenticates Git's PPA key by full fingerprint,
   installs the exact Git package version, checks every inherited manifest package, reuses the shared tool
   installer and full nonroot verifier, and installs root-owned mode-0555 hooks.
   The only shared installer deviation is allowing the Docker daemon path to be already absent (`rm -f`).
   No container rootfs identity or Docker runtime is required on the worker.
   The future executor must import/verify the fixed VHD inside this RG without Gallery/VMI Builder or another VM,
   verify its actual boot generation/size and Azure agent/CSE readiness, and pin the staged OS artifact.
   An offline rootfs tool test is not evidence of Azure boot/CSE/private-network behavior.
5. After direction, perform bounded quota/SKU/provider/effective-permission reads: six total vCPUs,
   B-series quota for one B2s, Dlsv5 quota for two workers and NIC/disk/NAT/PE capacity.
   No SKU/region/subscription/identity substitution is allowed.
6. Implement/review isolated AVM-pinned infrastructure, Azure worker lifecycle/CSE backend, controller service
   and independent deadline cleanup supervisor before the full attempt. **This probe is not that controller;
   no VMSS deployment is runnable in this revision.**

Items 1-3 and 5 are external authorization/evidence gates. Item 4 still needs Azure boot/import evidence.
Item 6 is an **implementation gap within #60**, not something blocked merely by missing credentials.
This partial PR does not satisfy #60 acceptance and must reference, not close, the issue.

Only Virtual Machine Contributor (`9980e02c-c2be-4d73-94e8-173b1dc7cf3c`) and Network Contributor
(`4d97b98b-1d4f-4787-a291-c67834d212e7`) may be assigned by agents to the spike controller MI at exact
`/subscriptions/b47d2942-f5ad-4d3c-b28e-c23e4f83d97e/resourceGroups/rg-ghrunners-spike-vmss-swc`.
No role-write code is delivered. Other persistent RBAC remains owner executed under a merged runbook.

## Required full-spike protocol (not yet executable)

1. Refresh budget and record reviewed head/run ID/deadlines; refuse an existing RG. Start the clock before
   RG creation, tag `spike-id=60`, `spike-run-id`, `spike-head`. Start independent exact-owned cleanup before
   provisioning. Persist at most two attempts before deployment requests.
2. Provision only private B2s controller, separate controller/worker/PE subnets/NSGs and identity-free workers
   with `defaultOutboundAccess=false`. NAT is the sole PIP. Deny inbound workload endpoints and worker access
   to controller/KV. Restrict controller MI permissions to approved exact scopes.
3. Prove personal-installation/group/label APIs; stop on failure. Use the pinned listener for one smoke-consumer
   set. Mint JIT per exact VM and deliver through **CSE protected settings**, consume/delete the guest handoff.
   No JIT in CLI provisioning arguments, env or logs. The runner internally requires `run.sh --jitconfig`;
   hide root/controller process data from job code.
4. Run one nonroot job per VM; prove private endpoint access/NAT IP, allowed/rejected hook behavior,
   no Docker/sudo/MI/secret env/token availability, and runner deregistration. Correlated completion must delete
   the exact VM, NIC and disk and verify absence.
5. Record actual Flex protection and guest termination notification behavior. Within the same budgets exercise
   controller loss, bootstrap failure, job timeout and failed deletion. Unknown outcomes stop scaling.
   An API response is not proof of guest notification. Save only allowlisted assertions/IDs.
6. Regardless of diagnostic failures, close/delete the captured GitHub set and clean the exact-owned RG in
   `finally`. Verify absence; leave no CSE payload/controller key. Failed assertions remain failures.

## Cleanup utility

This command makes Azure calls and must **not** run during the code-only phase:

```powershell
.\spikes\vmss-flex\Run.ps1 -Action Cleanup -ManifestPath C:\operator-artifacts\vmss60.json -ConfirmCoordinatorCleanupDirection
```

It refuses prepared manifests; validates tenant `30bac921-1547-4b1e-8445-72455da783f1`, subscription,
exact RG ID/location and three ownership tags; deletes only the owned RG; polls boolean absence with bounded
30-second commands. Already absent is idempotent success; delete/poll failures persist `cleanup=failed`.
No provider output is emitted. Recovery is bounded to 45 minutes inside the planned 60-minute reserve.
If resumed after the hard deadline it still attempts cleanup, never experimental work; report the overrun.
GitHub scale-set recovery remains an explicit executor duty, not part of Azure RG deletion.
