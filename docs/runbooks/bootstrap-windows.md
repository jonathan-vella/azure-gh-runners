# Bootstrap the Windows backend identity and resource group

Issues [#98](https://github.com/jonathan-vella/azure-gh-runners/issues/98) and
[#93](https://github.com/jonathan-vella/azure-gh-runners/issues/93); design in
[ADR-0007](../adr/0007-windows-vmss-isolated-runners.md). This is a one-time, owner-approved setup. The agent that
prepared it has **not** run it. Run it only after approval.

It creates the minimum needed for the protected `deploy-windows` workflow to deploy the isolated Windows backend:

- the resource group `rg-ghrunners-win-swc` with governance tags;
- the Entra app and service principal `sp-ghrunners-windows-deploy`, with **one** federated credential;
- **Owner on that resource group only**, so the deployment can create the orchestrator's role assignments;
- the GitHub environment variable `WINDOWS_AZURE_CLIENT_ID` on `platform-prod`.

It never touches the Linux platform identity `sp-ghrunners-platform-prod` or `rg-ghrunners-prod-swc`, and it never
creates a client secret, password or certificate.

## Why a separate identity

The Windows backend must be isolated from the Linux platform. A dedicated app scoped to its own resource group means a
compromise or mistake in the Windows deployment cannot reach the Linux platform, and the Linux deploy identity is not
widened. The federated credential uses the `platform-prod` **environment** subject, so only the `main`-only
`deploy-windows` workflow can sign in. The workflow reuses the existing `GH_APP_*` environment secrets and the
existing `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` secrets; only the client ID differs.

## Prerequisites

- PowerShell 7, Azure CLI and GitHub CLI, already signed in. The Azure account must be able to create Entra apps and
  create role assignments (Owner or User Access Administrator) on the subscription or the new resource group.
- The GitHub account must administer the repository environment and variables.
- The resource providers `Microsoft.App`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.ContainerRegistry`,
  `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity`, `Microsoft.Insights` and `Microsoft.Consumption` are
  registered. The script verifies this and stops; it does not change subscription-wide settings.
- The repository uses immutable-ID OIDC subjects and the default claim template, and the `platform-prod` environment
  allows only the `main` branch.

## What the script verifies first

The script stops on any unexpected state:

- the signed-in subscription and tenant equal the parameters you pass;
- the repository's OIDC customization API reports `use_default: true`, `use_immutable_subject: true`, and a
  `sub_claim_prefix` that equals `repo:<owner>@<owner-id>/<repo>@<repo-id>` computed from the repository's real IDs.
  The federated credential subject is `<sub_claim_prefix>:environment:platform-prod`; nothing is guessed;
- the `platform-prod` environment exists and has exactly one branch policy, `main`;
- no more than one Entra app has the display name, the app has no password or certificate credentials, it has at most
  one federated credential and that one matches the expected subject, issuer and audience;
- the service principal holds no role assignment except Owner at the resource group;
- an existing resource group is in the expected region.

## Dry run

`-WhatIf` performs only read-only checks and prints what it would change:

```powershell
./tools/bootstrap-windows.ps1 `
  -SubscriptionId <subscription-id> -TenantId <tenant-id> `
  -Owner <github-owner> -Repo <github-repo> -WhatIf
```

## Apply

Run after approval. Re-running is safe: existing matching resources are left alone.

```powershell
./tools/bootstrap-windows.ps1 `
  -SubscriptionId <subscription-id> -TenantId <tenant-id> `
  -Owner <github-owner> -Repo <github-repo> -Confirm:$false
```

Optional parameters: `-Location` (default `swedencentral`), `-ResourceGroupName` (default `rg-ghrunners-win-swc`),
`-EnvironmentName` (default `platform-prod`), `-AppDisplayName`, `-CredentialName`, `-CostCenter`.

## Verify

After the script finishes, confirm independently:

```powershell
az ad app federated-credential list --id <app-object-id> --query "[].{name:name,subject:subject,issuer:issuer,audiences:audiences}"
az role assignment list --assignee <service-principal-object-id> --all --query "[].{role:roleDefinitionName,scope:scope}"
gh variable list --repo <github-owner>/<github-repo> --env platform-prod
```

Expect exactly one credential, exactly one role assignment (Owner at the resource group scope), and the variable
`WINDOWS_AZURE_CLIENT_ID` equal to the app's client ID.

## Check the template before the first deployment (not run by the agent)

With the resource group in place, `validate` checks the template against Azure without creating anything:

```powershell
$env:GH_APP_PRIVATE_KEY = '<placeholder>'
az deployment group validate --resource-group rg-ghrunners-win-swc --parameters infra/windows/main.bicepparam
```

Use a throwaway placeholder for the key, never the real key. `what-if` is not used. Deploy only through the
`deploy-windows` workflow, never from a local checkout.

## Teardown

```powershell
# Remove the identity, its role assignment and the environment variable; keep the resource group.
./tools/bootstrap-windows.ps1 -SubscriptionId <subscription-id> -TenantId <tenant-id> -Owner <github-owner> -Repo <github-repo> -Teardown -Confirm:$false

# Also delete the resource group and everything in it (VMs, NAT, gallery, registry, jobs).
./tools/bootstrap-windows.ps1 -SubscriptionId <subscription-id> -TenantId <tenant-id> -Owner <github-owner> -Repo <github-repo> -Teardown -DeleteResourceGroup -Confirm:$false
```

Teardown refuses to delete a resource group that is not tagged `workload=gh-runners-windows` and stops if the service
principal has any assignment outside that resource group. Deleting the resource group stops all Windows billing.
