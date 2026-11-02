#!/bin/bash
# Tests for pinned and closed threads: meta/<board>.pins read by lib/menu.sh (order, Reply
# key) and enforced by sbin/bbs-publish (closed threads take replies only from sysops).
# Usage: tests/pins_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/pins_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }
root=$(mktemp -d "$scratch/pins.XXXXXX")
home=$root/home; mkdir -p "$home"
mkdir -p "$root"/{queue/incoming,state,drop/rejected,wall,lib,meta,users} "$root"/boards/general
cp "$here/lib/news-categories.conf" "$root/lib/"
echo coffe > "$root/sysops"
B=$root/boards/general

lib() { ( export BBS_ROOT="$root" BBS_LOCK_WAIT=2 BASHBBS_TEST=1
          source "$here/sbin/bbs-publish"
          reply_notify() { return 0; }
          "$@" ) >>"$log" 2>&1; }
# post <account> <subject> [parent]: prints nothing, leaves the new msgid in $LAST
post() { local f=$root/in.$$ before after
    { printf 'Board: general\nSubject: %s\n' "$2"; [[ -n ${3:-} ]] && printf 'Parent: %s\n' "$3"; printf '\nbody\n'; } > "$f"
    lib handle_post "$f" "bbs-$1"; }
newest() { local f; f=$(ls -t "$B"/*.msg | head -n 1); f=${f##*/}; f=${f%.msg}; echo "${f#*-}"; }
# Menu functions as user <name>
as() { local who=$1 out=$2; shift 2
    ( export BBS_ROOT="$root" USER=bbs-$who BASHBBS_TEST_ID=bbs-$who BASHBBS_TEST=1 TERM=dumb HOME="$home" COLOR=0
      source "$here/lib/menu.sh"
      me=$who
      menu_key() { return 1; }
      "$@" ) > "$out" 2>>"$log"; }

post coffe welcome;     sleep 1; W=$(newest)
post coffe sysop-notes; sleep 1; S=$(newest)
post coffe "say hi";    sleep 1; H=$(newest)
post alice other;       sleep 1; O=$(newest)
printf '%s closed\n%s closed\n%s open\n' "$W" "$S" "$H" > "$root/meta/general.pins"

# Publisher
n() { ls "$B"/*.msg | wc -l; }
c=$(n); post alice "Re" "$W"
check "closed: reply from a member is rejected" eq "$(n)" "$c"
post coffe "note 2" "$S"; R=$(newest)
check "closed: sysop can add to the thread" eq "$(n)" "$((c + 1))"
c=$(n); post alice "Re" "$R"
check "closed: reply to a reply in the thread is rejected" eq "$(n)" "$c"
post alice "hi" "$H"
check "open pin: reply accepted" eq "$(n)" "$((c + 1))"
c=$(n); post alice "Re" "$O"
check "unpinned: reply accepted" eq "$(n)" "$((c + 1))"
c=$(n); post alice "new thread"; N=$(newest)
check "closed thread does not block new threads" eq "$(n)" "$((c + 1))"

# Thread order: pins first in file order, then newest activity
order() { rows=(); mapfile -t rows < <(board_threads general ""); pins_first general
          local r; for r in "${rows[@]}"; do post_hdr "${r%%$'\t'*}" Subject; done; }
as alice "$root/o.txt" order
check "order: pins in file order, then the rest" eq "$(tr '\n' ',' < "$root/o.txt")" "welcome,sysop-notes,say hi,new thread,other,"
rm_pins() { mv "$root/meta/general.pins" "$root/pins.off"; }
rm_pins
as alice "$root/o2.txt" order
check "no pins file: newest activity first" eq "$(head -n 1 "$root/o2.txt")" "new thread"
mv "$root/pins.off" "$root/meta/general.pins"

# Reply key
keys() { root=$1; post_actions general "$1"; }
f() { ls "$B"/*-"$1".msg; }
as alice "$root/k1.txt" keys "$(f "$W")"
check "closed: no Reply for a member" not grep -q "R) Reply" "$root/k1.txt"
as coffe "$root/k2.txt" keys "$(f "$W")"
check "closed: Reply for a sysop" grep -q "R) Reply" "$root/k2.txt"
check "closed: sysop keeps Edit and Delete" grep -q "E) Edit  D) Delete" "$root/k2.txt"
as alice "$root/k3.txt" keys "$(f "$H")"
check "open pin: Reply for a member" grep -q "R) Reply" "$root/k3.txt"
as alice "$root/k4.txt" keys "$(f "$O")"
check "unpinned: Reply and own Edit" grep -q "R) Reply  E) Edit" "$root/k4.txt"

echo "pins_test: $pass passed, $fail failed (log: $log)"
exit $(( fail > 0 ))
