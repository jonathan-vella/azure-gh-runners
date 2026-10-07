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
| `labels` | Required, non-empty, unique custom runner labels. The registry validator requires `ghr-<name>`. |
| `cpu`, `memory` | Required total ACA replica resources across all job containers, using one of the supported pairs below. |
| `maxExecutions` | Required positive integer for maximum concurrent executions. Effective scale is subject to Azure quotas; the schema does not invent a concurrency cap. |
| `replicaTimeoutSeconds` | Required positive integer. The ACA job API does not document a service maximum for this setting, so the schema does not impose an arbitrary upper bound. |
| `allowedEvents` | Required, non-empty list of `workflow_dispatch`, `schedule`, and `push`; private consumers may also opt into `pull_request`. `pull_request_target` and `workflow_run` are never accepted. |
| `allowedRefs` | Required, non-empty list of branch refs in `refs/heads/<branch>` form. Public declarations can list only one ref; the registry validator checks that it is the repository's actual default branch. |
| `allowedWorkflows` | Required, non-empty list of `GITHUB_WORKFLOW_REF` values in `<owner>/<repo>/.github/workflows/<file>@refs/heads/<branch>` form. |
| `notes` | Optional maintainer context; never include credentials or secrets. |

The schema rejects unknown fields. The registry validator in issue [#17](https://github.com/jonathan-vella/azure-gh-runners/issues/17)
will also check cross-file uniqueness, the `ghr-<name>` label, and the remote default branch.
The schema cannot know a repository's current default branch by itself. Public consumers must be limited to
`workflow_dispatch`, `schedule`, and default-branch `push`; private consumers may opt into `pull_request` where policy
allows it. The runner pre-job hook remains responsible for enforcing the policy at runtime.

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
