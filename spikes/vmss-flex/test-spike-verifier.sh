#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]]
verify() {
  runuser --user runner -- env -i HOME=/home/runner \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ghr-vmss/pre-job-spike.sh \
    AZURE_CORE_COLLECT_TELEMETRY=false AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no \
    AZURE_BICEP_USE_BINARY_FROM_PATH=true /bin/bash /opt/ghr-vmss/verify-spike-worker.sh
}
reject() {
  if verify >/dev/null 2>&1; then
    echo 'Unsafe spike verifier fixture was accepted.' >&2
    exit 1
  fi
}
verify
file=/opt/ghr-vmss/pre-job-spike.sh
chmod 0777 "$file"
reject
chmod 0555 "$file"
chown runner:runner "$file"
reject
chown root:root "$file"
mv "$file" "$file.disabled"
reject
mv "$file.disabled" "$file"
delegate=/opt/runner-image/pre-job-policy.py
chmod 0755 "$delegate"
reject
chmod 0555 "$delegate"
if runuser --user runner -- env ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh \
  /bin/bash /opt/ghr-vmss/verify-spike-worker.sh >/dev/null 2>&1; then
  echo 'Verifier accepted a substituted hook environment.' >&2
  exit 1
fi
verify
