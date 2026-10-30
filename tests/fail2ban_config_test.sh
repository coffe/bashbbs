#!/bin/bash
# Static checks for the fail2ban jail and its installer gate. Nothing is run on the
# host: fail2ban is not needed here, and a jail that reaches iptables would only
# show up on a real install.
# Checks: no LAN exemption, loopback only, nftables ban actions, and no iptables
# action in the jail. The installer must also require nft before it installs the jail.
# Usage: tests/fail2ban_config_test.sh   (failures and the summary are printed)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
jail="$here/etc/fail2ban-jail.local"
pass=0; fail=0
check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d"; fi
}

check "no hardcoded LAN exemption" bash -c '! grep -q "192\.168\." "$1"' _ "$jail"
check "ignoreip is loopback only" grep -qx 'ignoreip = 127.0.0.0/8 ::1' "$jail"
check "ban action is nftables" grep -qx 'banaction = nftables' "$jail"
check "allports ban action is nftables" grep -qx 'banaction_allports = nftables\[type=allports\]' "$jail"
check "no iptables action in the jail" bash -c '! grep -v "^#" "$1" | grep -qi iptables' _ "$jail"
check "installer requires nft for the jail" grep -q 'command -v fail2ban-client >/dev/null && command -v nft >/dev/null' "$here/install.sh"
check "nftables dependency is tied to fail2ban" grep -q '! command -v fail2ban-client >/dev/null || command -v nft' "$here/lib/install-helpers.sh"

echo "fail2ban_config_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
