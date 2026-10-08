# VMSS Flex spike: source-disabled code preparation

Issue [#81](https://github.com/jonathan-vella/azure-gh-runners/issues/81);
Refs [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60).
**Draft, do not merge or execute.** ADR-0006 remains Proposed and #60 stays open.
No cloud experiment, identity/grant/environment change, key operation or smoke dispatch was performed.
Offline validation is not VMSS feasibility or runtime acceptance evidence.

## Identity, trust and lifecycle

The [temporary-identity contract](temporary-identity.md) is the authoritative preparation protocol.
The owner supersedes the old two aggregate create calls with at most **two complete sequential full runs**
inside the **same original four-hour/$10 envelope**, including bootstrap, test and verified cleanup.
There is no per-step retry, new clock, allowance refund or third run.
The original nonce and ordinal bind each fresh app/FIC/assignment and unique seven-day vault.
Run two requires all prior resource/identity/environment cleanup and exact App-key revocation.
The current ONE-new-key authorization permits one seeded run, not a second key.

An authenticated workstation operator precreates/tags only `rg-ghrunners-spike-vmss-swc`, then creates a unique
single-tenant app/SP and grants temporary Owner ONLY at that RG. The production principal
`24ebb9cc-0e3b-4956-a333-5665a060f2c7` and production trust are never reused or widened.
`infra/main.bicep` deploys the foundation at **resource-group scope** into that precreated RG;
the subscription deployment wrapper is removed. `infra/worker.bicep` remains one worker deployment.
The nested worker parameter map retains the exact eight-key Go/Bicep contract; ordinal is top-level.

Use a standard GA FIC with issuer `https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange` and exact immutable subject:

```text
repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss
```

The dedicated environment is branch-main-only, with no reviewer or wait timer. Flexible preview/reusable trust
is rejected. The owner accepts that another reviewed main workflow can reference this environment:
this is environment federation plus repository review, **not cryptographic caller-workflow binding**.
Hosted claim verification emits only issuer/audience/subject and immutable repository/owner IDs; synthetic
fixtures are not actual observed token-exchange evidence. Never retrieve a GitHub OIDC token locally.

The coordinator exclusively owns the approved ONE new spike-only key for GitHub App **5224898**, temporary
handling to seed `spike-vmss` secret **`GH_APP_PRIVATE_KEY`**, exact new-key revocation and temporary-copy deletion.
This supersedes manual-only UI handling. Safe tooling is currently blocked, not owner authorization:
no key has been created. Production keys and `platform-prod` remain untouched.
The workflow maps only this dedicated environment secret to `GHR_SPIKE60_APP_PRIVATE_KEY` for the ARM secure
parameter-file step. Missing actual seed evidence, fingerprint or secret fails closed. The legacy runtime field
`ownerRevocationConfirmed` records actual approved delegated coordinator evidence, not an owner-only UI mandate.
App fingerprints use GitHub's SHA256 over DER SubjectPublicKeyInfo, standard padded base64 (44 characters).
Before ARM, the supplied PEM is imported in memory and its public fingerprint must match BOTH immutable ledger
and approval. PKCS1/PKCS8 normalize identically; no private-key subprocess/file is used for verification.

Paid cleanup is RG first, then exact Owner assignment, FIC, app, SP and environment. Credential revocation never
delays it, but pending revocation prevents full cleanup or another seeded run.
The canonical adapter serializes cleanup, persists delete intent before requests and distinguishes a successful
request acknowledgement from absence. Issue [#85](https://github.com/jonathan-vella/azure-gh-runners/issues/85)
adds revision-fenced intents and sanitized actual provider receipts, with bounded read-only terminal settling,
not a bare 202/no-wait response. The injected shared coordinator is a mock only; without real authorized
cross-host CAS the adapter fails closed before authentication. Local snapshots/artifacts are not ownership.
Runtime RG-only `closed` is explicitly not full identity/environment/key cleanup.
Lost responses, stale crash locks and ambiguous late creation remain explicitly unresolved;
never retry deletes, force locks, infer terminal absence from an early 404 or certify full cleanup.

The independent hosted cleanup backstop is retained, but all authenticated execution/cleanup paths and the
workflow have **source-disabled gates**. Environment flags cannot enable them.
Cross-host coordination with the external canonical ledger, actual independent recovery availability and
abrupt operator/whole-workflow loss remain blocking execution review points. A workstation watcher is not an
approved sole recovery architecture. No additional identity, grant or secret transfer is authorized to solve this.
Do not start paid work until exact reviewed coordination, supervisor start/keepalive checks, failure signaling
and authoritative cleanup reconciliation are demonstrated. Readiness booleans record evidence; they do not
prove availability or replace authorization. Post-start recovery loss/provider deletion failure requires explicit
escalation of surviving inventory, original deadlines and continuing billing exposure.

## Controller and credential isolation

The official `actions/scaleset` v0.4.0, commit `6ce025902cd964747a078c2aabe7340ebc667eca`, uses its actual client
and listener interfaces. Verified ClientID is `Iv23liLOmKrlxX0rFd2z`; installation/default-group compatibility
remains a runtime assertion. Creation, cleanup and the standalone probe use the same ordinal-qualified label:
`ghr-smoke-vmss-spike-<32-lowercase-hex-runId>-<runOrdinal>`.
The controller journal retains original nonce, ordinal, clock, head, scale-set/runner/request IDs and reservations.
Redelivery is idempotent; another request and resumed provisioning are rejected.

Controller VM Contributor `9980e02c-c2be-4d73-94e8-173b1dc7cf3c` and Network Contributor
`4d97b98b-1d4f-4787-a291-c67834d212e7` remain exact-RG-only. Key Vault Secrets User
`4633458b-17de-408a-b874-0445c86b69e6` is restricted to that ordinal's single versionless
`github-app-private-key` secret scope. The executor implements no controller role writes or broader grant.
Controller retrieval uses the exact ARM-created secret version.
Vault name is `kv-ghr60-<first-14-runId-characters><ordinal>`; retention is seven days, purge protection off.
Unavailable/tombstoned names stop: no substitution, purge, recovery or reuse.

JIT travels only through the worker's secure deployment parameter/CSE protected settings, never artifacts,
public settings, environment variables or provisioning CLI arguments. The supported runner internally consumes
`--jitconfig`; this is not a credential-free-memory/argv claim.
Nonsecret controller evidence is copied before RG deletion; provider/extension logs, JIT and private keys are
never uploaded. Diagnostics failure must not be represented as successful cleanup.

## Native guest and smoke contracts

The cloud path requires an exact verified, non-latest Gen2
`Canonical:ubuntu-24_04-lts:server:<version>` in Sweden Central. No image import, Gallery or VMI Builder.
The regional candidate `24.04.202609040` is metadata evidence, not a proven guest baseline.
The coordinator owns approval of a fresh spike-only SSH **public** key; never read/reuse private home keys.
No private key is generated or transferred by this code.

`native-image.json` pins Ubuntu 24.04 build 20260926 solely for offline rootfs evidence.
Guest ingress/egress and DNS quotas precede downloads and exact minimal jq/curl/Python package adaptation.
The shared installer/verifier supplies inherited toolset evidence; the spike-specific runtime verifier checks
the actual spike wrapper/delegate, root ownership/modes, exact manifest, UID/GID and groups.
Native hardening removes sudo and executable setuid/setgid access. The shared/container verifier is unchanged.
Neither an empty identity environment nor IMDS denial proves no managed identity: ARM identity readback is needed.
The smoke-specific one-job timeout is 15 minutes, not a change to the consumer registry's 360-minute policy.

Reviewed no-echo smoke pins after merged `jonathan-vella/ghr-smoke#4`:
main commit `ad2c6e8b84654ce29774f32ecabc38914c8817cd`, workflow blob
`be116700ef35fdd7ff115005193239dc15e0a05b`, path `.github/workflows/vmss-smoke.yml`.
These supersede ALL prior #2 pins; preflight still recaptures exact remote main/blob before any authorized run.
The root-owned spike hook pins both `GITHUB_WORKFLOW_SHA` and `GITHUB_SHA`; the shared policy hook is unchanged.
No IP-echo service or `expected_nat_ipv4` input is allowed.
NAT evidence is ARM worker subnet/NIC readback (`defaultOutboundAccess=false`, no VM/NIC public IP, attached NAT)
plus successful worker GitHub connection/job completion: observational configuration-plus-completion,
**not byte-level source-IP measurement**, and not private-PaaS connectivity proof.

## Original envelope and validation

Fixed subscription `b47d2942-f5ad-4d3c-b28e-c23e4f83d97e` (`shared`), tenant
`30bac921-1547-4b1e-8445-72455da783f1`, region `swedencentral`.
Peak reserve is one B2s, two D2ls v5, three P4 disks, NAT/PIP and two PEs for the original four hours, including
cleanup. Two full DNS-zone and per-run KV charges plus combined image/log/miscellaneous/cleanup reserves must
fit **strictly below $10**. There is no partial $8 envelope or unpriced contingency fallback.
Both runs reserve four guests total, 17.179869184 GB NAT, 8.589934592 GB outbound,
17.179869184 GB PE ingress plus egress and 115,280 DNS queries. Quotas cannot reset on retry/reboot.
See the exact positive, refreshed meter schema in the identity contract. Fixture rates are not an account quote;
deletion failures can accrue beyond planned time/cost limits.

Use PowerShell 7.5+, existing Linux Docker, Node/npm and Azure CLI/Bicep:

```powershell
npm run validate:spike-vmss
npm run validate
node .\spikes\vmss-flex\identity-cli.mjs prepare C:\operator-artifacts\identity.json <reviewed-40-character-head>
node .\spikes\vmss-flex\identity-cli.mjs inspect C:\operator-artifacts\identity.json
```

Offline Prepare uses a pre-existing external parent, creates state once and starts no clock or cloud call.
Only future reviewed bootstrap begins the original clock before any RG/app create.
Reserve the canonical foundation handoff before dispatch; `Run.ps1 -Action Prepare -IdentityEnvelopePath ...`
imports that existing original ledger and never starts a hosted clock/nonce.
The workflow's `identity_envelope_json` and `approval_json` must be nonsecret. Approval retains exact head,
execution/secret direction, image, installation/workflow/commit/blob, archive checksum, public key, App-key
fingerprint, complete pricing and quota. Bootstrap additionally requires actual dependency, public-key,
scoped-tool and independent-recovery readiness. No flags enable the source gates.

The pinned Linux Go container tests the actual PowerShell-generated JSON against Go's worker validator,
including rejecting an extra nested ordinal. The bounded real-rootfs fixture checks native adaptation and
privilege rejection. Neither proves cloud boot, CSE, firewall enforcement, scheduling, termination notifications,
private PaaS access or deletion. #10/dependency direction, complete effective meters, native runtime fit,
safe key tooling and available reviewed recovery still block any execution.
