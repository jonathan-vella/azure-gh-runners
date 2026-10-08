#!/usr/bin/env bash
set -euo pipefail

marker=/var/lib/ghr-spike60/initial-boot-id
[[ -s $marker ]] || exit 0
initial_boot_id=$(<"$marker")
current_boot_id=$(</proc/sys/kernel/random/boot_id)
[[ $initial_boot_id =~ ^[a-f0-9-]{36}$ && $current_boot_id =~ ^[a-f0-9-]{36}$ ]] || exit 1
[[ $initial_boot_id == "$current_boot_id" ]] && exit 0

iptables -w 5 -P OUTPUT DROP
iptables -w 5 -P INPUT DROP
ip6tables -w 5 -P OUTPUT DROP
ip6tables -w 5 -P INPUT DROP
