#!/bin/bash
# Tests for the public user list (list_users in lib/menu.sh): a profile with the
# line hidden=yes is left out, every other profile is listed, and hidden=no does
# not hide; Who's online (online_view). Only the menu functions are sourced; the start loop is skipped.
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

# Who's online with the who -u rows the Raspberry Pis really print (garbage date, empty
# LINE): parsed from the end, login time from ps etimes of the pids.
mk delta
bin=$root/bin; mkdir -p "$bin"
cat > "$bin/who" <<'W'
#!/bin/sh
printf '%s\n' 'bbs-alpha pts/0        8070917549812449543 00:13         849 (192.168.1.112)' \
    'bbs-alpha pts/1        72524611602561902  old         6901 (192.168.1.1)' \
    'bbs-gamma             1970-01-07 06:11  .          597' \
    'bbs-beta  pts/3        2026-11-21 00:01   .         700 (10.0.0.1)'
W
cat > "$bin/ps" <<'P'
#!/bin/sh
printf '%s\n' '  849 600' ' 6901 90000' '  597 7200' '  700 5'
P
chmod +x "$bin/who" "$bin/ps"
out=$(PATH="$bin:$PATH" BBS_ROOT="$root" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alpha TERM=dumb \
    bash -c "source '$here/lib/menu.sh'; pause() { :; }; redraw() { :; }; online_view" </dev/null 2>&1)
want_a=$(date -d @$(( $(date +%s) - 90000 )) +%H:%M)
want_g=$(date -d @$(( $(date +%s) - 7200 )) +%H:%M)
check "online: two sessions, oldest time, shortest idle" grep -Eq "^alpha +$want_a +13m +x2\$" <<<"$out"
check "online: empty LINE column still parses" grep -Eq "^gamma +$want_g +-\$" <<<"$out"
check "online: hidden account left out" bash -c '! grep -q "^beta" <<<"$1"' _ "$out"
check "online: no old/garbage" bash -c '! grep -q "old\|8070917" <<<"$1"' _ "$out"
[[ $fail -eq 0 ]] || printf '%s\n' "$out"

echo "user_list_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
