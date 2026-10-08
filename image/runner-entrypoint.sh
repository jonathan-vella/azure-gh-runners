#!/usr/bin/env bash
set -euo pipefail
umask 077

config_path=/jit/config
if [[ ! -s "$config_path" ]]; then
  echo "::error::JIT runner configuration is missing." >&2
  exit 1
fi

jit_config="$(<"$config_path")"
rm -f -- "$config_path"
unset GH_APP_PRIVATE_KEY GH_APP_ID GH_APP_INSTALLATION_ID

exec /home/runner/run.sh --jitconfig "$jit_config"
