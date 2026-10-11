# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Shared Azure platform for ephemeral, private-network GitHub Actions runners: Linux jobs on Azure Container Apps,
  registry-driven consumer onboarding (`config/consumers/`), hardened runner image with a fail-closed pre-job policy
  hook, and the staged, protected `platform-prod` deployment workflow.
- Documentation: [architecture](docs/architecture.md), [consumer onboarding](docs/onboarding-consumer.md),
  [operations](docs/operations.md) and a security model finalised against live evidence
  ([security](docs/security.md)).
- Automated post-deploy public-access check (`tools/check-public-access.mjs`), run as the last step of the deploy job
  and against fixtures in `npm run validate`.
- Negative smoke coverage specification (non-default-branch `push`, `pull_request`, identity-token refusal) in
  [smoke](docs/smoke.md#negative-checks).

### Changed

- ACA managed environment is deployed with `zoneRedundant: false` (AVM default is `true`).

### Deferred

- Scheduled maintenance workflow ([#28](https://github.com/jonathan-vella/azure-gh-runners/issues/28)): a scheduled
  deploy would run unattended on a no-reviewer environment.

## v1.0.0 release criteria

Tag `v1.0.0` only when every box is checked. Windows runners (milestone M7) do not gate v1.0.

- [x] ACA platform deployed through the staged `platform-prod` workflow with ADR-0001 to ADR-0005 live-verified for
  function (2026-10-11).
- [x] `ghr-smoke` positive smoke passes on the real ACA runner: private DNS, Entra OIDC login, container listed over the
  private endpoint, scale 0 to 1 to 0 ([smoke](docs/smoke.md)).
- [x] No usable managed-identity token inside the runner (HTTP 400, one run).
- [x] Architecture, onboarding, operations and security documentation written.
- [ ] Negative smoke checks run and recorded: non-default-branch `push` and `pull_request` rejected by the hook.
- [ ] Post-deploy public-access check green on a live deploy run.
- [ ] `AGENTS.md` links the new documentation; README, LICENSE, SECURITY and CONTRIBUTING in place (owned by the
  release-hygiene work).
- [ ] Open dependency audit findings assessed ([security](docs/security.md)).
- [ ] Release notes written from this file and `v1.0.0` tagged.
