# ADR-0001: Private ACR image-build path

## Context

Issue [#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6) asks whether a GitHub-hosted runner can queue
an `az acr build --agent-pool` task against a Premium registry with public network access disabled, whether a
Git-context task changes the result, whether the agent pool can pull the GHCR base image, and whether S1/S2 are
available in Sweden Central.

The first bounded Azure experiment verified that a Premium ACR can be created with public access and admin access
disabled and accessed from a VNet through an approved private endpoint. An S1 agent pool reached `Succeeded`.
The S2 pool was still `Creating` when cleanup began; its create command returned a registry-not-found error during
resource-group deletion. Neither build context nor the GHCR image pull was tested.

Microsoft Learn's [agent-pool documentation](https://learn.microsoft.com/en-us/azure/container-registry/tasks-agent-pools)
lists Sweden Central, S1 (2 vCPU/3 GB), S2 (4 vCPU/8 GB), and a default standard-pool quota of 16 vCPU per registry.
It requires HTTPS egress to external registries such as GHCR. This documented quota is per registry, not a
subscription-level quota.

## Decision

**Proposed experiment; build-path decision blocked.** This ADR remains unaccepted because no GitHub-hosted build or
agent-pool GHCR pull has been observed. The repository now contains a bounded manual workflow to test the local
source-context and exact checked-out Git commit against a private Premium ACR. A pinned, digest-qualified official
`actions-runner` base image provides the GHCR pull probe. The experiment scaffold does not claim that either test
passes.

The workflow must first be merged to the default branch before `workflow_dispatch` can run; the runtime evidence will
therefore follow review and merge of the scaffold, not precede it. The temporary app uses one federated credential
with the exact `main` branch subject, no client password/certificate, and no production identity or GitHub App
secret. Its `Contributor` assignment is limited to the explicitly named, tagged spike resource group; `AcrPush` and
`Container Registry Tasks Contributor` are limited to that resource group's test registry.

## Consequences

- Keep issue #6 open until source-context upload, Git-context, GHCR pull, S1/S2, and cleanup results are recorded.
- Before dispatch, run `tools/spike-acr-agentpool.ps1 -Action Setup` from an already-authenticated Azure CLI session
  in the approved `shared` subscription. It refuses to reuse an existing group or app and prints the non-secret
  client ID.
- After this workflow is merged to `main`, dispatch `.github/workflows/spike-acr-agentpool.yml` on `main` with all
  three required inputs: `client_id`, `resource_group` (`rg-ghrunners-spike6-swc`), and `registry_name`
  (`ghrunners6jv20261007`).
- The workflow serializes runs against the fixed spike resource group without canceling a resource-owning run. It
  claims the group with its workflow run ID and refuses a group carrying a prior run marker. It asserts subscription,
  tenant, region, ownership tags, Premium SKU, disabled public access, and disabled admin access before testing.
  It creates the VNet agent pool and ACR private endpoint, routes allowed outbound traffic through the NAT Gateway,
  denies inbound access and RFC1918 lateral/Internet egress except for explicitly allowed platform dependencies,
  bounds the pool/build/cleanup waits, and deletes/verifies the exact spike resource group in an `always()` cleanup
  step.
- The temporary Entra app cannot safely delete itself with these least-privilege role assignments. After every
  workflow outcome, including timeout or failure, run this exact external cleanup command from the operator session:
  `tools/spike-acr-agentpool.ps1 -Action Cleanup -ClientId <client-id>`. This command deletes and verifies the exact
  tagged resource group if it remains, removes the temporary service principal and app, and asserts all are absent.
  If Azure login never succeeds, the same cleanup command remains available. Setup prints the command with the
  actual client ID.
- Task logs are captured only in the ephemeral GitHub-hosted runner's temporary directory, reduced to the exit code,
  run ID, and fixed diagnostic classification, then deleted. They are not printed or uploaded as artifacts.
- Do not choose ACR Tasks or the documented fallback until the GH-hosted run URLs, ACR task run IDs/statuses,
  public-endpoint probe, pool states, and cleanup assertions have been reviewed and added here.

## Status

Proposed — experiment scaffold only; results are incomplete and no build-path decision is accepted.
