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
| `backend` | Optional explicit `aca` or `vmss`. Omission preserves legacy declarations and has no schema default. |
| `vmSku` | Required only for `backend: "vmss"`; initially allowlisted to `Standard_D2ls_v5`. |
| `maxRunners` | Required only for `backend: "vmss"`; integer from 1 through the platform cap of 2. |
| `jobTimeoutMinutes` | Required only for `backend: "vmss"`; integer from 1 through 360 minutes. |
| `labels` | Required, non-empty, unique custom runner labels. The registry validator requires `ghr-<name>`. |
| `cpu`, `memory` | Required for legacy and explicit ACA declarations: total ACA replica resources across all job containers, using one of the supported pairs below. Not valid for VMSS. |
| `maxExecutions` | Required for legacy and explicit ACA declarations: positive integer for maximum concurrent executions. Not valid for VMSS. |
| `replicaTimeoutSeconds` | Required for legacy and explicit ACA declarations: positive ACA job replica timeout in seconds. Not valid for VMSS. |
| `allowedEvents` | Required, non-empty list of `workflow_dispatch`, `schedule`, and `push`; private consumers may also opt into `pull_request`. `pull_request_target` and `workflow_run` are never accepted. |
| `allowedRefs` | Required, non-empty list of branch refs in `refs/heads/<branch>` form. Public declarations can list only one ref; the registry validator checks that it is the repository's actual default branch. For opted-in private PRs, this allowlists the PR base branch. |
| `allowedWorkflows` | Required, non-empty list in `<owner>/<repo>/.github/workflows/<file>@refs/heads/<branch>` form. Branch jobs match directly; private PRs authorize the workflow path against the PR base branch while validating the actual merge ref separately. |
| `notes` | Optional maintainer context; never include credentials or secrets. |

The schema rejects unknown fields. The registry validator in issue [#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17)
also checks cross-file uniqueness, the `ghr-<name>` label, and the remote default branch.
The schema cannot know a repository's current default branch by itself. Public consumers must be limited to
`workflow_dispatch`, `schedule`, and default-branch `push`; private consumers may opt into `pull_request` where policy
allows it. The runner pre-job hook remains responsible for enforcing the policy at runtime.

## Runner backend contract

The legacy [`example.json.sample`](../config/consumers/example.json.sample) remains valid without a `backend`.
[`example-aca.json.sample`](../config/consumers/example-aca.json.sample) and
[`example-vmss.json.sample`](../config/consumers/example-vmss.json.sample) show the explicit variants. VMSS-only
fields are rejected when `backend` is absent or set to `aca`; ACA sizing fields (`cpu`, `memory`, `maxExecutions`,
and `replicaTimeoutSeconds`) are required for legacy and explicit ACA declarations and rejected for `vmss`. All
three VMSS sizing fields are required for `vmss`. The schema intentionally has no default for `backend`: the primary
backend is unresolved pending the accepted backend ADR. Omitted-backend runtime and generator behavior remain gated
on that decision. The VMSS sample is a schema-preparation example only, not a deployable registry entry: the
registry validator and generator reject active VMSS consumers until runtime support lands. This change does not
alter active consumer declarations, generated parameters, or runtime behavior.

## Generated deployment parameters

Run `npm run generate:consumers` after changing a registry declaration. It first runs the same schema, cross-entry,
policy, and GitHub repository metadata validation as the registry validator, then atomically writes
[`infra/generated/consumers.json`](../infra/generated/consumers.json). `npm run validate` runs the generator's
`--check` mode, which fails if the artifact is missing or stale and never writes it.

The artifact is an ARM deployment parameters document with `parameters.consumers.value` as an array. Active VMSS
entries are rejected until backend runtime support is implemented, so generated entries currently use the legacy or
ACA shape. Consumers are sorted by `name`; `labels`, `allowedEvents`, `allowedRefs`, and `allowedWorkflows` are
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

The main runner container must receive the generated string unchanged as non-secret `CONSUMER_POLICY_JSON`.
For public consumers, the sole `allowedRefs` entry is the explicit, remotely verified default-branch contract; the
hook does not guess `main`, infer it from a PR payload, or call GitHub. Regenerate/review the declaration when a
repository changes visibility or default branch. Policy injection is administrator-controlled runner process
configuration, not consumer workflow/job `env`. Never let workflow code supply or override it.

Private `pull_request` is an explicit opt-in to **open, same-repository, non-fork merge-ref jobs only**. The runtime
hook validates the payload repositories, visibility, PR number, base/head branches, `GITHUB_BASE_REF`,
`GITHUB_HEAD_REF`, job merge ref, and workflow merge ref before mapping the workflow filename to its allowed base
branch entry. Closed PRs, head-ref jobs, forks (including private forks), malformed metadata, and branch-ref
fallbacks are rejected. This narrows rather than widens the platform floor.
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
