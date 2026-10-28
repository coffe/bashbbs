#!/bin/bash
# Tests for the wall (one-line greetings): the publisher's *.wall rules and
# lock (sbin/bbs-publish), and the menu's list, write and entry view
# (lib/menu.sh). Every run uses its own BBS_ROOT under the scratchpad. The
# owner is set with ASOWNER, which stubs stat -c %U.
# Usage: tests/wall_test.sh [logfile]   (full log in the file; the screen shows
# only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/d1734d7a-ba5d-4ad7-aeee-cb0f3089f2e5/scratchpad}
log=${1:-$scratch/wall_test.log}
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }

newroot() {
    root=$(mktemp -d "$scratch/wall.XXXXXX")
    mkdir -p "$root"/{boards/general,meta,queue/incoming,state,drop/rejected,wall,lib,t}
    cp "$here/lib/news-categories.conf" "$root/lib/"
}

# Run one publisher function in a subshell with the script sourced.
lib() {
    ( export BBS_ROOT="$root" BBS_LOCK_WAIT="${LOCKW:-2}"
      source "$here/sbin/bbs-publish"
      stat() { if [[ ${1:-} == -c && ${2:-} == %U ]]; then echo "${ASOWNER:-}"; else command stat "$@"; fi; }
      "$@" ) >>"$log" 2>&1
}

# proc <owner> <file>: the publisher's process() on one queued file. Returns its code.
proc() { ASOWNER=$1 lib process "$2"; }
locked_proc() { LOCKW=1 proc bbs-alice "$1"; }
rc_is() { local want=$1; shift; "$@"; [[ $? -eq $want ]]; }
not_in() { ! grep -qxF -- "$1" "$2"; }

# mkwall <name> <text>: writes t/<name>.wall with the text (%b escapes), sets WF.
mkwall() { WF=$root/t/$1.wall; printf '%b' "$2" > "$WF"; }
wallcount() { find "$root/wall" -name '*.msg' | wc -l; }
wallhas()  { grep -lxF -- "$1" "$root"/wall/*.msg >/dev/null 2>&1; }
present()  { wallhas "$1"; }
absent()   { ! wallhas "$1"; }

# Menu, sourced with the test root. Output to a file; stdin from the caller.
menu_run() { # menu_run <outfile> <command...>
    local out=$1; shift
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST=1 TERM=dumb
      source "$here/lib/menu.sh"
      "$@" ) > "$out" 2>>"$log"
}
main_nav() { main_menu; echo "NAV=$nav_req"; }
line_of() { grep -nxF -- "$1" "$2" | head -n 1 | cut -d: -f1; }
before()  { local a b; a=$(line_of "$1" "$3"); b=$(line_of "$2" "$3"); [[ -n $a && -n $b ]] && (( a < b )); }
fits() { # fits <width> <file>: no line wider than width characters
    python3 -c 'import sys; w = int(sys.argv[1]); sys.exit(any(len(l.rstrip("\n")) > w for l in open(sys.argv[2], encoding="utf-8")))' "$1" "$2"
}
ns_name() { [[ $(basename "$1") =~ ^[0-9]{19}- ]]; }
ordered() { # ordered <pattern-a> <exact-line-b> <file>: a appears before b
    local a b
    a=$(grep -n -m1 -F -- "$1" "$3" | cut -d: -f1)
    b=$(grep -n -m1 -xF -- "$2" "$3" | cut -d: -f1)
    [[ -n $a && -n $b ]] && (( a < b ))
}

# ---- A. Publishing ----------------------------------------------------------
newroot
mkwall a1 'Hej alla, hur mår ni?\n'
check "bbs-alice: hälsning publiceras" lib handle_wall "$WF" bbs-alice
check "en fil i wall/" eq "$(wallcount)" 1
check "avsändaren är ägaren (alice)" grep -q '^Author: alice$' "$root"/wall/*.msg
check "texten finns som egen rad" present 'Hej alla, hur mår ni?'
check "filen är 0644" eq "$(stat -c %a "$root"/wall/*.msg)" 644
check "ingen tempfil kvar" eq "$(find "$root/wall" -name '.tmp.*' | wc -l)" 0

# ---- B. Length: 140 characters, not bytes -----------------------------------
n140=$(printf 'a%.0s' $(seq 140))
n141=$(printf 'a%.0s' $(seq 141))
a140=$(python3 -c 'print("å" * 140)')
a141=$(python3 -c 'print("å" * 141)')
mkwall len140 "$n140\n"
check "140 tecken godkänns" lib handle_wall "$WF" bbs-alice
mkwall len141 "$n141\n"
check "141 tecken avvisas" rc_is 1 proc bbs-alice "$WF"
check "141 tecken hamnar i drop/rejected" test -e "$root/drop/rejected/$(basename "$WF")"
mkwall ae140 "$a140\n"
check "140 åäö godkänns (280 byte)" lib handle_wall "$WF" bbs-alice
mkwall ae141 "$a141\n"
check "141 åäö avvisas" rc_is 1 proc bbs-alice "$WF"
check "åäö-texten sparas oförändrad" present "$a140"
check "tre filer i wall/ efter B" eq "$(wallcount)" 3

# ---- C. Control and invisible characters ------------------------------------
mkwall ctl 'ab\x1b[31mcd\r\n'
check "ESC och CR tas bort" lib handle_wall "$WF" bbs-alice
check "texten är ab[31mcd" present 'ab[31mcd'
mkwall bidi 'x\xe2\x80\xaey\n'
check "bidi-överskrivning (Cf) tas bort" lib handle_wall "$WF" bbs-alice
check "texten är xy" present 'xy'
mkwall onlyctl '\x1b\x07\n'
check "bara kontrolltecken avvisas" rc_is 1 proc bbs-alice "$WF"

# ---- D. Format rejects -------------------------------------------------------
mkwall multi 'rad ett\nrad två\n'
check "flera rader avvisas" rc_is 1 proc bbs-alice "$WF"
mkwall badutf 'a\xff\n'
check "ogiltig UTF-8 avvisas" rc_is 1 proc bbs-alice "$WF"
mkwall big "$(printf 'x%.0s' $(seq 2000))\n"
check "över 1024 byte avvisas" rc_is 1 proc bbs-alice "$WF"

# ---- E. Owner ---------------------------------------------------------------
mkwall fake 'hej från root\n'
check "ägare utanför bbs-mönstret: rc 0" rc_is 0 proc root "$WF"
check "och filen är borta ur kön" test ! -e "$WF"
check "och ingen hälsning från root" absent 'hej från root'

# ---- F. Limit 100: the 101st removes the oldest -----------------------------
newroot
for i in $(seq 1 101); do mkwall "t$i" "t$i\n"; lib handle_wall "$WF" bbs-alice; done
check "101 hälsningar: 100 kvar" eq "$(wallcount)" 100
check "äldsta (t1) är borta" absent t1
check "nästa (t2) finns kvar" present t2
check "nyaste (t101) finns kvar" present t101
check "ingen arkivkatalog skapad" test ! -e "$root/state/wall-trimmed"

# ---- G. Two publishers at once ----------------------------------------------
newroot
( for i in $(seq 1 60); do mkwall "p$i" "p$i\n"; lib handle_wall "$WF" bbs-alice; done ) &
( for i in $(seq 1 60); do mkwall "q$i" "q$i\n"; lib handle_wall "$WF" bbs-bob; done ) &
wait
check "120 samtidiga: högst 100 kvar" eq "$(wallcount)" 100
check "inga tempfiler kvar" eq "$(find "$root/wall" -name '.tmp.*' | wc -l)" 0
check "sista från alice (p60) finns" present p60
check "sista från bob (q60) finns" present q60

# ---- H. Lock held by someone else -------------------------------------------
newroot
mkwall held 'väntar på lås\n'
( exec 8>>"$root/state/wall.lock"; flock 8; sleep 3 ) &
sleep 0.5
check "låst wall: rc 2" rc_is 2 locked_proc "$WF"
check "och filen ligger kvar för nästa körning" test -e "$WF"
check "och ingen hälsning publicerad" eq "$(wallcount)" 0
wait

# ---- I. Menu: list, entry view, write, main menu ----------------------------
newroot
for i in $(seq 1 12); do mkwall "m$i" "Greeting number $i\n"; lib handle_wall "$WF" bbs-alice; done
mkwall long 'Ett långt meddelande med åäö som ska brytas snyggt på fyrtio kolumner, även om det tar plats.\n'
lib handle_wall "$WF" bbs-bob
LONGF=$(grep -l 'långt meddelande' "$root"/wall/*.msg)

for w in 40 60 80; do
    o=$scratch/wall-entry-$w.out
    menu_run "$o" wall_entry "$LONGF" "$w"
    check "vy vid $w: ingen rad bredare än $w" fits "$w" "$o"
    check "vy vid $w: texten med åäö syns" grep -q 'åäö' "$o"
    check "vy vid $w: avsändare och datum" grep -q 'av bob' "$o"
done

o1=$scratch/wall-menu-1.out
printf 'q\n' | menu_run "$o1" wall_menu
# Page 1 only: the newest (bob's long greeting), then 12 down to 4.
check "lista: nyast först (långt före 12)" ordered 'långt' 'Greeting number 12' "$o1"
check "lista: 12 före 4" before 'Greeting number 12' 'Greeting number 4' "$o1"
check "sida 1 av 2 visas" grep -q '^Page 1 of 2$' "$o1"
check "sida 1 visar 4" grep -qxF 'Greeting number 4' "$o1"
check "lista: 10 per sida (ingen 3 på sida 1)" not_in 'Greeting number 3' "$o1"

o2=$scratch/wall-menu-2.out
printf '\n\nq\n' | menu_run "$o2" wall_menu
check "Enter går till sida 2" grep -q '^Page 2 of 2$' "$o2"
check "sida 2 visar 2" grep -qxF 'Greeting number 2' "$o2"
check "sida 2 visar 1" grep -qxF 'Greeting number 1' "$o2"

o3=$scratch/wall-main.out
printf '2\n' | menu_run "$o3" main_nav
check "huvudmeny: 2) Wall" grep -qx '2) Wall' "$o3"
check "huvudmeny: 3) Users, 4) My account" grep -qx '4) My account' "$o3"
check "rubrik: [W] Wall" grep -q '\[W\] Wall' "$o3"
check "valet 2 öppnar Wall" grep -q 'NAV=wall' "$o3"
check "inga PM-rader i menyn" eq "$(grep -ci 'private\|mail' "$o3")" 0

o4=$scratch/wall-main-w.out
printf 'w\n' | menu_run "$o4" main_nav
check "bokstaven w öppnar Wall" grep -q 'NAV=wall' "$o4"

# Write: menu queues *.wall with a nanosecond name, the publisher then publishes it.
o5=$scratch/wall-write.out
printf 'Hej från menyn\n\n' | menu_run "$o5" wall_write
WQ=$(ls "$root"/queue/incoming/*.wall 2>/dev/null | head -n 1)
check "skriv: en *.wall i kön" test -n "$WQ"
check "kön: namn med nanosekunder" ns_name "$WQ"
check "kön: texten som skrevs" grep -qxF 'Hej från menyn' "$WQ"
check "publiceras från kön" rc_is 0 proc bbs-alice "$WQ"
check "hälsningen syns i wall/" present 'Hej från menyn'

printf '%s\n\n' "$(python3 -c 'print("å" * 141)')" | menu_run "$o5" wall_write
check "skriv: 141 tecken köas inte" eq "$(ls "$root"/queue/incoming/*.wall 2>/dev/null | wc -l)" 0

o6=$scratch/wall-top.out
menu_run "$o6" top_bar ""
check "rubriken: [W] Wall" grep -q '\[W\] Wall' "$o6"

echo "SUMMARY pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
