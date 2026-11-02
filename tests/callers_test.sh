#!/bin/bash
# Tests for the visitor counter: login event queued by welcome_screen, counted
# and logged by sbin/bbs-publish (handle_call), forged owner, log cap, the
# "You are caller #N" line and the Last callers view (lib/menu.sh).
# Owner is faked with ASOWNER (stubs stat -c %U). Own BBS_ROOT per run.
# Usage: tests/callers_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/callers_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }

root=$(mktemp -d "$scratch/callers.XXXXXX")
home=$root/home; mkdir -p "$home"
mkdir -p "$root"/{queue/incoming,state,drop/rejected,wall,lib,boards/general,meta}
cp "$here/lib/news-categories.conf" "$root/lib/"

lib() { ( export BBS_ROOT="$root" BBS_LOCK_WAIT=2 BBS_CALLERS_KEEP="${KEEP:-500}" BASHBBS_TEST=1
          source "$here/sbin/bbs-publish"
          stat() { if [[ ${1:-} == -c && ${2:-} == %U ]]; then echo "${ASOWNER:-}"; else command stat "$@"; fi; }
          "$@" ) >>"$log" 2>&1; }
proc() { ASOWNER=$1 lib process "$2"; }
menu_run() { local out=$1; shift
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=dumb HOME="$home"
      source "$here/lib/menu.sh"; "$@" ) > "$out" 2>>"$log"; }
welcome() { ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=dumb HOME="$home"
      source "$here/lib/menu.sh"; printf '\n' | { welcome_screen; } ) > "$1" 2>>"$log"; }
calls() { ls "$root"/queue/incoming/*.call 2>/dev/null | wc -l; }
fits() { python3 -c 'import sys; w=int(sys.argv[1]); sys.exit(any(len(l.rstrip("\n"))>w for l in open(sys.argv[2],encoding="utf-8")))' "$1" "$2"; }

# 1. Login queues one event; screen says caller #1.
welcome "$root/w1.txt"
check "login queues one .call file" eq "$(calls)" 1
check "queued file is empty (nothing user-controlled)" eq "$(stat -c %s "$root"/queue/incoming/*.call)" 0
check "first login: caller #1" grep -qx 'You are caller #1' "$root/w1.txt"
check "no temp file left" eq "$(ls -A "$root/queue/incoming" | grep -c '^\.tmp')" 0

# 2. Job counts and logs; owner decides the name (alias uid resolves to bbs-alice).
f=$(ls "$root"/queue/incoming/*.call)
check "job accepts the event" proc bbs-alice "$f"
check "event file removed" eq "$(calls)" 0
check "log has one line: ISO minute + name" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z alice$' "$root/state/callers.log"
check "total is 1" eq "$(cat "$root/state/callers.total")" 1
check "log has no IP or seconds" not grep -Eq '[0-9]+\.[0-9]+\.[0-9]+|:[0-9]{2}:[0-9]{2}' "$root/state/callers.log"
check "log and total world readable" eq "$(stat -c %a "$root/state/callers.log" "$root/state/callers.total" | tr '\n' ' ')" "644 644 "

# 3. Forged owner: content naming someone else is ignored; a non-bbs owner is dropped.
printf 'Author: bbs-bob\nbbs-bob\n' > "$root/queue/incoming/1-x.call"
check "text in the file does not choose the name" proc bbs-carol "$root/queue/incoming/1-x.call"
check "name is the file owner (carol)" grep -q ' carol$' "$root/state/callers.log"
check "bob not logged" not grep -q ' bob$' "$root/state/callers.log"
printf '' > "$root/queue/incoming/2-y.call"
proc root "$root/queue/incoming/2-y.call"
proc nobody "$root/queue/incoming/2-y.call"
check "non-bbs owner: nothing logged" eq "$(wc -l < "$root/state/callers.log")" 2
check "non-bbs owner: file dropped" test ! -e "$root/queue/incoming/2-y.call"
head -c 200 /dev/zero > "$root/queue/incoming/3-z.call"
proc bbs-dave "$root/queue/incoming/3-z.call"
check "oversized event rejected, not counted" eq "$(cat "$root/state/callers.total")" 2
check "oversized event quarantined" test -e "$root/drop/rejected/3-z.call"

# 4. Same account, same minute: counted once.
: > "$root/queue/incoming/4-a.call"; : > "$root/queue/incoming/5-a.call"
proc bbs-carol "$root/queue/incoming/4-a.call"; proc bbs-carol "$root/queue/incoming/5-a.call"
check "repeat in the same minute counted once" eq "$(cat "$root/state/callers.total")" 2

# 5. Cap: keep the last N lines by rewriting; total keeps counting; inode stays.
ino=$(stat -c %i "$root/state/callers.log")
for i in 1 2 3 4 5 6; do
    : > "$root/queue/incoming/9$i-b.call"; proc bbs-usr$i "$root/queue/incoming/9$i-b.call"
done
KEEP=4 proc bbs-last "$(: > "$root/queue/incoming/99-c.call"; echo "$root/queue/incoming/99-c.call")"
check "log capped at 4 lines" eq "$(wc -l < "$root/state/callers.log")" 4
check "newest line kept" grep -q ' last$' "$root/state/callers.log"
check "oldest line gone" not grep -q ' alice$' "$root/state/callers.log"
check "total keeps counting past the cap" eq "$(cat "$root/state/callers.total")" 9
check "log rewritten in place (same inode)" eq "$(stat -c %i "$root/state/callers.log")" "$ino"

# 6. Screen: number continues from the total and counts events still queued.
welcome "$root/w2.txt"
check "intro shows caller #10" grep -qx 'You are caller #10' "$root/w2.txt"
welcome "$root/w3.txt"
check "pending event counted: caller #11" grep -qx 'You are caller #11' "$root/w3.txt"
check "caller line fits 40 columns" bash -c "grep -x 'You are caller #[0-9]*' \"$root/w2.txt\" | awk '{exit length(\$0) > 40}'"

# 7. Last callers view: newest first, at most 10, 40 columns.
rm -f "$root"/queue/incoming/*.call
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '2026-11-01T10:%02dZ user%d\n' "$i" "$i"; done > "$root/state/callers.log"
menu_run "$root/v.txt" bash -c 'echo | callers_view' 2>/dev/null || ( export BBS_ROOT="$root" BASHBBS_TEST=1 TERM=dumb HOME="$home" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice; source "$here/lib/menu.sh"; echo | callers_view > "$root/v.txt" 2>>"$log" )
check "view lists 10 callers" eq "$(grep -c ' user[0-9]*$' "$root/v.txt")" 10
check "view: newest first" eq "$(grep -m1 ' user' "$root/v.txt" | awk '{print $NF}')" user12
check "view: oldest shown is user3" grep -q ' user3$' "$root/v.txt"
check "view: user2 not shown" not grep -q ' user2$' "$root/v.txt"
check "view fits 40 columns" fits 40 "$root/v.txt"
check "Fame & Glory offers Last Callers" grep -q 'menu_item 2 "Last Callers"' "$here/lib/menu.sh"

echo "SUMMARY pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
