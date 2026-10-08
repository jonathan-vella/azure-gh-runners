# ADR-0005: Runner labels and `runs-on` syntax

## Context

The platform's KEDA `github-runner` scaler is intended to use `noDefaultLabels: true`, while the runner is registered
through GitHub's repository JIT configuration endpoint. Issue #10 asked for evidence of the labels GitHub registers,
the matching `runs-on` form, and whether a job using only `self-hosted` wakes the pool.

GitHub documents the JIT endpoint's `labels` request field as custom labels to add and its response as containing both
runner metadata (including labels) and `encoded_jit_config` ([REST API](https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-configuration-for-a-just-in-time-runner-for-a-repository)).
GitHub also documents that self-hosted runners automatically receive the `self-hosted` and OS/architecture labels
([label documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow#using-default-labels-to-route-jobs)).
The config is a sensitive bootstrap credential and must not be logged, persisted, or committed.

The latest stable KEDA release at authoring time is v2.21.0. Its
[GitHub runner scaler implementation](https://github.com/kedacore/keda/blob/v2.21.0/pkg/scalers/github_runner_scaler.go)
checks every queued-job label against the configured labels and adds reserved defaults only when `noDefaultLabels` is
false. This is implementation evidence, not proof of the KEDA version or runtime behavior in Azure Container Apps.
KEDA issue [#6127](https://github.com/kedacore/keda/issues/6127) reported the opposite behavior on v2.14.0.

## Decision

Use the consumer's custom label only. The registry requires `ghr-<name>`; the init container passes that label to the
JIT endpoint, and the KEDA rule uses the same label with `noDefaultLabels: true`. Consumers write a single label:

```yaml
runs-on: ghr-<name>
```

GitHub's label routing matches a job's requested labels against runner labels; `self-hosted` is a default runner label,
not a required token in `runs-on`. With `noDefaultLabels`, KEDA v2.21.0 requires every job label to be in the
configured set, so a custom-label-only job is expected to match the runner and wake the scaler, and a job requesting
only `self-hosted` (or `[self-hosted, ghr-<name>]`) is not expected to wake it.

This is the chosen default; no live evidence is claimed. The real `platform-prod` deployment and the `ghr-smoke` smoke
test will prove it. If the deployed KEDA version behaves differently, update this ADR and the onboarding guidance.

## Consequences

- Consumer documentation and examples use `runs-on: ghr-<name>` only.
- The JIT API's required `runner_group_id` uses the default group `1`; the smoke test confirms it for the personal
  account.
- No further spike runs. The archival harness under `spikes/jit-labels/` and its workflows are not part of validation.

## Status

Accepted (default, pending live smoke), 2026-10-08.
