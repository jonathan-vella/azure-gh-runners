#!/usr/bin/env bash
set -euo pipefail

[[ $(id -un) == runner && $(id -u) == 1001 && $(id -g) == 1001 ]]
[[ ${ACTIONS_RUNNER_HOOK_JOB_STARTED:-} == /opt/ghr-vmss/pre-job-spike.sh ]]
[[ -n ${CONSUMER_POLICY_JSON:-} ]]
IFS= read -r jit
[[ ${#jit} -gt 0 && ${#jit} -le 131072 && $jit =~ ^[A-Za-z0-9+/]+={0,2}$ ]]
cd /home/runner
exec ./run.sh --jitconfig "$jit"
