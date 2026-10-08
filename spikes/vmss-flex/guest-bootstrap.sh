#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=30s 1200s /bin/bash "$0" --bounded "$@"
fi
shift
fail_closed() {
  trap - ERR TERM INT HUP
  printf '%s\n' "$1" >&2
  iptables -w 5 -P OUTPUT DROP || printf 'Failed to drop IPv4 output.\n' >&2
  iptables -w 5 -P INPUT DROP || printf 'Failed to drop IPv4 input.\n' >&2
  ip6tables -w 5 -P OUTPUT DROP || printf 'Failed to drop IPv6 output.\n' >&2
  ip6tables -w 5 -P INPUT DROP || printf 'Failed to drop IPv6 input.\n' >&2
  systemctl poweroff --no-block || printf 'Failed to request guest poweroff.\n' >&2
  exit 1
}
install_fail_closed_traps() {
  trap 'fail_closed "Guest bootstrap failed; dropping traffic and requesting poweroff."' ERR
  trap 'fail_closed "Guest bootstrap received a termination signal; dropping traffic and requesting poweroff."' TERM INT HUP
}
require_free_controller_uid() {
  if getent passwd 1002 >/dev/null; then
    fail_closed 'Controller UID 1002 is already in use; refusing to continue.'
  fi
}
install_fail_closed_traps

[[ $# == 4 && $(id -u) == 0 ]]
mode=$1 head=$2 archive_sha=$3 config=$4
[[ $mode == worker || $mode == controller ]]
[[ $head =~ ^[a-f0-9]{40}$ && $archive_sha =~ ^[a-f0-9]{64}$ ]]
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]]
[[ $(dpkg-query -W -f='${Version}' iptables) == 1.8.10-3ubuntu2 ]]

systemctl mask apt-daily.service apt-daily-upgrade.service unattended-upgrades.service

# Separate ingress/egress quotas bound total transfer to 4 GiB per guest.
# No paid guest-log sink or image/staging resource is created by this spike.
iptables -w 5 -N GHR_SPIKE60_BYTES
iptables -w 5 -A GHR_SPIKE60_BYTES -m quota --quota 2147483648 -j RETURN
iptables -w 5 -A GHR_SPIKE60_BYTES -j REJECT
iptables -w 5 -I OUTPUT 1 -j GHR_SPIKE60_BYTES
iptables -w 5 -N GHR_SPIKE60_INPUT
iptables -w 5 -A GHR_SPIKE60_INPUT -m quota --quota 2147483648 -j RETURN
iptables -w 5 -A GHR_SPIKE60_INPUT -j DROP
iptables -w 5 -I INPUT 1 -j GHR_SPIKE60_INPUT
iptables -w 5 -I OUTPUT 2 -p tcp --dport 53 -j REJECT
iptables -w 5 -N GHR_SPIKE60_DNS
iptables -w 5 -A GHR_SPIKE60_DNS -m limit --limit 2/second --limit-burst 20 -j RETURN
iptables -w 5 -A GHR_SPIKE60_DNS -j REJECT
iptables -w 5 -I OUTPUT 3 -p udp --dport 53 -j GHR_SPIKE60_DNS
ip6tables -w 5 -P OUTPUT DROP
ip6tables -w 5 -P INPUT DROP

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 120 --max-filesize 10485760 \
  "https://api.github.com/repos/jonathan-vella/azure-gh-runners/tarball/$head" --output "$work/source.tar.gz"
printf '%s  %s\n' "$archive_sha" "$work/source.tar.gz" | sha256sum --check --strict - >/dev/null
install -d -o root -g root -m 0755 /opt/ghr-source
tar --extract --gzip --file "$work/source.tar.gz" --directory /opt/ghr-source \
  --strip-components=1 --no-same-owner
chmod -R go-w /opt/ghr-source
install -o root -g root -m 0555 /opt/ghr-source/spikes/vmss-flex/reboot-guard.sh \
  /usr/local/sbin/ghr-spike60-reboot-guard
cat > /etc/systemd/system/ghr-spike60-reboot-guard.service <<'UNIT'
[Unit]
Description=Prevent VMSS spike traffic quotas from resetting after reboot
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ghr-spike60-reboot-guard
RemainAfterExit=yes
FailureAction=poweroff
UNIT
install -d -o root -g root -m 0700 /var/lib/ghr-spike60
network_units=0
active_network_units=0
for unit in systemd-networkd.service NetworkManager.service; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    unit_id=$(systemctl show --property=Id --value "$unit") ||
      fail_closed "Could not resolve systemd unit $unit."
    [[ $unit_id == *.service && $unit_id != */* ]] ||
      fail_closed "Unsupported systemd unit identity for $unit."
    dropin="/etc/systemd/system/$unit_id.d/ghr-spike60-reboot-guard.conf"
    install -d -o root -g root -m 0755 "${dropin%/*}"
    cat > "$dropin" <<'UNIT'
[Unit]
Requires=ghr-spike60-reboot-guard.service
After=ghr-spike60-reboot-guard.service
UNIT
    network_units=$((network_units + 1))
    if systemctl is-active --quiet "$unit"; then
      active_network_units=$((active_network_units + 1))
    fi
  fi
done
if [[ $network_units -eq 0 || $active_network_units -eq 0 ]]; then
  fail_closed 'No supported active systemd network manager; refusing to continue.'
fi
systemctl daemon-reload
marker=/var/lib/ghr-spike60/initial-boot-id
[[ ! -e $marker && ! -L $marker ]]
marker_tmp=$(mktemp /var/lib/ghr-spike60/.initial-boot-id.XXXXXX)
cat /proc/sys/kernel/random/boot_id > "$marker_tmp"
chmod 0444 "$marker_tmp"
mv -T -- "$marker_tmp" "$marker"
# The regional image's patch baseline is not the local rootfs baseline. Install
# the exact inherited minimum on both guests, inside existing byte/DNS quotas.
manifest=/opt/ghr-source/image/versions.json
/bin/bash /opt/ghr-source/spikes/vmss-flex/install-minimal-tools.sh "$manifest"

if [[ $mode == worker ]]; then
  [[ $config == none ]]
  /bin/bash /opt/ghr-source/spikes/vmss-flex/native-bootstrap.sh ||
    fail_closed 'Native worker bootstrap failed; dropping traffic and requesting poweroff.'
  exit 0
fi
[[ $config =~ ^[A-Za-z0-9+/]+={0,2}$ ]]
require_free_controller_uid
groupadd --gid 1002 controller
useradd --uid 1002 --gid 1002 --groups users --create-home --shell /bin/bash controller
passwd --lock controller >/dev/null
install -d -o root -g root -m 0755 /opt/ghr-vmss
install -d -o controller -g controller -m 0700 /var/lib/ghr-vmss
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 120 --max-filesize 62914560 \
  https://go.dev/dl/go1.25.3.linux-amd64.tar.gz --output "$work/go.tar.gz"
printf '%s  %s\n' 0335f314b6e7bfe08c3d0cfaa7c19db961b7b99fb20be62b0a826c992ad14e0f "$work/go.tar.gz" |
  sha256sum --check --strict - >/dev/null
tar --extract --gzip --file "$work/go.tar.gz" --directory /opt --no-same-owner
runuser --user controller -- env -i HOME=/home/controller \
  PATH=/opt/go/bin:/usr/bin:/bin GOTOOLCHAIN=local CGO_ENABLED=0 \
  timeout --signal=TERM --kill-after=10s 600s /opt/go/bin/go build \
  -C /opt/ghr-source/spikes/vmss-flex -mod=readonly -o /var/lib/ghr-vmss/controller .
install -o root -g root -m 0555 /var/lib/ghr-vmss/controller /opt/ghr-vmss/controller
rm -f /var/lib/ghr-vmss/controller
url=$(jq -er '.downloads.bicep.url' /opt/ghr-source/image/versions.json)
checksum=$(jq -er '.downloads.bicep.sha256' /opt/ghr-source/image/versions.json)
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 180 --max-filesize 314572800 "$url" --output "$work/bicep"
printf '%s  %s\n' "$checksum" "$work/bicep" | sha256sum --check --strict - >/dev/null
chmod 0555 "$work/bicep"
timeout --signal=TERM --kill-after=10s 180s "$work/bicep" build \
  /opt/ghr-source/spikes/vmss-flex/infra/worker.bicep --outfile /opt/ghr-vmss/worker.json
printf '%s' "$config" | base64 --decode > "$work/controller.json"
hash=$(sha256sum /opt/ghr-vmss/worker.json | cut -d' ' -f1)
jq --arg hash "$hash" '.templateSha256=$hash' "$work/controller.json" > /opt/ghr-vmss/controller.json
chmod 0444 /opt/ghr-vmss/worker.json /opt/ghr-vmss/controller.json
cat > /etc/systemd/system/ghr-spike60.service <<'UNIT'
[Unit]
After=network-online.target cloud-final.service
Wants=network-online.target
[Service]
User=controller
Group=controller
ExecStart=/opt/ghr-vmss/controller -execute-on-private-controller -controller-config /opt/ghr-vmss/controller.json
Restart=no
RuntimeMaxSec=10800
TimeoutStopSec=180
KillMode=control-group
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ghr-vmss
PrivateTmp=true
StandardOutput=journal
StandardError=null
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
install -d -o root -g root -m 0755 /run/ghr-vmss
printf '%s\n' 'verified' > /run/ghr-vmss/controller-ready
chmod 0444 /run/ghr-vmss/controller-ready
