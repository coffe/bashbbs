#!/bin/bash
# Tests for lib/install-helpers.sh: a missing config is installed, an edited config
# is kept with the repo version in <target>.new, an identical one is left alone,
# and only the missing packages of the asked level are listed. Runs as the current
# user, so the install target is a temp file and no system path is touched.
# Usage: tests/install_helpers_test.sh   (failures and the summary are printed)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d"; fi
}
source "$here/lib/install-helpers.sh"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
repo="$root/repo.conf"
echo "repo version" > "$repo"

# keep_or_note: a missing target is installed.
keep_or_note "$repo" "$root/new.conf" 2>/dev/null
check "missing target is installed" cmp -s "$repo" "$root/new.conf"

# keep_or_note: an identical target is left alone and gets no .new file.
keep_or_note "$repo" "$root/new.conf" 2>/dev/null
check "identical target gets no .new" test ! -e "$root/new.conf.new"

# keep_or_note: an edited target is kept, and the repo version goes to .new.
echo "sysop edit" > "$root/new.conf"
note=$(keep_or_note "$repo" "$root/new.conf" 2>&1)
check "edited target is kept" grep -qx 'sysop edit' "$root/new.conf"
check "repo version goes to .new" cmp -s "$repo" "$root/new.conf.new"
check "a note names the kept file" grep -q 'KEPT' <<<"$note"

# bashbbs_missing_deps: only failing checks of the asked level are listed.
BASHBBS_DEPS=(
    "alpha|required|false"
    "beta|optional|false"
    "gamma|required|true"
    "delta|optional|false"
)
check "required lists only the failing required package" \
    test "$(bashbbs_missing_deps required)" = "alpha"
check "optional lists only the failing optional packages" \
    test "$(bashbbs_missing_deps optional)" = "$(printf 'beta\ndelta')"
check "a passing package is never listed" \
    bash -c '! grep -q gamma <<<"$1"' _ "$(bashbbs_missing_deps required)"

echo "install_helpers_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
