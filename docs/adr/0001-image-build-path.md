# ADR-0001: Private ACR image-build path

## Context

Issue [#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6) asks whether a GitHub-hosted runner can queue
an `az acr build --agent-pool` task against a Premium registry with public network access disabled, and whether a
Git-context task avoids any local source-context upload limitation. It also requires validating GHCR base-image
egress and S1/S2 availability and quota before selecting the build path.

The spike resource group was absent before provisioning. In the approved `shared` subscription and `swedencentral`,
the isolated spike setup created a Premium ACR with admin access disabled and public network access disabled, an
approved private endpoint with `privatelink.azurecr.io` DNS records, and a dedicated agent-pool subnet. The subnet
had no inbound allows; outbound rules allowed the ACR private-endpoint subnet, the Azure services listed in the
agent-pool documentation, and Internet HTTPS for external image sources, while denying other VNet and Internet
traffic. Its only public IP was attached to the NAT Gateway for outbound connectivity.

Microsoft Learn's [agent-pool documentation](https://learn.microsoft.com/en-us/azure/container-registry/tasks-agent-pools)
lists Sweden Central as supported, S1 (2 vCPU/3 GB), S2 (4 vCPU/8 GB), and a default standard-pool quota of 16 vCPU
per registry. It says other public registries such as GHCR require corresponding outbound rules. The same page notes
that ACR Tasks runs may be paused for Azure free credits.

## Decision

**Blocked; no build-path decision is accepted.** The source-context and pinned Git-context builds were not run from a
GitHub-hosted runner, and no GHCR pull from an agent pool was observed. Therefore this ADR does not select ACR Tasks,
claim that Git context solves the private-registry path, or claim that the fallback has been tested.

The temporary test workflow could not be dispatched without first placing its workflow file on the repository's
default branch. [GitHub's workflow documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)
requires the workflow file to exist on the default branch for `workflow_dispatch`; the workflow was only on the spike
branch. Creating a pull request before the specified evidence exists would violate the spike's PR gate, so no PR was
opened and no local-operator build was substituted for a GitHub-hosted test.

The live Azure checks established that the S1 pool reached `Succeeded`. The S2 pool was still `Creating` when cleanup
began; its create command then returned a registry-not-found error during resource-group deletion. This cleanup
outcome does not establish S2 availability, and actual quota consumption was not verified. The documented 16-vCPU
standard quota is not a subscription-level quota and must not be represented as one.

## Consequences

- Keep issue #6 open and do not treat its acceptance criteria or this ADR as accepted.
- Do not implement dependent image-build work on the assumption that GitHub-hosted ACR Tasks works with public access
  disabled.
- The documented fallback—build on GitHub-hosted runners, push to private GHCR, then import into ACR by digest—remains
  a candidate, not a validated decision.
- Resume only when the required GitHub-hosted source-context and pinned-commit Git-context runs can be performed
  without bypassing branch protection or the PR gate. Record task run IDs, outcomes, and GHCR pull evidence then.

## Status

Blocked — investigation is incomplete and this ADR is not accepted. The temporary OIDC app, service principal, and
registry-scoped role grants were removed. The isolated spike resource group was deleted, and `az group exists` verified
that it is absent.
