# ADR-0005: Runner labels and `runs-on` syntax

## Context

The platform's KEDA `github-runner` scaler is intended to use `noDefaultLabels: true`, while the runner is registered
through GitHub's repository JIT configuration endpoint. Issue #10 requires evidence of the labels GitHub registers,
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

The isolated diagnostic job, two trusted `workflow_dispatch` templates, and a fail-closed job-start hook are prepared
under `spikes/jit-labels/`. The hook allows only those two workflows, from `jonathan-vella/ghr-smoke`, with
`workflow_dispatch` on `refs/heads/main`. The templates are not deployed or installed in `ghr-smoke` by this PR.

## Decision

**Proposed, pending live verification.** Configure JIT with the consumer-specific label only (for example,
`ghr-smoke-jit-label-spike`) and configure KEDA with that same label and `noDefaultLabels: true`. The matching
synthetic job should request the custom label only:

```yaml
runs-on: ghr-smoke-jit-label-spike
```

GitHub's label routing matches a job's requested labels against runner labels; `self-hosted` is a default runner label,
not a required token in the `runs-on` expression. KEDA v2.21.0's `noDefaultLabels` option omits reserved labels from
the configured scaler labels. Its current matching implementation requires every job label to exist in that
configured set. Consequently a custom-only job label is expected to both match the runner and wake the scaler, while a
job requesting only `self-hosted` is expected not to match the custom-only scaler rule.

The protected workflows include an OIDC-claims diagnostic that prints only allowlisted claims (never the JWT) and
`spike-jit-labels-deploy.yml`, which deploys only the `caj-ghr-spike10-jit-labels` diagnostic job to
the dedicated `rg-ghrunners-spike10-swc` group. It is manual, main-only, requires explicit capacity confirmation and
approval of `platform-prod`, uses a temporary identity with only scoped Contributor/Managed Identity Operator grants,
and validates the approved subscription, region/API availability, internal/public-disabled environment, delegated
subnet/NSG/NAT, private registry/Key Vault, and digest-pinned images. The job has a run-ID ownership tag and a bounded
observation window with guarded cleanup. The user-assigned identity is lifecycle `None` for job containers; the App
key is resolved from Key Vault into the init container only. The two smoke workflow templates are trusted manual jobs
with no secrets or third-party actions.

The JIT API requires `runner_group_id`; the scaffold supplies `1`, which GitHub's repository endpoint example shows
as the default group. Acceptance of that group ID for the personal-account `ghr-smoke` repository remains to be
confirmed by the live, authorized API request. Repository OIDC customization metadata was read back as
`use_default: true`, `use_immutable_subject: true`, with prefix
`repo:jonathan-vella@25802147/azure-gh-runners@1408821667`. The isolated identity FIC therefore uses the standard
environment suffix `:environment:platform-prod`; the operator script verifies the live template and reads the FIC
back before granting roles. Do not alter the existing production FIC as part of issue #10.

## Consequences

- Do not treat the actual JIT label set, exact `runs-on` matching, or ACA scaler behavior as proven until the isolated
  observer completes and its workflow/execution URLs and label observations are recorded here.
- The observer records labels from the registered JIT runner while the matching workflow is active, confirms that the
  matching job creates exactly one successful ACA execution, and checks automatic ephemeral-runner deregistration.
- The observer then requires the `self-hosted`-only workflow to remain queued for two minutes with no new ACA execution
  and cancels the queued run. Any unexpected test runner left registered is removed by its captured ID and reported as
  a failed auto-cleanup assertion.
- The runner job and queue tests must verify that `runs-on: <consumer-label>` starts the pool and `self-hosted` alone
  does not. They require the isolated issue #10 setup; no other spike resources or production resources may be reused
  or changed.
- The pinned image is GitHub's `actions-runner` v2.338.0 image digest verified on 2026-10-07. Re-check the latest
  stable runner release before changing the pin.

## Status

Proposed; not accepted. The protected environment requires an authorized human reviewer, the isolated ACA environment
failed to provision in `swedencentral` because of regional capacity, and no live JIT/scaler test has run. Do not
deploy, switch region, or relax network controls while that blocker remains.
