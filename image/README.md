# Generic runner image

Issues [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19) and
[#20](https://github.com/jonathan-vella/azure-gh-runners/issues/20) supply the **linux/amd64 toolset and pre-job hook**.
The image is not yet a deployable platform runner. JIT initialization and the main
entrypoint belong to issues #21 and #22; identity isolation, labels, and the production build path still require
their spike decisions. Nothing here publishes an image, onboards a consumer, or deploys Azure resources.

## Pins and provenance

[`versions.json`](versions.json) is the installation and verification manifest, not a list of intended versions.
The official runner `2.338.0` multi-platform digest was read from GHCR with `docker buildx imagetools inspect`.
Its amd64 filesystem was inspected to establish the existing `runner` UID/GID (1001/1001), tool package versions,
and `/home/runner` layout. Git, jq, curl, and Python are inherited **by that immutable digest** and their exact
dpkg versions are checked during every build. No apt update or floating dependency resolution occurs.
The jq package is `1.7.1-3ubuntu0.24.04.2`, although its executable reports `jq-1.7`.

The additional tools use official, version-qualified binaries/packages with committed SHA-256 checksums. Every download
must pass the checksum check **before** extraction or execution; redirects must remain HTTPS. Azure CLI's Debian
package includes its own Python and dependencies, separate from the pinned system `python3`. `dpkg --install` checks
that its system-library dependencies are satisfied by the immutable base; it cannot fetch additional packages.
These first-party sources were checked on 2026-10-07:

| Tool | Version | Release and checksum source |
| --- | --- | --- |
| Azure CLI | 2.91.0 | [Official release](https://github.com/Azure/azure-cli/releases/tag/azure-cli-2.91.0), `2.91.0-1~noble` SHA256 in [Microsoft's package index](https://packages.microsoft.com/repos/azure-cli/dists/noble/main/binary-amd64/Packages.gz) |
| Bicep | 0.48.1 | [Latest stable release](https://github.com/Azure/bicep/releases/tag/v0.48.1), `bicep-linux-x64` asset digest in GitHub release metadata |
| Terraform | 1.16.5 | [Latest stable release](https://github.com/hashicorp/terraform/releases/tag/v1.16.5), [official SHA256SUMS](https://releases.hashicorp.com/terraform/1.16.5/terraform_1.16.5_SHA256SUMS) |
| Node LTS | 24.21.0 | [Official index](https://nodejs.org/dist/index.json), highest released LTS entry (Krypton), [SHASUMS256.txt](https://nodejs.org/dist/v24.21.0/SHASUMS256.txt) |
| PowerShell | 7.6.6 | [Official release](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6), `linux-x64` asset digest in GitHub release metadata |

Update pins through a reviewed PR: resolve the official release and checksum sources again, change the manifest,
and rebuild. Never use `latest`, an unverified installer, or override build arguments. A runner-base update also
requires re-inspecting UID/GID, package versions, library compatibility, and security defaults. The installation
script rejects non-amd64 bases; other architectures need separately verified archives and testing.

## Privilege and Docker

The final user is the upstream `runner`, not a newly created account. Its sudo and docker supplementary groups are
removed because the base grants passwordless sudo. The inherited `/usr/bin/dockerd` binary is removed; no daemon is
installed, started, or used. The upstream Docker client and other upstream utilities are preserved. Do not mount a
Docker socket or run this image privileged. Container builds/Docker-in-Docker are not supported.
The runner directory remains writable by `runner`; installed tools and the manifest are root-owned and not
runner-writable. Upstream `WORKDIR`, `CMD`, runner files, and embedded action Node runtimes remain unchanged.
The upstream image has no entrypoint and defaults to `/bin/bash`: this change deliberately does not add one.

## Pre-job policy contract

`ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh` is baked into the image. The root-owned,
non-runner-writable hook runs the inherited `/usr/bin/python3` in isolated mode with no new runtime dependencies.
It consumes non-secret `CONSUMER_POLICY_JSON` from the runner process environment, with exactly the five fields
emitted by the [registry generator](../docs/consumer-registry.md#generated-deployment-parameters). Missing/invalid
policy or context exits nonzero with a fixed, sanitized reason; policy, event contents, tokens, and raw untrusted
values are never logged. Python ignores user module paths, and branch validation uses the pinned `/usr/bin/git`.

Public jobs must use the sole, registry-verified default-branch ref for dispatch, schedule, or push. Private branch
jobs may use any explicitly allowed branch, but the workflow ref must equal the job ref. Repository comparisons are
case-insensitive; workflow paths and branch refs are exact. Workflow paths must be direct `.yml`/`.yaml` files under
the consumer's `.github/workflows`, not reusable-workflow repository or path substitutes.

Private PR jobs require explicit `pull_request` opt-in, an open same-repository non-fork payload, and matching
`refs/pull/<number>/merge` job **and workflow** refs. The base branch must be allowed and the workflow filename must
match an entry at that base branch. `GITHUB_BASE_REF`/`GITHUB_HEAD_REF` must match the payload. Closed PRs,
forks, missing metadata, mismatched numbers/visibility/repositories, head refs, and branch-ref fallbacks fail closed.
`pull_request_target` and `workflow_run` are forbidden regardless of visibility or supplied policy.

### Runner context and limits

[GitHub's hook documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts)
states that default variables and `GITHUB_EVENT_PATH` are available and that nonzero status fails the job before
user steps, with output in **Set up runner**. This implementation also checked the pinned runner `v2.338.0` source:
[JobHookProvider](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/JobHookProvider.cs) writes the event
payload and starts a script handler with an empty custom environment;
[ScriptHandler](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/Handlers/ScriptHandler.cs) exports
runtime context; [GitHubContext](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/GitHubContext.cs)
allowlists the required variables. The policy remains inherited administrator process configuration, not job `env`.
Missing variables are errors, not permission to reconstruct context from less trustworthy fields.

[JobExtension](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/JobExtension.cs) downloads/prepares
actions before the hook, but schedules the hook before action pre-steps and job/service container setup. This is a
before-user-execution policy gate, **not** a before-download gate. Policy JSON is limited to 64 KiB and PR payloads
to 1 MiB; regular-file/nonblocking payload checks prevent FIFO hangs, and each git ref check has a five-second timeout.
The hook performs no network requests. It does not itself prove ACA identity isolation, JIT/scaler behavior, or live
GitHub hook invocation. These still need authorized end-to-end smoke evidence.

## Local verification

From the repository root, with Linux Docker available:

```powershell
docker build --platform linux/amd64 --progress plain -f image\Dockerfile -t ghrunners-issue19:local .
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges --entrypoint bash ghrunners-issue19:local /opt/runner-image/verify-tools.sh
node tools\test-prejob.js ghrunners-issue19:local
Get-Content -Raw image\Dockerfile | docker run --rm -i hadolint/hadolint@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e
npm run validate
```

Bound local build execution to 20 minutes; individual downloads have a 180-second timeout and three retries.
The build itself runs the version/permission probe without networking, including `az bicep version` using the
installed Bicep rather than auto-downloading another binary. The separate container probe additionally drops
capabilities and disallows privilege escalation. Neither probe registers a runner or requires cloud credentials.
`npm run validate` includes offline image contract tests alongside all existing repository validators.
Those tests check committed pins and structure only: **they are not substitutes for Docker build, hadolint,
or executable version/permission probes**. If Docker is unavailable, report those checks as blocked and keep the PR
draft with **do not merge** until actual build evidence is available.

`npm run validate:hook` downloads Bats **1.14.0**, checks archive SHA-256
`bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177` before extraction, and runs the fixtures.
The release tag resolves to commit `eb7f42f8d608ac693d7a4b67474f6714ea68cfc5`. Bats lives in a temporary test directory,
not the production image. Linux runs natively; Windows uses the manifest's digest-pinned runner base with
network disabled and the source mounted read-only. Passing a local built-image tag as above instead exercises the
baked hook under the final non-root user, with capabilities dropped and privilege escalation disabled.
The fixtures include the exact generator output and allow/deny execution, fork payloads, malformed metadata,
sanitized logs, and a failed-hook fixture that prevents a following synthetic user step. The full validation command
includes these tests; it does not build/publish the production image or claim live GitHub/ACA proof.
