#!/usr/bin/env bash
set -euo pipefail

[[ -f /.dockerenv ]] || { echo 'Run this fixture only in its isolated Docker container.' >&2; exit 1; }
guard=$PWD/reboot-guard.sh
marker=/var/lib/ghr-spike60/initial-boot-id
work=$(mktemp -d)
bin=$work/bin
log=$work/firewall.log
mkdir -p "$bin" /var/lib/ghr-spike60
[[ ! -e $marker && ! -L $marker ]] || { echo 'Unexpected existing reboot marker.' >&2; exit 1; }
trap 'rm -f -- "$marker"; rmdir --ignore-fail-on-non-empty /var/lib/ghr-spike60; rm -rf -- "$work"' EXIT
export GHR_SPIKE60_TEST_LOG=$log

for command in iptables ip6tables; do
  cat > "$bin/$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >> "$GHR_SPIKE60_TEST_LOG"
[[ -z ${GHR_SPIKE60_FAIL_COMMAND:-} || "${0##*/} $*" != "$GHR_SPIKE60_FAIL_COMMAND" ]]
SH
  chmod 0755 "$bin/$command"
done

expect_failure() {
  if GHR_SPIKE60_FAIL_COMMAND="${1:-}" PATH="$bin:$PATH" "$guard"; then
    echo 'Reboot guard unexpectedly succeeded.' >&2
    exit 1
  fi
}

: > "$log"
expect_failure
[[ ! -s $log ]]

: > "$marker"
expect_failure
[[ ! -s $log ]]

printf 'not-a-boot-id\n' > "$marker"
expect_failure
[[ ! -s $log ]]

printf '00000000-0000-0000-0000-000000000000\n' > "$marker"
: > "$log"
if ! GHR_SPIKE60_FAIL_COMMAND= PATH="$bin:$PATH" "$guard"; then
  echo 'Stale boot marker did not apply the firewall successfully.' >&2
  exit 1
fi
cat > "$work/expected" <<'EOF'
iptables -w 5 -P OUTPUT DROP
iptables -w 5 -P INPUT DROP
ip6tables -w 5 -P OUTPUT DROP
ip6tables -w 5 -P INPUT DROP
EOF
diff -u "$work/expected" "$log"

: > "$log"
expect_failure 'iptables -w 5 -P OUTPUT DROP'
[[ $(wc -l < "$log") -eq 1 ]]

: > "$log"
expect_failure 'ip6tables -w 5 -P OUTPUT DROP'
[[ $(wc -l < "$log") -eq 3 ]]

printf '%s\n' "$(< /proc/sys/kernel/random/boot_id)" > "$marker"
: > "$log"
GHR_SPIKE60_FAIL_COMMAND= PATH="$bin:$PATH" "$guard"
[[ ! -s $log ]]
