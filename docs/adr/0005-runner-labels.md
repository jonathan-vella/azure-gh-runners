# ADR-0005: Runner labels and `runs-on` syntax

## Context

The platform's KEDA `github-runner` scaler is intended to use `noDefaultLabels: true`, while the runner is registered
through GitHub's repository JIT configuration endpoint. The issue #10 acceptance criteria require live evidence of
the labels GitHub registers, the matching `runs-on` form, and whether a job using only `self-hosted` wakes the pool.

GitHub documents the JIT endpoint's `labels` request field as custom labels to add and its response as containing both
the runner metadata (including labels) and `encoded_jit_config` ([REST API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-configuration-for-a-just-in-time-runner-for-a-repository)).
GitHub also documents that self-hosted runners automatically receive the `self-hosted` and OS/architecture labels
([label documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow#using-default-labels-to-route-jobs)).
The config is a sensitive bootstrap credential and must not be logged, persisted, or committed.

The latest stable KEDA release at authoring time is v2.21.0. Its
[GitHub runner scaler implementation](https://github.com/kedacore/keda/blob/v2.21.0/pkg/scalers/github_runner_scaler.go)
checks every queued job label against the configured labels and adds reserved defaults only when
`noDefaultLabels` is false. This matches the intended custom-label-only behavior, but does not establish which KEDA
version Azure Container Apps runs. The older
[KEDA issue #6127](https://github.com/kedacore/keda/issues/6127) reported the opposite behavior on v2.14.0.

The current repository does not yet contain the ACA runner job or a synthetic workflow in `ghr-smoke`, so live
scale-up behavior cannot be tested in this repository state.

## Decision

**Proposed, pending live verification.** Configure JIT with the consumer-specific label only (for example,
`ghr-smoke`) and configure KEDA with the same label and `noDefaultLabels: true`. Consumer jobs should request both
`self-hosted` and the consumer-specific label:

```yaml
runs-on: [self-hosted, ghr-smoke]
```

This form is expected to match the registered runner while ensuring the KEDA rule can key on the consumer-specific
label. A job requesting only `self-hosted` is expected not to match that custom-label-only rule.

The workflow `spike-jit-runner-labels.yml` is a bounded, manual probe for the protected `platform-prod` environment.
It may run only from `main`, requires that environment's reviewer approval, scopes its installation token to the
`ghr-smoke` repository and Administration: write, asks GitHub to add only a unique custom label, prints only returned
runner metadata and labels, and deletes/verifies removal of the temporary registration. It never reads, prints, or
stores `encoded_jit_config`.

## Consequences

- Do not treat the actual JIT label set, exact `runs-on` matching, or Azure Container Apps scaler behavior as proven
  until the probe and isolated scale test have completed and their run links/results are recorded here.
- The JIT label probe can establish the actual labels returned by GitHub, including whether `self-hosted` appears.
- The runner job and queue tests must verify that `[self-hosted, <consumer-label>]` starts the pool and that
  `self-hosted` alone does not. They require the isolated issue #10 test setup; no other spike resources or production
  resources may be reused or changed.
- The runner-registration cleanup is part of the probe's success condition.

## Status

Proposed; not accepted. The protected environment requires an authorized human reviewer, and this PR cannot access
its secrets. Live JIT and KEDA evidence remains outstanding.
