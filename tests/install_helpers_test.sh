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

# bashbbs_missing_words: every missing package of both levels, on one line (apt-get gets all of them).
check "missing words joins both levels on one line" \
    test "$(bashbbs_missing_words | xargs)" = "alpha beta delta"

# bashbbs_postfix_warnings: a correct setup prints nothing. Each deviation prints its own warning.
echo "bbs.localdomain" > "$root/mailname"
good=$(bashbbs_postfix_warnings /etc/mailname '$myhostname, localhost, $myorigin' 'Maildir/' "$root/mailname" 2>&1)
check "correct Postfix setup prints nothing" test -z "$good"
origin=$(bashbbs_postfix_warnings pocket-scout.local '$myhostname, localhost' 'Maildir/' "$root/mailname" 2>&1)
check "wrong myorigin is reported" grep -q 'myorigin is' <<<"$origin"
check "missing \$myorigin in mydestination is reported" grep -q 'does not include \$myorigin' <<<"$origin"
nohost=$(bashbbs_postfix_warnings bbs.localdomain 'localhost' 'Maildir/' "$root/mailname" 2>&1)
check "missing \$myhostname is reported" grep -q 'does not include \$myhostname' <<<"$nohost"
mbox=$(bashbbs_postfix_warnings bbs.localdomain '$myhostname, $myorigin' '' "$root/mailname" 2>&1)
check "wrong home_mailbox is reported" grep -q "home_mailbox is 'unset'" <<<"$mbox"
check "myorigin read from a missing mailname file is reported" \
    grep -q "myorigin is 'unset'" <<<"$(bashbbs_postfix_warnings /nonexistent/mailname '$myhostname, $myorigin' 'Maildir/' "$root/nope" 2>&1)"

# sshd fragment: the newsstatus block is present, has no pty or forwarding, and runs only bbs-news-status.
frag="$here/etc/sshd-bashbbs.conf"
check "sshd fragment has a newsstatus Match block" grep -qx 'Match User newsstatus' "$frag"
check "newsstatus forces bbs-news-status" grep -qx '    ForceCommand /usr/local/sbin/bbs-news-status' "$frag"
check "newsstatus block has no pty" bash -c 'awk "/^Match User newsstatus/{f=1;next} /^Match /{f=0} f" "$1" | grep -qx "    PermitTTY no"' _ "$frag"
check "newsstatus block has no forwarding" bash -c 'awk "/^Match User newsstatus/{f=1;next} /^Match /{f=0} f" "$1" | grep -qx "    AllowTcpForwarding no"' _ "$frag"

# features_merge: a missing file is the template; an existing one keeps its values and
# gets only the missing names, off, with their comment.
tmpl="$here/etc/features.example"
features_merge "$tmpl" "$root/features" 2>/dev/null
check "features: missing file is the template" cmp -s "$tmpl" "$root/features"
check "features: template has every feature off" bash -c '! grep -E "^[a-z.]+=" "$1" | grep -qv "=off$"' _ "$tmpl"
printf 'wall=on
 news = on
games.turf=off
' > "$root/features2"
features_merge "$tmpl" "$root/features2" 2>/dev/null
check "features: existing values kept" bash -c 'head -n 3 "$1" | cmp -s - <(printf "wall=on\n news = on\ngames.turf=off\n")' _ "$root/features2"
check "features: missing name appended off" grep -qx 'fame=off' "$root/features2"
check "features: comment comes along" bash -c 'grep -B1 -x "fame=off" "$1" | grep -q "^# fame:"' _ "$root/features2"
check "features: no name twice" bash -c '[[ -z $(grep -oE "^ *[a-z.]+ *=" "$1" | tr -d " =" | sort | uniq -d) ]]' _ "$root/features2"
check "features: every template name present" bash -c 'for k in $(grep -oE "^[a-z.]+" <(grep -E "^[a-z.]+=" "$2")); do grep -qE "^ *${k//./\\.} *=" "$1" || exit 1; done' _ "$root/features2" "$tmpl"
cp "$root/features2" "$root/features3"; features_merge "$tmpl" "$root/features2" 2>/dev/null
check "features: second run changes nothing" cmp -s "$root/features2" "$root/features3"

echo "install_helpers_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
