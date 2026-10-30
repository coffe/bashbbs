#!/bin/bash
# Tests for sbin/bbs-maildir: it creates the Inbox, Sent and Trash folders with
# tmp, new and cur and the mode 700, runs again without harm, keeps an existing
# message, and refuses a home directory that is missing. Runs as the current
# user, so the owner is the current user.
# Usage: tests/maildir_test.sh   (failures and the summary are printed)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d"; fi
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
home="$root/home/alice"
mkdir -p "$home"
owner="$(id -un):$(id -gn)"
run() { bash "$here/sbin/bbs-maildir" "$home" "$owner"; }

run >/dev/null 2>&1
check "first run succeeds" run

for folder in Maildir Maildir/.Sent Maildir/.Trash; do
    for sub in "" /tmp /new /cur; do
        check "$folder$sub exists" test -d "$home/$folder$sub"
    done
done
check "Inbox mode is 700" test "$(stat -c %a "$home/Maildir")" = 700
check "Trash cur mode is 700" test "$(stat -c %a "$home/Maildir/.Trash/cur")" = 700

echo "Hej" > "$home/Maildir/new/1700000000.test.host"
run >/dev/null 2>&1
check "second run succeeds" run
check "existing message survives a second run" grep -qx 'Hej' "$home/Maildir/new/1700000000.test.host"

check "missing home is refused" bash -c "! bash '$here/sbin/bbs-maildir' '$root/home/nobody' '$owner' 2>/dev/null"

# Owner: as non-root, chown cannot be tested for real. A stub install records its
# arguments instead, and the sysop and a regular user must each get their own owner.
stub=$(mktemp -d)
trap 'rm -rf "$root" "$stub"' EXIT
printf '#!/bin/bash\necho "$@" >> "$STUB_LOG"\n' > "$stub/install"
chmod +x "$stub/install"
eq() { [[ $1 == "$2" ]]; }
owners() { # owners <home> <owner:group>: the -o and -g arguments install got
    mkdir -p "$1"
    : > "$stub/log"
    PATH="$stub:$PATH" STUB_LOG="$stub/log" bash "$here/sbin/bbs-maildir" "$1" "$2"
    grep -o -- '-[og] [^ ]*' "$stub/log" | sort -u | tr '\n' ' '
}
check "sysop folders are owned by bbs-coffe" \
    eq "$(owners "$root/home/coffe" bbs-coffe:bbs-coffe)" "-g bbs-coffe -o bbs-coffe "
check "user folders are owned by bbs-alice" \
    eq "$(owners "$root/home/alice" bbs-alice:bbs-alice)" "-g bbs-alice -o bbs-alice "
echo "maildir_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
