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

On 2026-10-07, [run 37652530423](https://github.com/jonathan-vella/azure-gh-runners/actions/runs/37652530423)
and [run 37653350378](https://github.com/jonathan-vella/azure-gh-runners/actions/runs/37653350378) both stopped
at Azure login with `AADSTS700213`; no networking, agent-pool, or build steps ran. The presented GitHub Actions subject was
`repo:jonathan-vella@25802147/azure-gh-runners@1408821667:ref:refs/heads/main`, while the first setup helper
created a name-based subject. The repository OIDC customization readback reported immutable subjects enabled and
the matching ID-based prefix. Both temporary resource groups and Entra applications/service principals were
subsequently removed and absence verified. The setup helper now derives the prefix from GitHub repository metadata,
requires it to match the repository's OIDC customization readback, and appends only the observed `main` ref suffix.
This correction requires review and merge before another runtime attempt.

Microsoft Learn's [agent-pool documentation](https://learn.microsoft.com/en-us/azure/container-registry/tasks-agent-pools)
lists Sweden Central, S1 (2 vCPU/3 GB), S2 (4 vCPU/8 GB), and a default standard-pool quota of 16 vCPU per registry.
It requires HTTPS egress to external registries such as GHCR. This documented quota is per registry, not a
subscription-level quota.

## Decision

**Proposed; evidence recorded, decision not accepted.** The bounded GitHub-hosted experiment ran as
[workflow run 37658270199](https://github.com/jonathan-vella/azure-gh-runners/actions/runs/37658270199) on
`18bd21c48630d672026f68a88ef0158f01563397`. It created the isolated network, attempted both pool tiers, ran both
build contexts, and cleaned up. The pinned Git-context build succeeded as ACR task `dt1`; it used the digest-pinned GHCR
`actions-runner` base image, demonstrating that this task could pull that image. This is evidence for a
commit-pinned Git-context route, not for the local source-context route.

The local source-context command exited 1 without returning an ACR task run ID. Its underlying cause is unknown;
this does not establish that upload failed because of private networking. S1 reached `Succeeded`. S2 remained
`Creating` at the bounded check and its availability is unresolved. The experiment's public `/v2/` probe returned
HTTP 401, an authentication challenge that does not establish whether unauthenticated registry data access is
enabled or blocked. Accordingly, a successful source-context build or S2 provisioning is not a prerequisite to
considering the demonstrated Git-context alternative, but the outstanding failure cause and S2 availability mean
the issue's investigation is not complete and no path is accepted here.

Before testing, the workflow's successful scope assertion read back and checked the Azure subscription ID, tenant ID,
and name (`shared`); resource-group existence, location (`swedencentral`), required ownership tags, and absence of
a prior-run marker; and registry location, Premium SKU, `publicNetworkAccess=Disabled`, and
`adminUserEnabled=false`. These are the exact ARM properties verified by that assertion. The evidence does not
establish ACR private-endpoint/data-plane reachability or that the public endpoint rejects unauthenticated access.
Raw task logs were not retained or emitted, so no more specific cause can be stated for the local source-context
failure.

The workflow deleted and verified the exact spike resource group. Subsequent external cleanup verified the group,
temporary Entra app/service principal (including its federated credential), and scoped role assignments absent.

The workflow is merged to the default branch and its runtime evidence is recorded above. Its temporary app used one
federated credential with the exact `main` branch subject, no client password/certificate, and no production identity
or GitHub App secret. Its `Contributor` assignment was limited to the explicitly named, tagged spike resource group;
`AcrPush` and `Container Registry Tasks Contributor` were limited to that resource group's test registry.

## Consequences

- Keep issue #6 open. The Git-context path and GHCR pull have positive evidence, but the local source-context failure
  is undiagnosed, S2 readiness/quota is unresolved, and the public-probe result is inconclusive. No accepted build-path
  decision is made.
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
- The current GitHub Actions subject for this repository includes immutable owner and repository IDs. The setup
  helper derives `repo:<owner>@<owner-id>/<repository>@<repository-id>` from GitHub metadata and requires an exact
  match with the known owner and repository IDs and the repository's immutable OIDC subject configuration before
  creating the temporary app. Cleanup validates the same exact subject from its fixed allowlist without requiring
  GitHub API availability, so a GitHub outage cannot block removal of the temporary Azure identity. Setup appends
  only the observed `:ref:refs/heads/main` suffix; no environment or event suffix is inferred. See the
  [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc). The two prior AADSTS700213
  runs do not constitute evidence for any pool or build criterion.
- Do not represent the local source-context route, S2 availability, public endpoint behavior, or private-endpoint
  data-plane reachability as proven. Any later decision should weigh the demonstrated Git-context route against the
  issue's remaining questions and the documented GitHub-hosted build -> private GHCR -> `az acr import` fallback.

## Status

Proposed — experiment results are recorded, but investigation is incomplete and no build-path decision is accepted.
