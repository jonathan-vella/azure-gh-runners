# Adopting this platform

A step-by-step guide for running your own copy of the platform from a fork. Read the [README](../README.md) first for
what it is, its security model, and what is and is not live-verified. The platform deploys real Azure resources (about
USD 110 per month fixed), so read [Cost](../README.md#cost) too.

> The maintainer's own identifiers (subscription, tenant, App and client IDs, owner IDs) appear only in evidence and
> history documents: `docs/adr/*`, `docs/research-*`, and `docs/smoke.md`. They are not configuration. Never copy
> them into your deployment.

## 0. Prerequisites

- An Azure subscription where you can create resource groups, Entra applications, and role assignments (Owner, or
  Contributor plus User Access Administrator, on the subscription, and permission to create Entra apps).
- A GitHub account or organisation, a fork of this repository (public or private), and the repositories you will run
  jobs for. The platform targets personal-account repositories; organisation use is untested.
- Local tools: Node.js/npm, Azure CLI with Bicep, GitHub CLI, PowerShell 7 (the runbooks use it).
- Quota in `swedencentral` for Azure Container Apps, ACR Premium, NAT Gateway, and Key Vault.

## 1. Fork and verify locally

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>
npm ci
npm run validate
```

`npm run validate` needs no Azure login. It must pass before you change anything.

## 2. Values to replace

| Value | Where it lives | Notes |
| --- | --- | --- |
| Subscription ID, tenant ID | GitHub environment secrets `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID` (step 5); `$subscription`/`$tenant` in the identity runbook | Never committed to the repository. |
| Resource group | `resourceGroup` in `infra/network-config.json`; optional repository variable `RESOURCE_GROUP` (defaults to `rg-ghrunners-prod-swc`) | Keep the two in sync. |
| Region | `location` in `infra/network-config.json` | v1 supports only `swedencentral`: the validator and the Bicep `@allowed` lists enforce it, and resource names carry an `swc` suffix. Another region means editing `tools/validate-network.js`, `infra/modules/network.bicep`, `infra/modules/observability.bicep`, and the names yourself; it is untested. |
| Address space and subnets | `addressSpace` and `subnets` in `infra/network-config.json` | Defaults are `10.60.0.0/22`; change only to avoid overlap with your networks. `npm run validate:network` checks the ranges. |
| Governance tags | `governanceTags` in `infra/network-config.json` | Replace owner, cost centre, and contacts. Keys are required, values are free text. |
| GitHub owner and repo | `repo` and workflow refs in `config/consumers/*.json`; `@jonathan-vella` in `.github/CODEOWNERS`; repository links in `SECURITY.md` and `CODE_OF_CONDUCT.md` | Image paths in `deploy.yml` come from `github.repository`. |
| GitHub App ID, installation ID, key | Environment secrets `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY` (step 4) | Never committed. |
| Deploy client ID | Environment secret `AZURE_CLIENT_ID` | Created in step 3. |
| Naming | Resource names are CAF-style (`*-ghrunners-prod-swc-<suffix>`) with a hash suffix from the subscription and resource group | Fixed in Bicep; change deliberately and consistently if you must. |

The registered smoke-test consumer `config/consumers/smoke.json` belongs to the maintainer. Delete it in your fork,
then run `npm run generate:consumers`. An empty registry deploys the foundation with no jobs.

## 3. Create the Azure identities

Follow [bootstrap-identity.md](runbooks/bootstrap-identity.md). It creates the resource group, the deploy identity
with a federated credential trusted only by the `platform-prod` environment and the constrained RBAC delegation. You
create the `platform-prod` GitHub environment yourself, restricted to `main`; the runbook verifies it and sets
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` as environment secrets.

## 4. Create the GitHub App

Follow [github-app.md](runbooks/github-app.md). It creates a private App with Administration read/write, Actions
read, and Metadata read, installs it on selected repositories only, and stores `GH_APP_ID`,
`GH_APP_INSTALLATION_ID`, and `GH_APP_PRIVATE_KEY` as `platform-prod` environment secrets. Handle the private key as
your highest-value secret.

## 5. Checklist of environment secrets and variables

| Name | Kind | Scope | Set by |
| --- | --- | --- | --- |
| `AZURE_CLIENT_ID` | secret | `platform-prod` environment | identity runbook |
| `AZURE_TENANT_ID` | secret | `platform-prod` environment | identity runbook |
| `AZURE_SUBSCRIPTION_ID` | secret | `platform-prod` environment | identity runbook |
| `GH_APP_ID` | secret | `platform-prod` environment | GitHub App runbook |
| `GH_APP_INSTALLATION_ID` | secret | `platform-prod` environment | GitHub App runbook |
| `GH_APP_PRIVATE_KEY` | secret | `platform-prod` environment | GitHub App runbook |
| `RESOURCE_GROUP` | variable (optional) | repository | you, only if you changed the resource group |

Also enable branch protection on `main` and require the `validate` workflow. Settings are yours to configure; nothing
in this repository changes them for you.

## 6. Deploy

Merge your configuration changes to `main`, then run the **Deploy platform** workflow
(`.github/workflows/deploy.yml`, `workflow_dispatch` on `main`). It runs in stages:

1. Builds the runner and init images on a GitHub-hosted runner and pushes them to GHCR by digest.
2. Deploys the foundation (network, Log Analytics, Key Vault, ACR, internal ACA environment) with `deployJobs=false`
   and reads back the network posture.
3. Imports the images into ACR by digest.
4. Deploys one ACA job per registry entry with `deployJobs=true`.

Use the `foundation_only` input for a first run to stop after the foundation readbacks. Never deploy from a local
checkout. The run summary prints the NAT egress IP (the only public IP, outbound-only) and the smoke storage account
name.

The optional network diagnostic settings stay off until you check the live categories with
`AZURE_SUBSCRIPTION_ID=<subscription-id> node tools/validate-diagnostics.mjs --live deployment-outputs.json`; see
[observability.md](observability.md).

## 7. Onboard the first consumer

1. Install the GitHub App on the consumer repository (**Only select repositories**), per the App runbook.
2. Add `config/consumers/<name>.json` (copy `config/consumers/example.json.sample`). Public repositories may allow
   only `workflow_dispatch`, `schedule`, and default-branch `push`; see
   [consumer-registry.md](consumer-registry.md). The runner label is `ghr-<name>`.
3. Run `npm run generate:consumers` and `npm run validate`, commit, open a pull request, and merge it.
4. Run **Deploy platform** again so the new job exists.
5. In the consumer repository use `runs-on: ghr-<name>`. If the job must reach your private Azure resources, create a
   consumer-owned federated identity and a private endpoint in the shared consumer subnet; [smoke.md](smoke.md) shows
   the pattern end to end with a blob container.

## 8. Teardown

1. Optional: delete the consumer registry entries and redeploy, to deregister cleanly before removing everything.
2. Delete the resource group: `az group delete --name <resource-group>`.
3. Key Vault purge protection is off, so a soft-deleted vault can be purged
   (`az keyvault purge --name <vault> --location <region>`) if you plan to redeploy into the same group.
4. Delete the deploy and what-if Entra applications (and their federated credentials) and any consumer-owned apps.
5. Uninstall the GitHub App and delete its private key, then delete the App.
6. Delete the `platform-prod` environment and the secrets above, and the GHCR packages created by the deploy workflow.

## What is verified

The Linux ACA path has been deployed and smoke-tested in the maintainer's subscription (evidence in
[smoke.md](smoke.md)). Nothing here has been validated in another tenant, so expect to fix issues the first time, and
please report them. The Windows backend ([ADR-0007](adr/0007-windows-vmss-isolated-runners.md)) is not built yet and has
no adoption steps.
