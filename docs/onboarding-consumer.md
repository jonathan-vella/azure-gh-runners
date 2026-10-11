# Onboard a repository to the ACA backend

A deterministic checklist for an operator or coding agent. It onboards one GitHub repository to the Linux ACA backend
of this platform. Windows consumers use a different backend; see [Windows consumers](#windows-consumers). Do each step in
order, record the readback it asks for, and **stop and report** at any "Stop if" line instead of working around it.

Live-verified: the whole flow for `jonathan-vella/ghr-smoke` ([evidence](smoke.md)), including the consumer-owned
Entra identity and a private endpoint in the platform resource group. Not live-verified: private endpoints created in a
different resource group or subscription than the platform (step 6 lists the permissions that would be needed).

## Platform constraints

- Linux x64 only on this backend. No Docker-in-Docker and no Docker daemon; the runner container is unprivileged.
- Total replica size is one of the supported pairs from 0.25 vCPU / 0.5 GiB up to 4 vCPU / 8 GiB
  ([registry contract](consumer-registry.md#aca-cpu-and-memory)).
- Jobs reach only the platform and consumer private-endpoint subnets inside the VNet, plus the internet on port 443
  through one NAT address. There is no per-consumer network isolation: protect your data with Entra identity and RBAC.
- All registered repositories must be reachable by the one GitHub App installation (same account or organization).
- npm trusted publishing is not supported from self-hosted runners; publish from a GitHub-hosted runner.
- Public repositories may run only `workflow_dispatch`, `schedule` and `push` on the default branch. `pull_request`,
  `pull_request_target` and `workflow_run` are rejected for them. Private repositories may opt into `pull_request`;
  `pull_request_target` and `workflow_run` are never accepted.

## Inputs

| Name | Example | Notes |
| --- | --- | --- |
| `OWNER`, `REPO` | `octo`, `widgets` | The repository to onboard. |
| `NAME` | `widgets` | Lowercase kebab-case; becomes `config/consumers/<NAME>.json`, job `caj-ghr-<NAME>`, label `ghr-<NAME>`. |
| `ENVIRONMENT` | `azure` | GitHub Environment used for Azure OIDC; restricted to the default branch. |
| `WORKFLOW` | `ci.yml` | The consumer workflow file that will use the runner. |

Platform values used below: resource group `rg-ghrunners-prod-swc`, region `swedencentral`.

## Step 1. Install the GitHub App on the repository

1. Open the App installation settings (<https://github.com/settings/installations>, **Configure**), choose
   **Only select repositories**, and add `OWNER/REPO`. Never select **All repositories**
   ([runbook](runbooks/github-app.md#2-install-on-a-repository)).
2. Verify: the repository appears in the installation's selected repositories.

Stop if: the App is not installed on the owning account, or the installation would need access to all repositories.

## Step 2. Add the registry entry

1. Create `config/consumers/<NAME>.json` (fields in the [registry contract](consumer-registry.md)):

   ```json
   {
     "name": "<NAME>",
     "repo": "<OWNER>/<REPO>",
     "visibility": "public",
     "backend": "aca",
     "labels": ["ghr-<NAME>"],
     "cpu": 1,
     "memory": "2Gi",
     "maxExecutions": 1,
     "replicaTimeoutSeconds": 3600,
     "allowedEvents": ["workflow_dispatch"],
     "allowedRefs": ["refs/heads/<default-branch>"],
     "allowedWorkflows": ["<OWNER>/<REPO>/.github/workflows/<WORKFLOW>@refs/heads/<default-branch>"]
   }
   ```

   Set `visibility` to the repository's real visibility and the ref to its real default branch; the validator checks
   both against GitHub. Allow only the events the workflow needs; entries may narrow the policy floor, never widen it.
2. Generate and validate (needs `gh` authenticated with read access to the repository):

   ```bash
   npm ci
   npm run generate:consumers
   npm run validate
   ```

3. Open one pull request containing the new entry and the regenerated `infra/generated/consumers.json`, using the
   standard merge bar (validation plus one code review with no blocking findings).
4. After it merges, dispatch the platform deployment on `main`:

   ```bash
   gh workflow run deploy.yml --repo jonathan-vella/azure-gh-runners --ref main
   gh run watch --repo jonathan-vella/azure-gh-runners
   ```

5. Verify: the run is green, including **Verify no public endpoints**, and the job exists:

   ```bash
   az containerapp job show --resource-group rg-ghrunners-prod-swc --name caj-ghr-<NAME> \
     --query "{state:properties.provisioningState, labels:properties.configuration.eventTriggerConfig.scale.rules[0].metadata.labels}"
   ```

   Expect `Succeeded` and `ghr-<NAME>`.

Stop if: validation fails, the deploy run fails, or the job is missing. Do not add a job or parameter outside the
registry.

## Step 3. Consumer workflow

In the consumer repository, on the default branch (`.github/workflows/<WORKFLOW>`):

```yaml
name: ci
on: workflow_dispatch          # only events allowed by the registry entry
permissions:
  contents: read
jobs:
  build:
    runs-on: ghr-<NAME>          # exactly one label; never self-hosted or a label list (ADR-0005)
    environment: <ENVIRONMENT>   # needed for the OIDC subject below
    permissions:
      contents: read
      id-token: write            # only if the job logs in to Azure with OIDC
    steps:
      - uses: actions/checkout@<full commit SHA>
```

Pin every action by full commit SHA. Create the GitHub Environment and restrict it to the default branch:

```bash
gh api -X PUT repos/OWNER/REPO/environments/ENVIRONMENT \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/OWNER/REPO/environments/ENVIRONMENT/deployment-branch-policies -f name=<default-branch> -f type=branch
```

Verify: `gh api repos/OWNER/REPO/environments/ENVIRONMENT/deployment-branch-policies --jq '[.branch_policies[].name]'`
returns only the default branch.

## Step 4. Entra identity for the consumer

The consumer, not the platform, owns the identity that its jobs use to reach its own resources. There is no usable
managed identity inside the runner. Create the app in the Entra tenant that holds the target resources.

1. Read the exact subject prefix from GitHub; do not construct it by hand. Repositories use the immutable form
   `repo:<owner>@<owner-id>/<repo>@<repo-id>`:

   ```bash
   gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
   ```

   Expected shape: `repo:<owner>@<numeric id>/<repo>@<numeric id>`. If the response has `use_immutable_subject: false`,
   use the prefix the API returns anyway. The subject is `<prefix>:environment:<ENVIRONMENT>`.
2. Create the app, service principal and exact-subject federated credential:

   ```bash
   APP_ID=$(az ad app create --display-name "ghr-<NAME>-consumer" --query appId -o tsv)
   SP_OID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
   cat > fic.json <<EOF
   {
     "name": "github-<ENVIRONMENT>",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "<PREFIX>:environment:<ENVIRONMENT>",
     "audiences": ["api://AzureADTokenExchange"]
   }
   EOF
   az ad app federated-credential create --id "$APP_ID" --parameters @fic.json
   rm fic.json
   ```

3. Verify: `az ad app federated-credential list --id "$APP_ID" --query "[].subject"` returns exactly the one subject.
   Do not create secrets or certificates for the app, and do not use wildcard or branch-agnostic subjects.
4. Store `APP_ID` and the tenant ID as repository variables (they are identifiers, not secrets).

## Step 5. Resource access for the identity (role assignments)

The consumer creates role assignments for its own identity on its own resources, at the narrowest scope. Example for a
blob container reader:

```bash
az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" --scope "<storage account resource ID>"
```

The platform deployment identity cannot grant these (its delegation is limited to `AcrPull`, `AcrPush` and
`Key Vault Secrets User` on the platform resource group). An operator with sufficient rights on the consumer's
resources makes the assignment. Role assignments on resources that live in the platform resource group are lost if that
group is deleted and must be recreated ([operations](operations.md#recover-after-resource-group-deletion)).

## Step 6. Private endpoints in `snet-consumer-pe`

Consumer PaaS resources must have public network access disabled and be reached through a private endpoint in
`snet-consumer-pe` (`10.60.0.128/26`), registered in the platform private DNS zone for the service.

1. Read the platform values from the latest foundation or jobs deployment (output names are fixed by `infra/main.bicep`):

   ```bash
   RG=rg-ghrunners-prod-swc
   DEP=$(az deployment group list -g $RG \
     --query "sort_by([?starts_with(name,'platform-')],&properties.timestamp)[-1].name" -o tsv)
   az deployment group show -g $RG -n "$DEP" --query \
     "{subnet:properties.outputs.consumerPrivateEndpointSubnetResourceId.value, zones:properties.outputs.privateDnsZoneResourceIds.value}"
   ```

   `consumerPrivateEndpointSubnetResourceId` is the subnet ID. `privateDnsZoneResourceIds` is a list of
   `{name, resourceId}`; select the entry for your service:

   | Service (`groupIds`) | Zone name |
   | --- | --- |
   | `blob` | `privatelink.blob.core.windows.net` |
   | `file` | `privatelink.file.core.windows.net` |
   | `queue` | `privatelink.queue.core.windows.net` |
   | `table` | `privatelink.table.core.windows.net` |
   | `vault` | `privatelink.vaultcore.azure.net` |
   | `registry` | `privatelink.azurecr.io` |

   A service without a listed zone needs the zone added to `infra/network-config.json` through a platform pull request
   ([operations](operations.md#add-a-private-dns-zone)).
2. Create the endpoint and DNS zone group (blob example; the platform's own smoke storage account in `infra/main.bicep`
   is the in-repo reference):

   ```bicep
   param location string = 'swedencentral'
   param storageAccountId string
   param consumerPeSubnetId string    // output consumerPrivateEndpointSubnetResourceId
   param blobPrivateDnsZoneId string  // privateDnsZoneResourceIds entry for privatelink.blob.core.windows.net

   resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
     name: 'pe-st-<NAME>'
     location: location
     properties: {
       subnet: { id: consumerPeSubnetId }
       privateLinkServiceConnections: [
         {
           name: 'blob'
           properties: { privateLinkServiceId: storageAccountId, groupIds: [ 'blob' ] }
         }
       ]
     }
   }

   resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
     parent: pe
     name: 'default'
     properties: {
       privateDnsZoneConfigs: [
         { name: 'blob', properties: { privateDnsZoneId: blobPrivateDnsZoneId } }
       ]
     }
   }
   ```

3. Set the target resource's public network access to `Disabled`. Never enable it to work around a failure.
4. Permissions (not live-verified for resources outside the platform resource group): the principal creating the
   endpoint needs `Microsoft.Network/virtualNetworks/subnets/join/action` on `snet-consumer-pe` and permission to write
   records in the private DNS zone. Grant neither to consumer jobs.
5. Verify the endpoint is approved and DNS is private (from a job, or any host linked to the VNet):

   ```bash
   az network private-endpoint show -g <rg> -n pe-st-<NAME> \
     --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status" -o tsv   # Approved
   getent hosts <account>.blob.core.windows.net                                                   # 10.60.0.x
   ```

## Step 7. Fork-PR approval

Set the repository to require approval for all external contributors, even when the registry entry does not allow
`pull_request`:

```bash
gh api -X PUT repos/OWNER/REPO/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
gh api repos/OWNER/REPO/actions/permissions/fork-pr-contributor-approval --jq .approval_policy
```

The readback must print `all_external_contributors`. This is a consumer-side setting; the platform does not enforce it.

## Step 8. Verify end to end

1. Dispatch the consumer workflow: `gh workflow run <WORKFLOW> --repo OWNER/REPO --ref <default-branch>`.
2. Expect within about 2 minutes: an ACA execution starts and the job runs.

   ```bash
   az containerapp job execution list -g rg-ghrunners-prod-swc -n caj-ghr-<NAME> -o table
   ```

3. The run concludes `success`; its private-endpoint steps resolve `10.60.0.x`.
4. After the run: the execution is finished (scale back to zero) and no runner remains registered:

   ```bash
   gh api repos/OWNER/REPO/actions/runners --jq .total_count    # 0
   ```

5. Negative check (recommended): a `push` from a non-default branch or a `pull_request` targeting `ghr-<NAME>` must fail
   at the pre-job hook with `Consumer policy rejected job`; see [negative checks](smoke.md#negative-checks).

## Troubleshooting

| Symptom | Likely cause and action |
| --- | --- |
| Job stays queued | Label is not exactly `ghr-<NAME>`; `self-hosted` or a label list is used; the deploy has not run since the merge; the App is not installed on the repository. See [operations](operations.md#troubleshooting). |
| Job fails at "Set up job" with `Consumer policy rejected job` | The event, ref or workflow is outside the registry entry. Fix the workflow or, if the policy floor allows it, the entry. |
| OIDC login fails with an unmatched subject | The environment name or immutable prefix differs; re-read `sub_claim_prefix`. |
| Name resolves to a public address | No private endpoint or DNS zone group for that service in `snet-consumer-pe`. |
| `AuthorizationPermissionMismatch` | The identity lacks the data-plane role at that scope (step 5). |

## Windows consumers

Windows jobs use a separate isolated backend and a different registry shape; this guide does not apply. See
[ADR-0007](adr/0007-windows-vmss-isolated-runners.md) and `docs/windows-runners.md` (published with the
Windows backend).
