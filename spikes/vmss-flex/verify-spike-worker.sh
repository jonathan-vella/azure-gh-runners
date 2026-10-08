#!/usr/bin/env bash
set -euo pipefail

manifest=/opt/runner-image/versions.json
[[ $(id -un) == runner && $(id -u) == 1001 && $(id -g) == 1001 ]]
[[ $(id -G) == '1001 100' ]]
[[ ${ACTIONS_RUNNER_HOOK_JOB_STARTED:-} == /opt/ghr-vmss/pre-job-spike.sh ]]
[[ -z ${IDENTITY_ENDPOINT:-}${IDENTITY_HEADER:-}${MSI_ENDPOINT:-}${MSI_SECRET:-} ]]
for file in /opt/ghr-vmss/verify-spike-worker.sh /opt/ghr-vmss/pre-job-spike.sh \
  /opt/ghr-vmss/pre-job-spike.py /opt/runner-image/pre-job-policy.sh /opt/runner-image/pre-job-policy.py; do
  [[ -f $file && ! -L $file && -x $file && ! -w $file ]]
  [[ $(stat -c '%u:%g:%a' "$file") == '0:0:555' ]]
done
[[ $(stat -c '%u:%g:%a' "$manifest") == '0:0:444' && ! -w $manifest ]]
for directory in /opt /opt/ghr-vmss /opt/runner-image /usr/local/bin; do
  [[ ! -w $directory && $(stat -c %u "$directory") == 0 ]]
done
if command -v sudo >/dev/null || command -v dockerd >/dev/null || command -v docker >/dev/null ||
  [[ -S /var/run/docker.sock ]]; then
  echo 'Spike worker exposes a forbidden privilege tool or Docker socket.' >&2
  exit 1
fi
privileged=$(find /usr /bin /sbin /opt -xdev -type f \( -perm -4000 -o -perm -2000 \) -executable -print -quit)
[[ -z $privileged ]]
[[ -x /home/runner/run.sh && -x /home/runner/config.sh ]]

equal() {
  [[ $1 == "$2" ]] || { echo 'Spike manifest tool version mismatch.' >&2; exit 1; }
}
equal "$(jq -r '.base.version' "$manifest")" "$(ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=0 /home/runner/bin/Runner.Listener --version)"
while IFS=$'\t' read -r package version; do
  equal "$version" "$(dpkg-query -W -f='${Version}' "$package")"
done < <(jq -r '.inherited[] | [.package, .packageVersion] | @tsv' "$manifest")
equal "$(jq -r '.inherited.git.version' "$manifest")" "$(git --version | cut -d ' ' -f 3)"
equal "$(jq -r '.inherited.jq.version' "$manifest")" "$(jq --version | cut -d - -f 2)"
equal "$(jq -r '.inherited.curl.version' "$manifest")" "$(curl --version | sed -n '1s/^curl \([^ ]*\).*/\1/p')"
equal "$(jq -r '.inherited.python.version' "$manifest")" "$(python3 --version | cut -d ' ' -f 2)"
equal "$(jq -r '.downloads.azureCli.packageVersion' "$manifest")" "$(dpkg-query -W -f='${Version}' azure-cli)"
equal "$(jq -r '.downloads.azureCli.version' "$manifest")" "$(az version --output json | jq -er '."azure-cli"')"
equal "$(jq -r '.downloads.bicep.version' "$manifest")" "$(bicep --version | cut -d ' ' -f 4)"
equal "$(jq -r '.downloads.bicep.version' "$manifest")" "$(az bicep version | cut -d ' ' -f 4)"
equal "$(jq -r '.downloads.terraform.version' "$manifest")" "$(terraform version -json | jq -er '.terraform_version')"
equal "$(jq -r '.downloads.node.version' "$manifest")" "$(node --version | cut -c 2-)"
equal "$(jq -r '.downloads.pwsh.version' "$manifest")" "$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
printf '%s\n' 'Actual spike wrapper, immutable delegate and nonprivileged manifest toolset verified.'
