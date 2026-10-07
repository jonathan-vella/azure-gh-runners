#!/bin/bash
set -euo pipefail

manifest=/opt/runner-image/versions.json

equal() {
  if [[ $2 != "$3" ]]; then
    printf '%s: expected %s, got %s\n' "$1" "$2" "$3" >&2
    exit 1
  fi
  printf '%s: %s\n' "$1" "$3"
}

equal user runner "$(id -un)"
equal uid "$(jq -r '.base.runnerUid' "$manifest")" "$(id -u)"
equal gid "$(jq -r '.base.runnerGid' "$manifest")" "$(id -g)"
[[ $(id -u) != 0 ]]
if sudo -n true 2>/dev/null; then
  echo 'runner must not have passwordless sudo' >&2
  exit 1
fi
if command -v dockerd || [[ -S /var/run/docker.sock ]]; then
  echo 'Docker daemon or socket must not be available' >&2
  exit 1
fi
[[ ! -w /opt/runner-image/versions.json && ! -w /usr/local/bin ]]
[[ -x /home/runner/run.sh && -x /home/runner/config.sh ]]
equal runner "$(jq -r '.base.version' "$manifest")" "$(ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=0 /home/runner/bin/Runner.Listener --version)"

while IFS=$'\t' read -r package version; do
  equal "$package package" "$version" "$(dpkg-query -W -f='${Version}' "$package")"
done < <(jq -r '.inherited[] | [.package, .packageVersion] | @tsv' "$manifest")

equal git "$(jq -r '.inherited.git.version' "$manifest")" "$(git --version | cut -d ' ' -f 3)"
equal jq "$(jq -r '.inherited.jq.version' "$manifest")" "$(jq --version | cut -d - -f 2)"
equal curl "$(jq -r '.inherited.curl.version' "$manifest")" "$(curl --version | sed -n '1s/^curl \([^ ]*\).*/\1/p')"
equal python "$(jq -r '.inherited.python.version' "$manifest")" "$(python3 --version | cut -d ' ' -f 2)"
equal 'azure-cli package' "$(jq -r '.downloads.azureCli.packageVersion' "$manifest")" "$(dpkg-query -W -f='${Version}' azure-cli)"
equal azureCli "$(jq -r '.downloads.azureCli.version' "$manifest")" "$(az version --output json | jq -er '."azure-cli"')"
equal bicep "$(jq -r '.downloads.bicep.version' "$manifest")" "$(bicep --version | cut -d ' ' -f 4)"
equal azureCliBicep "$(jq -r '.downloads.bicep.version' "$manifest")" "$(az bicep version | cut -d ' ' -f 4)"
equal terraform "$(jq -r '.downloads.terraform.version' "$manifest")" "$(terraform version -json | jq -er '.terraform_version')"
equal node "$(jq -r '.downloads.node.version' "$manifest")" "$(node --version | cut -c 2-)"
equal pwsh "$(jq -r '.downloads.pwsh.version' "$manifest")" "$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
