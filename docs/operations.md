# Operations

How to run the platform after the initial build. Everything here targets `rg-ghrunners-prod-swc` in `swedencentral`.
Production changes go only through the protected `platform-prod` workflow on `main`; never deploy from a local checkout.

Status labels: **live** means the step was performed against the real deployment; **untested** means it follows from
the design but has not been run.

## Deploy

Merge to `main`, then dispatch **Deploy platform** (`.github/workflows/deploy.yml`):

```bash
gh workflow run deploy.yml --repo jonathan-vella/azure-gh-runners --ref main
gh run watch --repo jonathan-vella/azure-gh-runners
```

Stages: image build to private GHCR, foundation (`deployJobs=false`), read-back assertions, `az acr import` by digest,
jobs (`deployJobs=true`), public-access check. The `platform-prod` environment is restricted to `main` and has no
required reviewer, so a dispatch deploys immediately. Runs are serialized by the `platform-prod` concurrency group.
The input `foundation_only` deploys and verifies only the foundation. (live)

The job summary prints the NAT egress IP, ACR login server, the smoke storage account name and the ACA job names.

## Rebuild images

Every deploy rebuilds both images from `image/Dockerfile` (tagged with the commit SHA), pushes them to GHCR, imports
them into ACR by digest and rolls the jobs to those digests, so the way to pick up base-image or tool updates is a
reviewed change to `image/` followed by a deploy. Scheduled rebuilds are deferred (see [#28](https://github.com/jonathan-vella/azure-gh-runners/issues/28)
in the [backlog](backlog.md)).

## GitHub App key rotation

Follow [the GitHub App runbook](runbooks/github-app.md#3-rotate-the-private-key). The key flows from the environment
secret into Key Vault by a deploy, so rotation is complete only after a deploy and a successful job start. If jobs stop
scaling after a rotation, see [troubleshooting](#troubleshooting). (the runbook procedure is untested end to end)

## Public access check

`tools/check-public-access.mjs` asserts that storage accounts, Key Vaults, container registries and the ACA
environment have public network access disabled (the environment also internal), that the Log Analytics workspace has
local authentication disabled (its documented exception), and that every public IP is attached only to the NAT gateway.
It runs read-only `az` queries (`az resource list` and `az resource show`) and exits non-zero on violation.

```bash
node tools/check-public-access.mjs --resource-group rg-ghrunners-prod-swc   # live, needs az login
node tools/check-public-access.mjs --input inventory.json                  # offline fixture
```

It runs as the last step of the deploy job and in `npm run validate` against fixtures. A resource type it does not
review produces a warning, not a failure: when a new resource type is added to the platform, extend the rules in the
tool in the same pull request.

## Recover after resource-group deletion

This exact sequence was done live on 2026-10-11 after the group was deleted to clear a failed environment. It needs
owner rights and deliberately repeats the bootstrap constraints: stop on any unexpected state.

1. Recreate the resource group with the same name, region and governance tags
   ([bootstrap runbook](runbooks/bootstrap-identity.md)).
2. Restore exactly the deploy identity's two documented roles at the group scope, `Contributor` and the constrained
   `Role Based Access Control Administrator`, using the condition recorded in that runbook. Add nothing else.
3. Purge the soft-deleted Key Vault, otherwise the deterministic vault name collides (purge protection is off):

   ```bash
   az keyvault list-deleted --subscription <subscription> --query "[].{name:name,location:properties.location}" -o table
   az keyvault purge --name <vault name from the list> --location swedencentral
   ```

4. Dispatch the deploy with `foundation_only` enabled and confirm the readbacks pass; this proves the foundation before
   images and jobs are involved.
5. Dispatch the deploy again without `foundation_only` to import images and deploy the jobs.
6. Recreate the consumer role assignments that lived on resources in the deleted group. For the smoke test that is
   `Storage Blob Data Reader` for the `ghr-smoke-consumer` service principal on the smoke storage account. Entra apps,
   service principals and federated credentials are tenant objects and survive. Resource names are deterministic for
   the same group, so repository variables such as `SMOKE_STORAGE_ACCOUNT` normally still match; confirm them from
   the run summary.
7. Run the [smoke workflow](smoke.md) and confirm the public-access check was green.

## The AVM `zoneRedundant` trap

The Azure Verified Module `avm/res/app/managed-environment` at `0.16.0` defaults `zoneRedundant` to `true`. In
`swedencentral` that made environment creation fail with `AKSCapacityHeavyUsage` / `ManagedEnvironmentCapacityHeavyUsageError`.
`infra/main.bicep` therefore sets `zoneRedundant: false` explicitly ([#92](https://github.com/jonathan-vella/azure-gh-runners/pull/92)).
Do not remove it or bump the module without checking the new default.

## Add a private DNS zone

Consumers whose service has no zone in the platform list need one. Add it to `privateDnsZones` in
`infra/network-config.json` (validated by `npm run validate:network`), merge, and deploy. The zone is created and
linked to the VNet by `infra/modules/network.bicep`. (untested for a new zone)

## Offboard a consumer

1. Remove `config/consumers/<name>.json`, run `npm run generate:consumers`, and open a pull request.
2. Deploys are incremental, so a removed entry does not delete its job: after the merge-and-deploy, delete
   `caj-ghr-<name>` explicitly (`az containerapp job delete`), through an approved operator session. (untested)
3. Remove the repository from the GitHub App installation, delete the consumer's Entra app and role assignments, and
   delete its private endpoints.

## Logs

The ACA environment sends `ContainerAppSystemLogs` and `ContainerAppConsoleLogs` to `law-ghrunners-prod-swc` through a
diagnostic setting. Local authentication is disabled, so query with Entra credentials (`workspaceCustomerId` is a
deployment output):

```bash
az monitor log-analytics query --workspace <workspaceCustomerId> --analytics-query \
  "ContainerAppSystemLogs | where TimeGenerated > ago(1h) | order by TimeGenerated desc | take 100"
az monitor log-analytics query --workspace <workspaceCustomerId> --analytics-query \
  "ContainerAppConsoleLogs | where TimeGenerated > ago(1h) | where ContainerName has 'jit-init' or ContainerName has 'runner' | order by TimeGenerated desc | take 100"
```

The diagnostic setting does not select a resource-specific table; if these tables are empty, run
`AzureDiagnostics | where Category startswith "ContainerApp"` instead (the table was not confirmed live). Job
console logs never contain the App key or the JIT configuration; if one ever does, treat it as an incident and
rotate the key. Execution state is also visible with `az containerapp job execution list`.

## Troubleshooting

| Symptom | Checks |
| --- | --- |
| Job queued, no execution starts | Workflow `runs-on` is exactly `ghr-<name>` ([ADR-0005](adr/0005-runner-labels.md)); repository is installed on the App; the entry deployed (`az containerapp job show`); `maxExecutions` not already reached; System logs show the `github-runner` scale rule error (bad App ID, installation ID or key). KEDA polls every 15 seconds. |
| Scaling stopped after key rotation | The deploy that writes the new key to Key Vault did not run or failed; the old key was deleted in App settings first. Re-run the deploy; verify with a job start. |
| Execution starts but job fails at **Set up job** with `Consumer policy rejected job: <reason>` | The pre-job hook rejected the event, ref, workflow or repository. Compare the reason (for example `event outside policy`, `job ref outside policy`, `workflow outside policy`) with the registry entry. This is intended for disallowed triggers; see [negative checks](smoke.md#negative-checks). |
| JIT failure: init container exits non-zero, no runner registers | `jit-init` console logs. Common causes: App not installed on the repository, App lacks Administration write, wrong installation ID, key mismatch. |
| Name resolves to a public address or fails | Missing private endpoint or DNS zone group; zone not linked to the VNet; check `az network private-dns record-set a list` for the name. The deploy readback checks ACR, Key Vault and smoke storage records. |
| Image import fails in the deploy | `az acr import` runs from the GitHub-hosted job over the ACR trusted-services bypass ([ADR-0001](adr/0001-image-build-path.md)); check the GHCR package is readable with the workflow token, the digest matches, and the bypass is `AzureServices`. The deploy stops before jobs are touched. |
| ACR pull fails when an execution starts | The job references an image digest that was not imported, or the identity lacks `AcrPull` on the registry. |
| Job deployment fails resolving the Key Vault secret | Identity lacks `Key Vault Secrets User`; Key Vault private endpoint or DNS record missing; secret `github-app-private-key` absent. Never enable Key Vault public access; use the ARM secure-secret fallback in [ADR-0002](adr/0002-key-vault-secret-references.md) if the reference cannot work. |
| Environment creation fails with `AKSCapacityHeavyUsage` | See [the zoneRedundant trap](#the-avm-zoneredundant-trap). |
| Public-access check fails | Read the `::error::` lines; fix the resource in Bicep, never by hand. Do not enable public access to unblock anything. |

## Scaling limits

- Concurrency per consumer is `maxExecutions` in its registry entry; each execution runs one job (`parallelism: 1`).
- Replica size is the entry's `cpu`/`memory` total (init container takes 0.25 vCPU / 0.5 GiB); the largest pair is 4 vCPU / 8 GiB.
- `replicaTimeoutSeconds` bounds a job; the platform has no retries (`replicaRetryLimit: 0`).
- The environment uses the Consumption workload profile; regional quota and the `/27` infrastructure subnet bound the
  total. Capacity limits beyond these have not been measured.

## Cost

The fixed baseline is about USD 110 per month (network, private endpoints, ACR Premium),
per [PRD](prd.md) NFR-4; this is an estimate, not a measured bill. ACA execution cost is zero while idle and
proportional to job runtime. No budget alert is deployed by this repository; set one on the resource group in the
Azure portal or through an approved change.

## Teardown

Deleting `rg-ghrunners-prod-swc` removes the platform but needs owner action and breaks things outside it: role
assignments on resources in the group are lost, the Key Vault is soft-deleted and must be purged to reuse its name,
and tenant objects (Entra apps, federated credentials) and GitHub settings (App installation, secrets, environments)
remain. Remove those separately if the platform is retired. Do not tear down as part of ordinary repository work.
