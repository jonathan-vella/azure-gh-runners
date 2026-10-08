#!/usr/bin/env bash
set -euo pipefail

[[ -f /.dockerenv ]] || { echo 'Run this fixture only in its isolated Docker container.' >&2; exit 1; }
work=$(mktemp -d)
bin=$work/bin
log=$work/actions.log
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$bin"

awk '
  /^(fail_closed|install_fail_closed_traps|require_free_controller_uid)\(\) \{$/ { copying=1 }
  copying { print }
  copying && /^}$/ { print ""; copying=0 }
' guest-bootstrap.sh > "$work/failure-helpers.sh"
[[ $(grep -c '() {' "$work/failure-helpers.sh") -eq 3 ]]
export GHR_SPIKE60_TEST_LOG=$log

for command in iptables ip6tables systemctl; do
  cat > "$bin/$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >> "$GHR_SPIKE60_TEST_LOG"
SH
  chmod 0755 "$bin/$command"
done

cat > "$work/expected" <<'EOF'
iptables -w 5 -P OUTPUT DROP
iptables -w 5 -P INPUT DROP
ip6tables -w 5 -P OUTPUT DROP
ip6tables -w 5 -P INPUT DROP
systemctl poweroff --no-block
EOF

assert_shutdown_actions() {
  diff -u "$work/expected" "$log"
}

: > "$log"
if PATH="$bin:$PATH" timeout --signal=TERM --kill-after=5s 0.2s \
  bash -c 'source "$1"; install_fail_closed_traps; while :; do :; done' _ "$work/failure-helpers.sh" \
  > "$work/timeout.out" 2>&1; then
  echo 'Timed-out bootstrap fixture unexpectedly succeeded.' >&2
  exit 1
fi
assert_shutdown_actions

: > "$log"
if PATH="$bin:$PATH" bash -c \
  'source "$1"; getent() { return 0; }; require_free_controller_uid' _ "$work/failure-helpers.sh" \
  > "$work/uid.out" 2>&1; then
  echo 'Existing controller UID fixture unexpectedly succeeded.' >&2
  exit 1
fi
assert_shutdown_actions

echo 'Termination and UID-collision failures dropped both protocol families and requested poweroff.'
