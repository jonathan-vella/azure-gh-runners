# Contributing

Thanks for helping. This project is a shared Azure platform for ephemeral, private-network GitHub Actions runners.
Security invariants matter more than features, so read [AGENTS.md](AGENTS.md) (it applies to humans too) before
changing anything in `infra/`, `image/`, `config/`, or `.github/`.

## Setup

Requirements: Node.js and npm, Azure CLI with Bicep. The hook tests also need Bash, git, jq, and curl on Linux, or
Linux Docker on Windows. Registered consumers need GitHub CLI access (see [README](README.md#local-validation)).

```bash
npm ci
npm run validate
```

`npm run validate` is the single local check and the same command CI runs. It must pass before you open a pull
request. It never deploys anything and needs no Azure login. Do not deploy from a local checkout; production
deployment belongs to the protected `platform-prod` workflow in the maintainer's repository.

## Pull requests

- One change per pull request, and one issue per branch. Reference the issue (for example `Closes #3`).
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `chore:`).
- Update directly related documentation.
- Pin GitHub Actions by full commit SHA and container images by digest; Bicep uses Azure Verified Modules at exact
  versions.
- Never commit secrets, keys, tokens, or personal data. Use placeholders in docs and examples.
- Merge bar: CI build plus `npm run validate` pass and a review finds no blocking issues.

DCO sign-off is not required. By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).

## Changing the policy floor

The consumer policy floor (allowed events and refs for public repositories, the ban on `pull_request_target` and
`workflow_run`, and the runner-secret isolation rules) is never relaxed silently. A proposal that loosens it needs:

1. An issue describing the use case and the threat analysis.
2. An explicit maintainer decision recorded in an ADR under `docs/adr/`.
3. Matching changes in both registry validation and the pre-job hook, with tests.

Changes that only tighten the floor are welcome as ordinary pull requests.

## AI-agent contributions

Contributions written with AI agents are welcome and held to the same bar. Point your agent at
[AGENTS.md](AGENTS.md), and make sure a human has read the diff and run `npm run validate`.

## Onboarding or removing a consumer

Only through `config/consumers/<name>.json`, validated by the registry tooling; see
[docs/consumer-registry.md](docs/consumer-registry.md). Run `npm run generate:consumers` afterwards.

## Reporting problems

Use the issue forms for bugs and feature requests. Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md). Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
