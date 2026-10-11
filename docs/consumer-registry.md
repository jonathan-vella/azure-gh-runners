# Consumer registry contract

Each onboarded repository has one JSON declaration in `config/consumers/<name>.json`, validated against
[`config/schema/consumer.v1.json`](../config/schema/consumer.v1.json). The file
[`config/consumers/example.json.sample`](../config/consumers/example.json.sample) demonstrates the shape only; its
`.sample` suffix means it is not an active consumer declaration and is not deployed.

## Fields

| Field | Contract |
| --- | --- |
| `name` | Required lowercase kebab-case identifier. |
| `repo` | Required GitHub `owner/name`. |
| `visibility` | Required `public` or `private`. |
| `backend` | Optional: `aca` (default when omitted) or `vmss`, the isolated Windows backend. `vmss` is accepted only together with `os: "windows"`. |
| `os` | `windows`, required with `backend: "vmss"` and rejected for ACA. |
| `labels` | Required, non-empty, unique custom runner labels. The registry validator requires `ghr-<name>`. |
| `cpu`, `memory` | ACA only, required: total ACA replica resources across all job containers, using one of the supported pairs below. |
| `maxExecutions` | ACA only, required: positive integer for maximum concurrent executions. |
| `replicaTimeoutSeconds` | ACA only, required: positive ACA job replica timeout in seconds. |
| `vmSize` | `vmss` only, optional: `Standard_D2ds_v5`, `Standard_D4ds_v5` (default), `Standard_D8ds_v5` or `Standard_D16ds_v5`. |
| `maxRunners` | `vmss` only, required: maximum concurrent ephemeral Windows workers, 1 to 5. |
| `jobTimeoutMinutes` | `vmss` only, required: minutes after which the worker VM is deleted, 1 to 360. |
| `acknowledgePublicPullRequestRisk` | `vmss` only, public repositories only: `true` is required to list `pull_request` in `allowedEvents`, and is rejected when `pull_request` is absent. |
| `allowedEvents` | Required, non-empty list of `workflow_dispatch`, `schedule`, and `push`; private consumers may also opt into `pull_request`, and public `vmss` consumers may with `acknowledgePublicPullRequestRisk: true`. `pull_request_target` and `workflow_run` are never accepted. |
| `allowedRefs` | Required, non-empty list of branch refs in `refs/heads/<branch>` form. Public declarations can list only one ref; the registry validator checks that it is the repository's actual default branch. For opted-in private PRs, this allowlists the PR base branch. |
| `allowedWorkflows` | Required, non-empty list in `<owner>/<repo>/.github/workflows/<file>@refs/heads/<branch>` form. Branch jobs match directly; private PRs authorize the workflow path against the PR base branch while validating the actual merge ref separately. |
| `notes` | Optional maintainer context; never include credentials or secrets. |

The schema rejects unknown fields. The registry validator in issue [#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17)
also checks cross-file uniqueness, the `ghr-<name>` label, and the remote default branch.
The schema cannot know a repository's current default branch by itself. Public consumers must be limited to
`workflow_dispatch`, `schedule`, and default-branch `push`; private consumers may opt into `pull_request` where policy
allows it. The runner pre-job hook remains responsible for enforcing the policy at runtime.

## Runner backend

Every consumer runs on one of two backends. Omitting `backend` (or `backend: "aca"`) selects an Azure Container Apps
(ACA) job on Linux.
[`example.json.sample`](../config/consumers/example.json.sample) omits `backend`;
[`example-aca.json.sample`](../config/consumers/example-aca.json.sample) sets `backend: "aca"` explicitly. Both are
equivalent. VMSS Flex as a Linux backend stays deferred ([ADR-0006](adr/0006-vmss-flex-spike.md)).

`backend: "vmss"` selects the isolated Windows backend ([ADR-0007](adr/0007-windows-vmss-isolated-runners.md), issue
[#94](https://github.com/jonathan-vella/azure-gh-runners/issues/94)). It requires `os: "windows"`, uses its own sizing
fields (`vmSize`, `maxRunners`, `jobTimeoutMinutes`) and rejects every ACA field (`cpu`, `memory`, `maxExecutions`,
`replicaTimeoutSeconds`); ACA entries reject the Windows fields. See
[`config/consumers/smoke-windows.json`](../config/consumers/smoke-windows.json) for a complete entry. The label rule is
unchanged (`ghr-<name>`), so a repository that has both an ACA and a Windows entry needs two names and two labels; the
validator allows one entry per repository **per OS**.

For this backend only, a public consumer may list `pull_request` in `allowedEvents` when the entry sets
`acknowledgePublicPullRequestRisk: true` (owner decision of 2026-10-11, SR-9). The Windows pre-job hook then accepts
only an open, same-repository (non-fork) pull request with matching merge refs, an allowed base branch and an
allowlisted workflow; fork-PR approval for all outside collaborators must be enabled on the repository and verified
at acceptance. `pull_request_target` and `workflow_run` stay rejected for every backend, public refs still collapse to
the verified default branch, and ACA behavior and generated output are unchanged.

## Generated deployment parameters

Run `npm run generate:consumers` after changing a registry declaration. It first runs the same schema, cross-entry,
policy, and GitHub repository metadata validation as the registry validator, then atomically writes
[`infra/generated/consumers.json`](../infra/generated/consumers.json) (ACA entries only) and
[`infra/generated/windows-consumers.json`](../infra/generated/windows-consumers.json) (Windows entries only).
`npm run validate` runs the generator's `--check` mode, which fails if either artifact is missing or stale and never
writes them.

The artifact is an ARM deployment parameters document with `parameters.consumers.value` as an array. Consumers are sorted by `name`; `labels`, `allowedEvents`, `allowedRefs`, and `allowedWorkflows` are
sorted because their registry semantics are set-valued. Each generated consumer has this typed shape:

| Field | JSON type | Source |
| --- | --- | --- |
| `name` | string | Registry `name` |
| `repo` | string | Verified registry `repo` |
| `visibility` | `public` or `private` | Registry value verified against GitHub |
| `labels` | string array | Registry labels |
| `cpu` | number | Registry `cpu` |
| `memory` | string | Registry `memory` |
| `maxExecutions` | integer | Registry `maxExecutions` |
| `replicaTimeoutSeconds` | integer | Registry `replicaTimeoutSeconds` |
| `policyJson` | string containing a JSON object | Normalized runner-hook policy below |

`policyJson` contains exactly `repository` (string), `visibility` (string), `allowedEvents` (string array),
`allowedRefs` (string array), and `allowedWorkflows` (string array). It does not include GitHub metadata such as the
default branch because the hook policy uses the validated allowed-ref list. Optional maintainer-only `notes` are not
deployed. This parameter payload is the contract for future Bicep consumer-job work; the current `main.bicep` does not
consume it yet.

`windows-consumers.json` is a plain JSON array (not an ARM parameters document), sorted by `name`, for the Windows
orchestrator. Each object has exactly: `name`, `owner` and `repo` (the two halves of the registry `repo`), `label`
(`ghr-<name>`), `vmSize` (the registry value or the `Standard_D4ds_v5` default), `maxRunners`, `jobTimeoutMinutes`, and
`policy`. `policy` is a JSON **object** with exactly the same five fields and semantics as the Linux
`CONSUMER_POLICY_JSON`; the orchestrator hands it to the worker, where
[`start-runner.ps1`](../image/windows/start-runner.ps1) writes it to a file read by the
[Windows pre-job hook](../image/windows/hooks/job-started.ps1). The acknowledgement flag is not part of `policy`: the
registry validator enforces it, and the hook independently accepts only same-repository, non-fork pull requests.

The main runner container must receive the generated string unchanged as non-secret `CONSUMER_POLICY_JSON`.
For public consumers, the sole `allowedRefs` entry is the explicit, remotely verified default-branch contract; the
hook does not guess `main`, infer it from a PR payload, or call GitHub. Regenerate/review the declaration when a
repository changes visibility or default branch. Policy injection is administrator-controlled runner process
configuration, not consumer workflow/job `env`. Never let workflow code supply or override it.

Private `pull_request` is an explicit opt-in to **open, same-repository, non-fork merge-ref jobs only**. The runtime
hook validates the payload repositories, visibility, PR number, base/head branches, `GITHUB_BASE_REF`,
`GITHUB_HEAD_REF`, job merge ref, and workflow merge ref before mapping the workflow filename to its allowed base
branch entry. Closed PRs, head-ref jobs, forks (including private forks), malformed metadata, and branch-ref
fallbacks are rejected. This narrows rather than widens the platform floor. The Windows hook applies the identical
rule, including for acknowledged public Windows consumers, where the payload repositories must be public and not forks.
See [the image hook contract](../image/README.md#pre-job-policy-contract) for context provenance and execution limits.

## ACA CPU and memory

The schema allows the 16 Consumption workload-profile pairs for total resources across all containers, documented by
[Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/containers#vcpu-and-memory-allocation-requirements),
from 0.25 vCPU / 0.5 GiB through 4 vCPU / 8 GiB in 0.25 vCPU and 0.5 GiB increments. CPU and memory must be a
documented pair, not merely independent values inside those limits. The smaller Consumption-only environment is
limited to 2 vCPU / 4 GiB; the platform plan uses a workload-profiles environment.

`maxExecutions` and `replicaTimeoutSeconds` have a minimum of 1. Azure documents no schema-level maximum for these
job properties, so practical limits are set by the Azure environment/subscription and GitHub workflow requirements
rather than an arbitrary contract cap.

## Local checks

`npm run validate` includes schema validation tests using valid and invalid fixture JSON, including resource-pair,
resource-cap, and public-event boundaries. It does not validate the remote repository's visibility/default branch or
uniqueness across consumer declarations; those checks belong to issue #17.
