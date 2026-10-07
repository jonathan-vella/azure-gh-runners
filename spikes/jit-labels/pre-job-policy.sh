#!/usr/bin/env bash
set -euo pipefail

readonly repository='jonathan-vella/ghr-smoke'
readonly branch='refs/heads/main'
readonly allowed_workflows=(
  'jonathan-vella/ghr-smoke/.github/workflows/jit-label-match.yml@refs/heads/main'
  'jonathan-vella/ghr-smoke/.github/workflows/jit-self-hosted-only.yml@refs/heads/main'
)

if [[ "${GITHUB_REPOSITORY:-}" != "$repository" ||
      "${GITHUB_EVENT_NAME:-}" != 'workflow_dispatch' ||
      "${GITHUB_REF:-}" != "$branch" ]]; then
  printf '%s\n' 'Denied: runner jobs are restricted to the approved issue 10 dispatch workflows on main.' >&2
  exit 1
fi

for workflow in "${allowed_workflows[@]}"; do
  if [[ "${GITHUB_WORKFLOW_REF:-}" == "$workflow" ]]; then
    exit 0
  fi
done

printf '%s\n' 'Denied: workflow ref is not an approved issue 10 test workflow.' >&2
exit 1
