# Temporary spike identity: disabled preparation

Issues [#81](https://github.com/jonathan-vella/azure-gh-runners/issues/81) and
[#85](https://github.com/jonathan-vella/azure-gh-runners/issues/85);
Refs [#60](https://github.com/jonathan-vella/azure-gh-runners/issues/60).
Draft, **do not merge or execute**. `temporary-identity.mjs` contains exact request plans and a durable state machine.
`identity-adapter.mjs` orchestrates preflight/bootstrap and cleanup; `Identity-Transport.ps1` uses existing bounded
Azure CLI/GitHub CLI helpers. Both authenticated transport entry points have unconditional source gates;
`executeTemporaryIdentity()` also always rejects.
No resource, identity, environment, trust, grant or secret has been created by this preparation.
ADR-0006 remains Proposed; none of this is VMSS feasibility evidence.

## Owner-directed supersessions

The owner replaces the old literal two aggregate create/deploy calls with **at most two full end-to-end runs**
inside **one original combined four-hour/$10 envelope**, including bootstrap and all cleanup.
Each run is RG bootstrap + app/SP/FIC/Owner + foundation + worker + test + verified cleanup.
Failed or ambiguous calls consume their step; no intra-run create/deploy/delete retry is issued.
A second full run may start only after all first-run resources, identities and the environment are verified absent.
It inherits the original nonce, clock and combined cost allowance. Cleanup starts by the original three-hour
deadline; the final hour remains reserved. No third run, replenished clock or extra $10 budget is permitted.

`runId` is the immutable 32-character original envelope nonce. `runOrdinal` is integer 1 or 2 while running,
0 before any run. Each temporary app and FIC name and assignment ID derives from both fields.
Issue #80 binds its unique seven-day vault name to the same interface; no purge, recovery or reuse is authorized.
State reservations precede external writes; absent metadata after a timeout means **reconcile**, not retry or success.
Server-assigned app/client/SP/FIC and GitHub environment/policy IDs are captured atomically before advancing.
Schema v2 adds a monotonically increasing `revision` and sanitized `intents`: each mutation and deletion has a
unique operation ID, ordinal, reservation revision and optional provider receipt. Cleanup itself has a durable
intent that fences new bootstrap/foundation/worker reservations. Old v1 snapshots are rejected, not silently
upgraded into authority. Atomic local updates fsync the temporary file before rename. They are not distributed CAS.
An orphan lock requires read-only operator reconciliation, not removal to force another write.
State contains no credential or provider error output.

The owner **rejects flexible FIC preview and SHA-pinned reusable trust**. Use one standard GA FIC at
`https://graph.microsoft.com/v1.0/applications/<captured-app-object-id>/federatedIdentityCredentials`,
issuer `https://token.actions.githubusercontent.com`, sole audience `api://AzureADTokenExchange`,
and the expected exact immutable subject:

```text
repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss
```

This value is a **candidate until actual sanitized claim verification**, not observed token-exchange evidence.
`assertSanitizedEnvironmentClaims` accepts only issuer, audience, subject and immutable repository/owner IDs,
never a JWT, auth token or arbitrary claim dump. Repository subject customization and production app/SP/FIC
remain untouched. The dedicated `spike-vmss` environment must allow only branch `main` (not a tag named main),
with no required reviewers or wait timer. Only the spike workflow may reference it in reviewed repository code.
The owner explicitly accepts that another reviewed main workflow could reference this environment.
This is **environment trust plus PR-review control, not cryptographic caller-workflow pinning**.

Sources: [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc),
[GitHub environment API](https://docs.github.com/en/rest/deployments/environments),
[GA application FIC API](https://learn.microsoft.com/en-us/graph/api/application-post-federatedidentitycredentials?view=graph-rest-1.0).
The [flexible FIC preview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials)
was researched but is not adopted; it supports `job_workflow_ref`, not `workflow_ref`.

## Bootstrap and cleanup contract

An already-authenticated workstation operator, never the production SP, must verify the exact shared
subscription/tenant and existing bootstrap/deletion authority. Authentication or unexpected authority errors stop.
Before any RG/app/environment creation, persist the original clock, full-run reservation and exact names.
Require an absent exact RG, absent exact app name/tags and absent `spike-vmss` environment; do not adopt or modify
pre-existing objects. Create/tag only `rg-ghrunners-spike-vmss-swc` in `swedencentral`, then the uniquely named
single-tenant app/SP with no password, certificate or API permissions. Reserve each write once.
Create/read back the main-only environment and actual sanitized subject, then the single exact GA FIC.
Grant Owner only to the captured temporary SP at the exact spike RG, using its pre-reserved assignment UUID.
No subscription grant, production grant or fallback identity is permitted. Foundation must use group deployment
into that precreated RG, not a subscription deployment. No step retries or name reuse on propagation failures.

The owner subsequently approved **scoped coordinator automation** for ONE new spike-only key for GitHub App
**5224898**, temporary handling only to seed **`GH_APP_PRIVATE_KEY` in `spike-vmss`**, then exact new-key revocation
and temporary-copy deletion. This supersedes the earlier mandatory owner-only UI seed/revoke policy.
Production keys/`platform-prod` remain untouched. The coordinator exclusively verifies and executes that safe
tool path; this child/adapter implements **no** key generation, private-key read/transfer, duplicate creation
or revocation API. A tool-availability blocker is not missing owner authorization and never permits substitution.
Record the approved coordinator's canonical GitHub App fingerprint (SHA256 over DER SubjectPublicKeyInfo,
standard padded base64: 44 characters representing 32 bytes) and actual seed
confirmation, and wait only inside the original clock. Secret metadata existence is not confirmation.
The executor requires approval fingerprint equality with the original ledger and derives the supplied PEM's
SPKI fingerprint in memory before any ARM work. PKCS1/PKCS8 encodings normalize to the same public identity;
no fingerprint overwrite, private-key file/subprocess argument or sensitive crypto-error output is permitted.
This follows [GitHub's fingerprint verification](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps#verifying-private-keys);
hex and SSH-style fingerprints are not accepted.
Missing actual key-ready evidence/secret fails closed;
the intended workflow consumes it only through an owner-only temporary ARM secure parameter file, never argv,
logs, uploaded artifacts or a local checkout. Nonbillable environment pre-staging is not implemented or authorized
by this helper; it would need separately reviewed clock/cleanup handling.

Every outcome, including partial/ambiguous app/SP/FIC/environment creation and bootstrap exceptions, enters
cleanup with the same authenticated operator identity, independent of the temporary SP being deleted.
Reconcile exact captured IDs plus nonce/head/ordinal ownership; duplicate names, broader grants, extra credentials
or additional FICs stop unsafe deletes and leave cleanup explicitly unverified. No name-only identity deletion.
Delete/verify the RG first, then exact Owner assignment, FIC, app, SP, and temporary GitHub environment.
Azure/Entra cascades may make subsequent objects absent; only authoritative readback counts, never transport errors
or a permission-denied response. Observe a reserved delete outcome without issuing another delete.
Verify all objects absent (including SP after app deletion and the environment secret).
Paid RG/identity/environment cleanup must proceed without waiting for owner availability.
Separately require the approved coordinator to revoke **only** the spike key identified by the recorded fingerprint
and confirm exact revocation and temporary-copy deletion.
Report `credential-revocation` with pending evidence until confirmation; deleting an environment secret does not
revoke a GitHub App private key. Only then close the full run or consider run two. If a seed request was interrupted
before any fingerprint was captured, explicit coordinator evidence that no key was created is required;
absence of metadata is not evidence. No production-key download, revocation or substitution is authorized.
The two-full-run ceiling does not itself authorize a second GitHub App key after revocation of the approved ONE;
any second seeded run still requires matching scoped authorization and actual key-ready evidence.
Soft-deleted vault retention is the separately approved #80 exception, not a claim of purge or global name reuse.
Never delete production objects or require the now-deleted temporary SP to finish identity cleanup.

## Preparation limits and validation

The disabled transport bounds authentication and HTTP individually to 30 seconds (70-second outer process bound),
preserves structured metadata, suppresses provider errors and refuses partial Graph pagination.
Authenticated requests cannot run until a separately reviewed source change removes both source gates AND an
authorized canonical coordinator exists. Mock transports exercise the actual orchestration, not external services.
The prepared HTTP path captures actual ARM response operation headers rather than hiding the handle behind a
synchronous `az group delete` poller. A 202 without a usable handle stays unresolved. Only exact subscription,
Sweden Central operation URLs with an API-version-only query are supported; unknown handle shapes are capability
blockers, never rewritten into guessed endpoints. Graph/GitHub synchronous success records no fabricated handle.
Receipts contain only operation ID, provider, state and optional operation URL. A caller boolean `accepted:true`
is rejected; accepted is not terminal. Receipt persistence precedes identity capture and subsequent verification.
Terminal settling uses read-only GETs of the captured handle, never another mutation. Failed/canceled status,
404/403, lost response, timeout, unknown status and missing receipt cannot certify deletion. Terminal success plus
two consecutive authoritative absence reads is required; late visibility resets absence observation.
Settle each reserved create before collecting fresh owned cleanup inventory, including late Owner assignments.
A persisted terminal failed RG create may close through authoritative absence without any new PUT or DELETE;
failure of a DELETE never supplies that proof. Missing receipts remain unresolved.
The adapter persists server-generated identity IDs before advancing, reconciles ambiguous tagged app/SP/FIC creates,
and routes bootstrap exceptions into cleanup. GitHub environments cannot carry ownership tags; an interrupted
create with no captured environment ID requires operator reconciliation, never automatic name-only deletion.
The minimal injected `withExclusive(runId, callback)` interface supplies a session with synchronous `read()` and
`compareAndSwap(expectedEnvelope, nextEnvelope)`. Its authority must serialize the whole callback against both
hosts, including provider requests, reject stale revisions/content and persist every transition before returning
true. It is not a TTL lease that another host may take over while the previous request is still in flight.
CAS is committed before the local mirror rename. A crash in that gap leaves the mirror stale and it is rejected;
no automatic adoption, reset or retry is provided. The only supplied coordinator is an in-memory fixture.
Without an authorized durable implementation, bootstrap and cleanup reject before authentication or writes.
Cleanup also owns a local operation lock; locks record unique owner ID, host, PID, process-start and creation UTC,
and purpose. Inspection never equates PID existence with identity (PID reuse/remote hosts are ambiguous).
Crash-stale locks remain untouched even if their process is gone. No TTL unlock, blind unlink or lease takeover.
A reserved delete with no successful acknowledgement remains unresolved even if an early read says absent.
Ambiguous app/SP/FIC/environment/RG creation cannot become full cleanup from a missing ID or early empty inventory.
Cleanup polls reads without reissuing a reserved delete, bounded to 45 minutes; unknown/failed readbacks remain
unverified. In provider-failure recovery, surviving RG resources can continue accruing cost beyond the deadline:
record exact surviving inventory, original deadline and hourly exposure and escalate to the owner. A planned
conservative ceiling is not an absolute provider billing guarantee or an infinite deletion reserve.

`identity-cli.mjs` supports offline Prepare/Inspect and read-only `inspect-lock`; Bootstrap/Cleanup remain disabled.
Local CLI seed/revocation/foundation mutation commands now explicitly refuse: canonical evidence writers and
foundation/worker dispatch integration are unavailable. A runtime manifest records `cleanupScope:
resource-group-only`; its historical `closed` phase never means full canonical identity/key cleanup.
`Run.ps1` Execute/Cleanup and `Supervisor.ps1` have explicit unavailable-coordination gates in addition to the
existing source-disabled gates. Runtime file locks, workflow base64 input and artifacts cannot confer ownership.
Flags are records, not authorization.
Do not interpret reducer `absent: true` inputs as evidence; only adapter authoritative readback may supply them.
The foundation bridge imports the same nonce/ordinal/clock and captured temporary client/SP. The canonical
`reserve-foundation` handoff must already be consumed before workflow input is accepted; no hosted clock is started.
Bootstrap additionally requires `readiness` with actual `independentRecoveryReady`, `scopedKeyToolReady`,
`sshPublicKeyApproved`, and `dependencyResolved` evidence, all true, before authentication/clock/creation.
These booleans are evidence records, not authorization or availability proof.
The existing hosted authenticated cleanup backstop is retained and source-disabled.
Coordination with the external canonical writer and actual independent recovery capability still require review
and demonstrated availability before any paid start. Workstation-only recovery is **not approved** for execution.
A source-disabled local watcher, fixtures or flags cannot certify workstation/whole-workflow loss recovery.

Read-only inspection uses no credentials or provider writes (replace the external state paths):

```powershell
node spikes\vmss-flex\identity-cli.mjs inspect C:\spike-state\identity.json
node spikes\vmss-flex\identity-cli.mjs inspect-lock C:\spike-state\identity.json.lock
node spikes\vmss-flex\identity-cli.mjs inspect-lock C:\spike-state\identity.json.cleanup.lock
```

Execution blockers remain: an authorized durable CAS channel accessible from both hosts; an independent,
always-available recovery host/cancellation domain; authentication continuation after workstation AND whole-workflow
loss; Graph/GitHub authority for exact application/SP/FIC/environment cleanup; and actual ARM operation-handle,
terminal-readback and authoritative inventory rights. HTTP preparation and mock receipts prove none of these.
No recovery store, host, grant, identity, environment or key operation is introduced by #85.

### Original-envelope meter and usage reservations

Each full run durably reserves two guests, 8,589,934,592 NAT bytes, 4,294,967,296 outbound bytes,
4,294,967,296 PE ingress bytes and the same PE egress bytes. The maximum two-run aggregate is **four guests,
17.179869184 GB NAT, 8.589934592 GB outbound and 17.179869184 GB PE ingress plus egress** (decimal GB).
Per-run DNS reservation is conservative: two guests, each allowed the entire four hours at 2 queries/second
plus burst 20, yielding 57,640 queries/run, **115,280 combined**. This over-reserves duration rather than refunding
failed bootstrap traffic. No guest restart or quota reset is authorized.

`priceOriginalEnvelope` accepts only the closed schema documented in
[the cost-source record](pricing-sources.md): a retrieval timestamp no more than 24 hours old, Azure Retail Prices
API source, USD, `swedencentral`, and exact pinned rates for the VM, disk, NAT, IP, Private Link, bandwidth,
Private DNS, and Key Vault operation meters. A caller-supplied source timestamp is checked for format and age, but
the code does not fetch the pricing API; the approver must verify the source values. Changed prices fail closed
until the reviewed rate table is updated. It rejects missing/extra categories, stale evidence, or a planned
projection at or above $10. Premium P4 uses its monthly retail price divided by 672 hours (the shortest
calendar month); each of the three disks is priced through all four planned hours, including cleanup. Two zone
hosting charges are conservatively billed at a full monthly rate. The two-run traffic calculation includes both
directions of guest quota bytes, all allowed DNS bursts, and four secret-only Key Vault operations. No arbitrary
log, image, cleanup, or miscellaneous amount is added: those paid resource creates are forbidden by this contract.
The guest quota does not include networking before `guest-bootstrap.sh` installs its rules (for example, earlier
OS/cloud-init traffic); that exposure is not bounded by this projection or validated on an Azure guest boot.
Accordingly, the named `Assert-SpikePaidExecutionCostCoverage` preflight rejects paid execution before source,
CAS, key, or cloud checks; no caller-supplied completion flag can override it. `priceOriginalEnvelope` remains
available for offline planning, but passing its subtotal does not certify cost coverage.

The example is approximately $4.31 using public retail rates. It is a planning projection, not an account-specific
quote, actual invoice, or absolute Azure billing limit. Resource-hour charges cover the original four hours, with
cleanup beginning by the three-hour work deadline and the final hour reserved. If a provider refuses/delays cleanup,
surviving resources can continue accruing charges past the deadline; that liability has no finite upper bound in this
estimate. No source gate, identity/key permission, or execution readiness is changed by this calculation.
Every full run rechecks fresh evidence before creation. The highest prior projection is retained even if a later
quote is cheaper; no cost allowance refund.

The offline tests cover exact trust/Owner/env contracts, production-ID rejection, two full runs, cleanup prerequisite
and order, original clock, combined cost ceiling, each interrupted step, no retry, locks/restart reservations,
ambiguous create capture and confirmation gates, concurrent/stale-lock callers, lost delete acknowledgements and
late materialization without false full cleanup. They run in the existing `validate:spike-vmss` test selector.
Run `npm run validate` for the repository check. Live #10/smoke scope, approved SSH key, Marketplace guest baseline,
complete effective price evidence and independent recovery remain execution gates; this document resolves none
of them by assertion.

The owner rejects all external IP-echo services. NAT evidence must instead correlate ARM subnet/NIC readback
(`defaultOutboundAccess=false`, no VM/NIC public IP, approved NAT attachment) with successful worker GitHub
connection/job completion. Label this configuration-plus-completion observation, not byte-level source-IP
measurement. It is not proof of private PaaS connectivity. Worker ARM identity readback remains necessary;
IMDS denial or empty identity environment variables alone do not prove absence of managed identity.

The coordinator owns fresh spike-only SSH public-key readiness; never discover/reuse a private home key.
Runtime accepts only an explicitly approved public key, not a generated/private-key substitute. App-key safe
tooling and independent cleanup readiness remain prerequisites even with scoped key automation approved.
