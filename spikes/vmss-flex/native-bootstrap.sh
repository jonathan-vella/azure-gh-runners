#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=10s 900s /bin/bash "$0" --bounded
fi
[[ $# == 1 && $(id -u) == 0 && $(dpkg --print-architecture) == amd64 ]]
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
if command -v dockerd >/dev/null || [[ -S /var/run/docker.sock ]]; then
  echo 'Native bootstrap requires a fresh guest with no Docker daemon or socket.' >&2
  exit 1
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
manifest="$root/image/versions.json"
native="$root/spikes/vmss-flex/native-image.json"
[[ -f $manifest && -f $native ]]
[[ $(jq -r '.base.version' "$manifest") == "$(jq -r '.runnerArchive.version' "$native")" ]]

download() {
  local url=$1 checksum=$2 destination=$3
  [[ $url == https://* && $checksum =~ ^[a-f0-9]{64}$ ]]
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 180 --max-filesize 314572800 "$url" --output "$destination"
  printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --strict -
}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
uid=$(jq -r '.base.runnerUid' "$manifest")
gid=$(jq -r '.base.runnerGid' "$manifest")
if getent passwd runner >/dev/null || getent passwd "$uid" >/dev/null || getent group "$gid" >/dev/null; then
  echo 'Native bootstrap requires a fresh guest without the runner account.' >&2
  exit 1
fi
groupadd --gid "$gid" runner
useradd --uid "$uid" --gid "$gid" --groups users --create-home --shell /bin/bash runner
passwd --lock runner >/dev/null

# Git is the only manifest package differing from the selected Azure VHD manifest.
# The PPA key is authenticated by its full fingerprint, never TOFU.
fingerprint=$(jq -r '.gitPpaFingerprint' "$native")
curl --fail --silent --show-error --proto '=https' --connect-timeout 20 --max-time 60 \
  "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$fingerprint" --output "$work/git.asc"
actual=$(gpg --batch --with-colons --import-options show-only --import "$work/git.asc" 2>/dev/null |
  awk -F: '$1 == "fpr" {print $10; exit}')
[[ $actual == "$fingerprint" ]]
gpg --batch --dearmor --output "$work/git.gpg" "$work/git.asc"
install -o root -g root -m 0644 "$work/git.gpg" /usr/share/keyrings/ghr-spike-git.gpg
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/ghr-spike-git.gpg] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble main' \
  > /etc/apt/sources.list.d/ghr-spike-git.list
sed -i 's|http://archive.ubuntu.com/|https://archive.ubuntu.com/|g; s|http://security.ubuntu.com/|https://security.ubuntu.com/|g' \
  /etc/apt/sources.list.d/ubuntu.sources
timeout --signal=TERM --kill-after=10s 180s apt-get -o APT::Update::Error-Mode=any \
  -o Acquire::Retries=0 -o Acquire::https::Timeout=20 update
git_version=$(jq -r '.inherited.git.packageVersion' "$manifest")
DEBIAN_FRONTEND=noninteractive timeout --signal=TERM --kill-after=10s 180s \
  apt-get -o Acquire::Retries=0 -o Acquire::https::Timeout=20 --yes --no-install-recommends \
  install "git=$git_version" "git-man=$git_version"
while IFS=$'\t' read -r package version; do
  [[ $(dpkg-query -W -f='${Version}' "$package") == "$version" ]]
done < <(jq -r '.inherited[] | [.package, .packageVersion] | @tsv' "$manifest")

download "$(jq -r '.runnerArchive.url' "$native")" "$(jq -r '.runnerArchive.sha256' "$native")" "$work/runner.tar.gz"
tar --extract --gzip --file "$work/runner.tar.gz" --directory /home/runner --no-same-owner
chown -R runner:runner /home/runner
install -d -o root -g root -m 0755 /opt/runner-image
install -o root -g root -m 0444 "$manifest" /opt/runner-image/versions.json
install -o root -g root -m 0555 "$root/image/install-tools.sh" "$root/image/verify-tools.sh" \
  "$root/image/pre-job-policy.sh" "$root/image/pre-job-policy.py" /opt/runner-image/
install -d -o root -g root -m 0755 /opt/ghr-vmss
install -o root -g root -m 0555 "$root/spikes/vmss-flex/run-one-job.sh" /opt/ghr-vmss/run-one-job.sh
/bin/bash /opt/runner-image/install-tools.sh
[[ ! -S /var/run/docker.sock ]]
if command -v dockerd >/dev/null; then
  echo 'Native bootstrap refuses an installed Docker daemon.' >&2
  exit 1
fi
runuser --user runner -- env -i HOME=/home/runner \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh \
  AZURE_CORE_COLLECT_TELEMETRY=false AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no \
  AZURE_BICEP_USE_BINARY_FROM_PATH=true POWERSHELL_TELEMETRY_OPTOUT=1 \
  DOTNET_CLI_TELEMETRY_OPTOUT=1 /bin/bash /opt/runner-image/verify-tools.sh
printf '%s\n' 'Native toolset and root-owned policy hook verified; no JIT or job started.'
