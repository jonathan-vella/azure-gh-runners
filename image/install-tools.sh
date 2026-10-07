#!/bin/bash
set -euo pipefail

manifest=/opt/runner-image/versions.json
[[ $(dpkg --print-architecture) == amd64 ]]
[[ $(id -u runner) == "$(jq -r '.base.runnerUid' "$manifest")" ]]
[[ $(id -g runner) == "$(jq -r '.base.runnerGid' "$manifest")" ]]
[[ $(id -u) == 0 ]]

download() {
  local tool=$1 destination=$2 url checksum
  url=$(jq -er --arg tool "$tool" '.downloads[$tool].url' "$manifest")
  checksum=$(jq -er --arg tool "$tool" '.downloads[$tool].sha256' "$manifest")
  [[ $checksum =~ ^[0-9a-f]{64}$ ]]
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-all-errors --connect-timeout 20 --max-time 180 "$url" --output "$destination"
  printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --strict -
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

download azureCli "$work/az.deb"
[[ $(dpkg-deb --field "$work/az.deb" Version) == "$(jq -r '.downloads.azureCli.packageVersion' "$manifest")" ]]
dpkg --install "$work/az.deb"

download bicep "$work/bicep"
install -m 0755 "$work/bicep" /usr/local/bin/bicep

download terraform "$work/terraform.zip"
python3 - "$work/terraform.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    with open("/usr/local/bin/terraform", "wb") as output:
        output.write(archive.read("terraform"))
PY
chmod 0755 /usr/local/bin/terraform

download node "$work/node.tar.gz"
mkdir /opt/node
tar --extract --gzip --file "$work/node.tar.gz" --directory /opt/node --strip-components=1 --no-same-owner
ln -s /opt/node/bin/node /usr/local/bin/node
ln -s /opt/node/bin/npm /usr/local/bin/npm
ln -s /opt/node/bin/npx /usr/local/bin/npx

download pwsh "$work/pwsh.tar.gz"
mkdir /opt/pwsh
tar --extract --gzip --file "$work/pwsh.tar.gz" --directory /opt/pwsh --no-same-owner
chmod 0755 /opt/pwsh/pwsh
ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh

# The base grants passwordless sudo and includes a daemon; neither belongs in job execution.
usermod --groups users runner
rm -f /usr/bin/dockerd
chmod 0750 /home/runner
chmod -R go-w /opt/az /opt/node /opt/pwsh /opt/runner-image
