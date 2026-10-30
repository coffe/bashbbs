#!/bin/bash
# Tests for the public user list (list_users in lib/menu.sh): a profile with the
# line hidden=yes is left out, every other profile is listed, and hidden=no does
# not hide. Only the menu functions are sourced; the start loop is skipped.
# Usage: tests/user_list_test.sh   (failures and the summary are printed)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d"; fi
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mk() { # mk <name> [extra profile line]
    mkdir -p "$root/users/$1"
    printf 'name=%s\nuuid=00000000-0000-4000-8000-%012d\ncreated=2026-10-30T00:00:00Z\n' "$1" "$RANDOM" > "$root/users/$1/profile"
    [[ -n ${2:-} ]] && echo "$2" >> "$root/users/$1/profile"
}
mk alpha
mk beta hidden=yes
mk gamma hidden=no

out=$(BBS_ROOT="$root" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alpha TERM=dumb \
    bash -c "source '$here/lib/menu.sh'; list_users" </dev/null 2>&1)

check "visible profile is listed" grep -q '^alpha ' <<<"$out"
check "hidden=no profile is listed" grep -q '^gamma ' <<<"$out"
check "hidden=yes profile is left out" bash -c '! grep -q "^beta " <<<"$1"' _ "$out"

echo "user_list_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
