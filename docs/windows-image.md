# Windows runner image and worker

The isolated Windows backend ([ADR-0007](adr/0007-windows-vmss-isolated-runners.md), tracker
[#93](https://github.com/jonathan-vella/azure-gh-runners/issues/93)) runs each job on one ephemeral Windows Server 2025
VM created from a pre-baked Azure Compute Gallery image. This page covers the **worker side**: the image, its build,
the boot-time startup script and the pre-job policy hook. The network, VM lifecycle and orchestrator are tracked
separately (#97, #98).

> **Status:** written and unit-tested offline only. Nothing here is live-verified until the
> [build workflow](../.github/workflows/build-windows-image.yml) has run against the Windows resource group and a
> runner job has completed on a worker built from the result (acceptance, #99).

## Files

| Path | Role |
| --- | --- |
| [`image/windows/versions.json`](../image/windows/versions.json) | Pinned base image, runner and tool versions with SHA-256 checksums |
| [`image/windows/install-tools.ps1`](../image/windows/install-tools.ps1) | Verifies each download's checksum, installs the tools and runner, installs the worker files, registers the boot task |
| [`image/windows/verify-tools.ps1`](../image/windows/verify-tools.ps1) | Checks every installed version against the manifest and the no-identity invariants |
| [`image/windows/start-runner.ps1`](../image/windows/start-runner.ps1) | Boot-time worker startup, installed as `C:\ghr\start-runner.ps1` |
| [`image/windows/hooks/job-started.ps1`](../image/windows/hooks/job-started.ps1) | Pre-job policy hook, installed as `C:\ghr\hooks\job-started.ps1` |
| [`.github/workflows/build-windows-image.yml`](../.github/workflows/build-windows-image.yml) | Manual image build, publish and test |

## Toolset

Windows Server 2025 Datacenter Azure Edition (Gen2) plus: GitHub Actions runner (win-x64), Node.js LTS, Git for Windows,
Python 3, PowerShell 7, Azure CLI, Bicep and Terraform, mirroring the Linux image where it makes sense. Versions are in
`versions.json`. The installer downloads over HTTPS only (redirects must stay HTTPS) and compares the SHA-256 **before**
extracting or executing anything; a mismatch fails the build. Checksums for the runner, Node, Git, PowerShell, Bicep and
Terraform come from the publishers' release metadata or checksum files. The Python and Azure CLI installers do not
publish a SHA-256 we could read, so those two values were computed from the official download on 2026-10-11 and pinned.

`az bicep` is pointed at the pinned `bicep.exe` through the machine variable `AZURE_BICEP_USE_BINARY_FROM_PATH`.
Docker is not installed; container jobs are not supported on this backend.

## Boot contract with the orchestrator

The orchestrator creates the VM with `customData`, which Windows writes to `C:\AzureData\CustomData.bin` as UTF-8 JSON:

```json
{"version":1,"jitConfig":"<base64 from generate-jitconfig>","policy":{"repository":"…","visibility":"…","allowedEvents":[…],"allowedRefs":[…],"allowedWorkflows":[…]},"expiresUtc":"2026-10-11T12:30:00Z"}
```

`policy` is the object emitted into [`windows-consumers.json`](../infra/generated/windows-consumers.json). A boot-time
scheduled task (`ghr-start-runner`, SYSTEM) runs `start-runner.ps1`, which:

1. Waits up to 15 minutes for the file (it may land just after boot), reads it, and **deletes it immediately**.
2. Refuses the config (and powers off) if it is malformed, has unexpected fields, an unsupported `version`, a
   `jitConfig` that is not plain base64, or an `expiresUtc` in the past.
3. Creates a local account `ghr-runner` in the `Users` group only (random password held in memory) and registers a
   one-shot task that runs as that account.
4. Writes the policy to `C:\ghr\policy.json` (readable, not writable, by `ghr-runner`) and the JIT config to
   `C:\ghr\work\jit.cfg` (readable and deletable by `ghr-runner` only), then starts the task.
5. As `ghr-runner`, the task reads and deletes the JIT config, sets `ACTIONS_RUNNER_HOOK_JOB_STARTED` to
   `C:\ghr\hooks\job-started.ps1`, and runs `C:\actions-runner\run.cmd --jitconfig <value>`. The JIT runner is
   ephemeral: it takes one job and exits.
6. Whatever the outcome, including any error, `shutdown /s /t 0` runs. A 390-minute local cap covers the 360-minute
   maximum job timeout; the orchestrator remains responsible for the per-consumer timeout and for deleting the VM.

The JIT config and policy are never logged; failures log only a fixed reason or the exception type to
`C:\ghr\logs\start-runner.log`. The script uses no Azure identity and never calls the instance metadata service. The VM
has no managed identity and no secrets. `C:\ghr` and the hook are writable only by SYSTEM and Administrators. Residual
exposure: the JIT config is visible on the `run.cmd` command line to the account that runs the job, which is the same
exposure as the Linux image; it is single-use and scoped to this one ephemeral runner.

## Pre-job hook

`job-started.ps1` is a PowerShell port of [`image/pre-job-policy.py`](../image/pre-job-policy.py) and fails closed. It
reads the policy file and checks, in order: policy shape (exactly five fields, no duplicate keys, bounded size),
event allowlist, repository, branch refs (`git check-ref-format`), workflow ref, and the job's ref and workflow against
the allowlist. `pull_request_target` and `workflow_run` are never in the allowed set, even if a policy lists them.

For `pull_request` the hook reads the event payload (`GITHUB_EVENT_PATH`) and accepts only an **open**,
**same-repository, non-fork** pull request whose job and workflow refs are `refs/pull/<number>/merge`, whose base
branch is allowlisted and whose workflow file is allowlisted for that base branch. Fork-ness comes from the payload,
never from `GITHUB_REF`. It also requires the payload repositories' `private` flag to match the policy's visibility,
which is what permits an acknowledged **public** Windows consumer (ADR-0007) while still rejecting forks. The runner
dot-sources `.ps1` hooks, so the hook has no "main" guard and reports through its exit code.

Offline tests: `tests/windows/job-started.tests.ps1` (hook, 28 cases including same-repo, fork, closed, merge-ref
mismatch, non-allowlisted workflow, missing or invalid payload, non-default push and `workflow_run`) and
`tests/windows/start-runner.tests.ps1` (config validation). Both run with plain `pwsh` through `npm run validate`.

## Building the image

Run **build-windows-image** manually (workflow dispatch). It uses the `platform-prod` environment, OIDC login with
`vars.WINDOWS_AZURE_CLIENT_ID` and `secrets.AZURE_TENANT_ID` / `secrets.AZURE_SUBSCRIPTION_ID`, and these inputs:

| Input | Default |
| --- | --- |
| `resource-group` | `rg-ghrunners-win-swc` |
| `gallery-name` | `gal_ghrunners_win_swc` |
| `image-definition` | `ghr-windows-2025` (created if missing: Windows, generalized, Gen2) |
| `location` | `swedencentral` |
| `build-subnet-id` | empty: resolved from the foundation deployment output (see below) |
| `vm-size` | `Standard_D4ds_v5` |

Prerequisites provided by the infrastructure work (#98): the resource group, gallery, and a build subnet (`snet-build` in the `vnet-ghrwin-<suffix>` VNet) with
outbound internet through the NAT gateway and no inbound path, and an identity allowed to create VMs, NICs, disks and
image versions in that resource group only.

If `build-subnet-id` is empty, the workflow reads the `buildSubnetResourceId` output of the `windows-foundation` deployment in the resource group (`az deployment group show`). It fails with a clear message if the output is missing or empty; pass the subnet resource ID explicitly in that case.

Steps: create a temporary private build VM (no public IP, no identity) from the marketplace image; run
`install-tools.ps1` and `verify-tools.ps1` through `az vm run-command`; remove the throwaway admin account; run
sysprep and `az vm generalize`; publish version `1.0.<run_number>` to the same region only (one replica); boot a
short-lived test VM from that version and run `verify-tools.ps1` again; then delete the build VM, test VM, NICs and
disks on **every** outcome. If the test fails, the unverified image version is deleted as well. Files are delivered to
the VM inside the run-command script, so the image content is exactly the checked-out commit.

`verify-tools.ps1` also asserts that no `ghr-runner` account, `CustomData.bin`, runner registration or Azure login is
present, and that only SYSTEM and Administrators can write `C:\ghr`. The build admin password is generated per run,
masked and discarded; the account is removed before sysprep, so no identity or secret is baked into the image.

## Patch cadence and updates

- **Rebuild monthly** (after Patch Tuesday) and after any security advisory for a baked tool. Each build starts from the
  latest marketplace Windows Server 2025 image, so a rebuild also takes the OS patches. Consumers use a pinned version
  chosen by the orchestrator, so a new version has no effect until it is selected.
- The runner is **pinned** in `versions.json`; workers are ephemeral, so nothing updates in place. A JIT runner that is
  too old may self-update on first connection; the VM is deleted after one job, so that update never persists. Raise the
  pin at least monthly, and always when GitHub announces a minimum runner version.
- To change a tool, edit `versions.json` through a reviewed PR: resolve the official release and checksum again, update
  the URL and SHA-256 together, run `npm run validate`, then rebuild. Never use `latest` or an unverified installer.
- Remove old gallery versions after the new one has been accepted; keep at least the previous one for rollback.

## First-run checks (not yet performed)

These cannot be proven offline, so the first live build and job must confirm them: the `ghr-runner` account can run a
scheduled task created from SYSTEM with a password (batch logon right: the live smoke showed Windows Server 2025 does not grant it, so boot now grants `SeBatchLogonRight` to that account only, and job-mode errors go to `C:\ghr\logs\job.log`); `az bicep version` uses the pinned binary; the
sysprep step shuts the VM down cleanly; and customData arrives at `C:\AzureData\CustomData.bin` before the 15-minute
wait ends. Treat any deviation as a defect in this change, not as an operational detail.
