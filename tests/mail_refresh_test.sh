#!/bin/bash
# New mail while logged in: the top bar shows "Mail (N)" on every screen once something
# is in Maildir/new, and the Inbox has R) Refresh (also when it is empty).
# The message is dropped between two keystrokes, by a menu_key wrapper in the session.
# Usage: tests/mail_refresh_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/mail_refresh_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -q -- "$2" "$1"; }
not() { ! "$@"; }
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/mr.XXXXXX")
out=$(mktemp -d "$scratch/mrout.XXXXXX")
home=$root/home
mkdir -p "$root"/{boards,meta,queue/incoming} "$home"/Maildir/{tmp,new,cur}
ESC=$'\033'

# drive <outfile> <color> <code> <steps...>: runs <code> in a session where the first
# call of menu_key first drops a message into Maildir/new.
drive() {
    local o=$1 c=$2 code=$3; shift 3
    local -a st=(); local s
    for s in "$@"; do st+=(--step "$s"); done
    python3 "$here/tests/pty_drive.py" --cols 80 --out "$o" --timeout 30 "${st[@]}" -- \
        env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb BASHBBS_COLOR="$c" \
        bash -c "source $here/lib/menu.sh
eval \"_orig_\$(declare -f menu_key)\"
dropped=0
menu_key() {
    if (( ! dropped )); then dropped=1
        printf 'From: bob\nSubject: Fresh mail\n\nHej\n' > $home/Maildir/new/1700000000.t1.host
    fi
    _orig_menu_key \"\$@\"
}
$code; echo DONE" 2>>"$log"
}
mv_away() { mv "$home"/Maildir/new/* "$out/" 2>/dev/null; }

# 1. Empty inbox: no return at once; message arrives while the prompt waits; R shows it.
drive "$out/a.txt" 0 'mail_view Inbox' 'R) Refresh=>r' 'Number: open=>q'
a=$(tr -d '\r' < "$out/a.txt")
check "empty inbox says No messages and offers R) Refresh / Q) Back" bash -c "grep -q 'No messages' <<<'$a' && grep -q '^R) Refresh   Q) Back' <<<'$a'"
check "R) Refresh shows the message that arrived meanwhile" bash -c "grep -q '^  1) \* Fresh mail' <<<'$a'"
check "list has R) Refresh in its key line" bash -c "grep -q 'Number: open   R) Refresh   Q) Back' <<<'$a'"
check "session ends" has "$out/a.txt" DONE
mv_away

# 2. Empty inbox, Q goes back.
drive "$out/b.txt" 0 'mail_view Inbox' 'R) Refresh=>q'
check "empty inbox: Q leaves" has "$out/b.txt" DONE
mv_away

# 3. Top bar on another screen: the indicator shows after a redraw (R in the Inbox reaches
# redraw but local_header has no bar, so use screen_header via the main menu: "?" redraws).
drive "$out/c.txt" 0 'main_menu' 'Q) Log out=>?' 'Any key=>x' 'Q) Log out=>Q' 'Log out? =>y'
c=$(tr -d '\r' < "$out/c.txt")
check "top bar: plain 'Mail (1)' after the message arrived" bash -c "grep -q '\[B\] Boards \[M\] Main \[P\] Mail (1) \[W\] Wall' <<<'$c'"
check "top bar: no indicator before the message arrived" bash -c "grep -q '\[P\] Mail \[W\]' <<<'$c'"
check "main menu counts it too" bash -c "grep -q '5) Mail (1 unread)' <<<'$c'"
mv_away
check "top bar: no colour codes with colour off" not has "$out/c.txt" "$ESC\[[0-9;]*m"

# 4. Mail menu: L) Look 4 new mail finds the message that arrived at the prompt.
drive "$out/d.txt" 0 'mail_menu' 'Look 4 new mail=>l' '1 new message=>l' 'Q) Back=>q'
d=$(tr -d '\r' < "$out/d.txt")
check "mail menu lists L) Look 4 new mail" grep -q '^L) Look 4 new mail' "$out/d.txt"
check "L reports the new message" grep -q '^1 new message' "$out/d.txt"
check "session ends" has "$out/d.txt" DONE
mv_away
drive "$out/e.txt" 0 'mail_menu' 'Look 4 new mail=>l' 'Q) Back=>q'
e=$(tr -d '\r' < "$out/e.txt")
check "second look still counts it (no move to cur)" grep -q '^1 new message' "$out/e.txt"
mv_away
drive "$out/f.txt" 0 'mail_menu' 'Look 4 new mail=>q'
mv_away
drive "$out/g.txt" 0 'mail_menu' 'Look 4 new mail=>l' 'Q) Back=>q'
check "no colour codes in mail menu" not has "$out/g.txt" "$ESC\[[0-9;]*m"
mv_away

echo "mail_refresh_test: $pass passed, $fail failed (log: $log)"
exit $(( fail > 0 ))
