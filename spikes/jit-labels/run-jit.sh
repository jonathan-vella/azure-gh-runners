#!/usr/bin/env bash
set -euo pipefail
umask 077

metadata="$(cat /jit/runner-metadata.json)"
printf 'Starting disposable JIT runner: %s\n' "$metadata"

jit_config="$(cat /jit/encoded-jit-config)"
rm -f /jit/encoded-jit-config
unset GH_APP_PRIVATE_KEY GH_APP_ID GH_APP_INSTALLATION_ID

exec /home/runner/run.sh --jitconfig "$jit_config"
