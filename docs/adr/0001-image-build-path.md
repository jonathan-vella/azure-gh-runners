# ADR-0001: Private ACR image-build path

## Context

Issue [#6](https://github.com/jonathan-vella/azure-gh-runners/issues/6) asked how to build the runner image into a
Premium ACR with public network access disabled, originally by testing an ACR Tasks dedicated agent pool (preview).

A bounded experiment ([run 37658270199](https://github.com/jonathan-vella/azure-gh-runners/actions/runs/37658270199),
2026-10-07) reached S1 pool `Succeeded` and a successful commit-pinned Git-context build, but the local source-context
build failed for an unknown cause and S2 availability was unresolved. The spike resources were deleted and verified
absent. The agent-pool path stayed preview, partly unproven, and added a subnet, quota, and cleanup burden.

## Decision

Build the image on a GitHub-hosted runner, push it to a private GHCR package, then copy it by digest into the private
ACR with `az acr import`. ACR keeps public network access disabled and enables the trusted-services bypass so the
import can reach the registry. Deployments reference the ACR image by digest. The ACR Tasks agent pool is dropped from
v1; `snet-acr-agents` is not used by v1.

This is the chosen default; no live evidence of the import path is claimed here. The real `platform-prod` staged
deployment (image build → GHCR → foundation with `deployJobs=false` → `az acr import` → jobs with `deployJobs=true`)
and the `ghr-smoke` smoke test will prove it.

## Consequences

- No preview dependency or agent-pool quota; image builds use standard GitHub-hosted runners.
- GHCR credentials for the import are used only by the deployment workflow, never by runner jobs.
- If the import fails, the staged deployment stops before jobs are deployed.
- The spike harness (`tools/spike-acr-agentpool.ps1`, `.github/workflows/spike-acr-agentpool.yml`) is archival only.

## Status

Accepted (default, pending live smoke), 2026-10-08.
