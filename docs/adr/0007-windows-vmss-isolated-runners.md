# ADR-0007: Windows runners on an isolated VMSS Flex backend; ACA stays the Linux backend

## Context

Azure Container Apps (ACA) only runs Linux (`linux/amd64`) container images, per
[Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/containers). The platform therefore cannot
run Windows jobs. The first real consumer, [`apex-vnext`](https://github.com/jonathan-vella/apex-vnext), has a
`windows-2025 package tests` job
([ci.yml](https://github.com/jonathan-vella/apex-vnext/blob/180ea0bfdf795e786a103cf7f0cfaa923d3817fc/.github/workflows/ci.yml),
[run 38139830680](https://github.com/jonathan-vella/apex-vnext/actions/runs/38139830680)) that takes about 46 minutes
on a GitHub-hosted runner. About 42 of those minutes are one step, `node --test` over the kernel, capabilities and CLI
packages; the Ubuntu `ci` job does more work in about 18 minutes.

That job needs **no private Azure access**: it has `contents: read` only and never signs in to Azure. It needs speed and
Windows, not the private-endpoint network.

[ADR-0006](0006-vmss-flex-spike.md) rejected a VMSS Flex backend for v1. That decision covered a **Linux** backend
inside the private-endpoint network, built after ACA capacity failures, with a strict four-hour/$10 envelope and
cross-host cleanup recovery. This ADR is a different design for a different need.

## Decision

Run **two backends** with a clear split:

| Backend | OS | Purpose | Network |
| --- | --- | --- | --- |
| **ACA jobs** | Linux | Private-endpoint platform runners (v1) | Internal VNet, private endpoints, private DNS |
| **VMSS Flex** | Windows | Isolated runners for speed and Windows-only jobs | Own VNet and resource group, **no link to the ACA platform** |

The Windows backend is built as an **isolated** runner:

- Ephemeral: one JIT runner per VM, one job, then the VM is deleted.
- No managed identity and no secrets on the worker. Only the controller holds the GitHub App credential.
- Own resource group and VNet, **not peered or linked** to the ACA platform; no private DNS link.
- NAT Gateway as the only public IP; outbound only.
- Pre-baked Windows Server 2025 image in an Azure Compute Gallery; nothing installed at boot.
- Dedicated deploy identity and GitHub environment for its resource group. `sp-ghrunners-platform-prod` stays scoped to
  `rg-ghrunners-prod-swc` and is not widened.
- A small budget cap and governance tags.

### Policy floor and the scoped exception

The consumer policy floor is unchanged for ACA: public repositories may run only `workflow_dispatch`, `schedule` and
`push` on the default branch; `pull_request`, `pull_request_target` and `workflow_run` are rejected.

**Owner decision, 2026-10-11:** for the **isolated Windows backend only**, a public consumer may opt into
`pull_request`, because `apex-vnext` runs its Windows tests on pull requests. This is allowed only when all of the
following hold:

1. The isolation controls above are in place (ephemeral, no identity, no secrets, no private network link).
2. The consumer entry sets an explicit acknowledgement flag; the schema rejects the exception for any other backend.
3. Fork-PR approval for **all outside collaborators** is enabled on the consumer repository and verified at acceptance.
4. `pull_request_target` and `workflow_run` stay rejected for every backend. Entries may only narrow the floor.
5. The Windows pre-job hook keeps the existing PR rule used for private consumers: only an open, same-repository
   (non-fork) pull request with matching merge refs, an allowed base branch and an allowlisted workflow is accepted.
   Fork PRs are therefore rejected technically, not only gated by approval. The owner may relax this later.
6. Both the registry validator and the Windows pre-job hook enforce the exception and fail closed.

This is a manual gate plus a technical block, not a guarantee: a PR from a compromised collaborator account runs its
code on the worker. Isolation limits the blast radius to compute abuse and egress in a throwaway resource group, which
the owner accepts for this lab.

## Consequences

- The Windows backend must be built: Windows image, PowerShell pre-job hook, scale-set controller, isolated
  infrastructure and deploy identity, registry support. Work is tracked in
  [#93](https://github.com/jonathan-vella/azure-gh-runners/issues/93) and issues #94–#99.
- The closed VMSS spike code ([`spikes/vmss-flex/`](https://github.com/jonathan-vella/azure-gh-runners/tree/25c0519b2a5cf9bf718091b18d0451b52af79aae/spikes/vmss-flex), removed from the tree) targeted Linux with bash bootstrap. The Go controller using
  `actions/scaleset` is expected to be reusable; the worker bootstrap and hook are not. It stays archival and unvalidated
  until a Windows design reuses specific parts.
- Windows workers cold-start for several minutes per job. That is negligible for a 40-minute job and poor for short ones.
- Cost evidence from the research doc (dated background): D4s_v5 Windows about $0.388 per hour pay-as-you-go. Actual
  cost must be measured at acceptance.
- Cleanup of VM, NIC, disk and runner registration must be exact-owned and verified; billing after failed deletion
  cannot be bounded absolutely.
- The cheap profiling experiment (#96) is optional and non-blocking: the owner chose to build the runner regardless.
  Its numbers become the baseline and target.

## Status

Accepted (direction), 2026-10-11. Implementation not started; the platform deployment is paused pending a full plan
review.
