#!/bin/bash
# Tests for Fame & Glory: the activity log written by sbin/bbs-publish (activity_add,
# activity_backfill), Most Active, BBS Records, and the menu helpers menu_item,
# board_desc and board_order in lib/menu.sh. Own BBS_ROOT per run.
# Usage: tests/fame_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/fame_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }

root=$(mktemp -d "$scratch/fame.XXXXXX")
home=$root/home; mkdir -p "$home"
mkdir -p "$root"/{queue/incoming,state,drop/rejected,wall,lib,meta,users} "$root"/boards/{general,pub,secret,news}
cp "$here/lib/news-categories.conf" "$root/lib/"
AL=$root/state/activity.log

# Publisher functions in a subshell. Private boards are faked: meta/<b>.meta marks them,
# group and membership checks are stubbed.
lib() { ( export BBS_ROOT="$root" BBS_LOCK_WAIT=2 BASHBBS_TEST=1
          source "$here/sbin/bbs-publish"
          in_group() { return 0; }
          chgrp() { return 0; }
          "$@" ) >>"$log" 2>&1; }
# Menu functions; list_width and board_is_private are stubbed (no tty, no groups).
W=80
menu_run() { local out=$1; shift
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=dumb HOME="$home"
      source "$here/lib/menu.sh"
      list_width() { echo "$W"; }
      board_is_private() { [[ -f $BBS_ROOT/meta/$(basename "$1").meta ]]; }
      pause() { :; }
      "$@" ) > "$out" 2>>"$log"; }
mkpost() { # mkpost <file> <board> <subject>
    printf 'Board: %s\nSubject: %s\n\nbody\n' "$2" "$3" > "$1"; }
mkmsg() { # mkmsg <file> <author> <date> [deleted]
    { printf 'Msgid: x\nAuthor: %s\nNode: n\nDate: %s\nSubject: s\n' "$2" "$3"
      [[ -n ${4:-} ]] && printf 'Deleted: %s\n' "$3"; printf '\nbody\n'; } > "$1"; }
fits() { python3 -c 'import sys; w=int(sys.argv[1]); sys.exit(any(len(l.rstrip("\n"))>w for l in open(sys.argv[2],encoding="utf-8")))' "$1" "$2"; }
today=$(date -u +%F)
touch "$root/meta/secret.meta"

# 1. activity_add: public post, wall, call.
mkpost "$root/p1" general "Hello"
check "public post accepted" lib handle_post "$root/p1" bbs-alice
check "post logged as 'DATE post alice'" grep -qx "$today post alice" "$AL"
printf 'hi there\n' > "$root/w1.wall"
check "wall accepted" lib handle_wall "$root/w1.wall" bbs-bob
check "wall logged" grep -qx "$today wall bob" "$AL"
check "activity_add call" lib activity_add call bbs-carol
check "call logged without bbs- prefix" grep -qx "$today call carol" "$AL"
check "log world readable" eq "$(stat -c %a "$AL")" 644

# 2. Private board post and the news author stay out.
n0=$(wc -l < "$AL")
mkpost "$root/p2" secret "Secret"
check "private post accepted" lib handle_post "$root/p2" bbs-alice
check "private post not logged" eq "$(wc -l < "$AL")" "$n0"
mkpost "$root/p3" news "News"
lib handle_post "$root/p3" bbs-news
mkpost "$root/p4" pub "By newsstatus"
lib handle_post "$root/p4" bbs-newsstatus
check "news / newsstatus accounts not logged" not grep -Eq ' (news|newsstatus)$' "$AL"
mkpost "$root/p5" news "Human on news"
lib handle_post "$root/p5" bbs-alice
check "post on the news board not logged" eq "$(grep -c "post alice" "$AL")" 1

# 3. Backfill: from posts on disk, once.
rm -f "$AL"; rm -f "$root"/boards/*/*.msg "$root"/wall/*.msg
mkmsg "$root/boards/general/1-a.msg" alice 2026-10-01T10:00:00Z
mkmsg "$root/boards/general/2-b.msg" bob 2026-10-02T10:00:00Z
mkmsg "$root/boards/general/3-c.msg" carol 2026-10-03T10:00:00Z deleted
mkmsg "$root/boards/secret/4-d.msg" dave 2026-10-04T10:00:00Z
mkmsg "$root/boards/news/5-e.msg" news 2026-10-05T10:00:00Z
mkmsg "$root/boards/pub/6-f.msg" newsstatus 2026-10-06T10:00:00Z
mkmsg "$root/wall/7-g.msg" erin 2026-10-07T10:00:00Z
printf '2026-10-08T12:00Z frank\n' > "$root/state/callers.log"
check "backfill runs" lib activity_backfill
check "backfill: public post" grep -qx '2026-10-01 post alice' "$AL"
check "backfill: second post" grep -qx '2026-10-02 post bob' "$AL"
check "backfill: wall" grep -qx '2026-10-07 wall erin' "$AL"
check "backfill: call from callers.log" grep -qx '2026-10-08 call frank' "$AL"
check "backfill: deleted post skipped" not grep -q carol "$AL"
check "backfill: private board skipped" not grep -q dave "$AL"
check "backfill: news and newsstatus skipped" not grep -Eq ' (news|newsstatus)$' "$AL"
check "backfill: 4 lines" eq "$(wc -l < "$AL")" 4
echo "2026-01-01 post keep" > "$AL"
lib activity_backfill
check "backfill not rerun when the log exists" eq "$(cat "$AL")" "2026-01-01 post keep"

# 4. Most Active: order, hidden, cap at 10.
: > "$AL"
for i in 1 2 3; do echo "2026-10-01 post zed"; done >> "$AL"
for i in 1 2 3; do echo "2026-10-01 wall amy"; done >> "$AL"
echo "2026-10-01 post bob" >> "$AL"
for i in 1 2 3 4 5; do echo "2026-10-01 post ghost"; done >> "$AL"
echo "2026-10-01 call callonly" >> "$AL"
mkdir -p "$root/users/ghost"; echo "hidden=yes" > "$root/users/ghost/profile"
menu_run "$root/ma.txt" most_active_view
check "most active: hidden user excluded" not grep -q ghost "$root/ma.txt"
check "most active: call-only user not listed" not grep -q callonly "$root/ma.txt"
check "most active: ties by name (amy before zed), bob last" eq "$(grep -E '^ +[0-9]+  ' "$root/ma.txt" | awk '{print $2}' | tr '\n' ' ')" "amy zed bob "
check "most active: counts" grep -Eq '^ +3  amy$' "$root/ma.txt"
: > "$AL"
for i in $(seq 1 14); do for j in $(seq 1 "$i"); do echo "2026-10-01 post u$(printf %02d "$i")"; done; done >> "$AL"
menu_run "$root/mb.txt" most_active_view
check "most active: capped at 10" eq "$(grep -cE '^ +[0-9]+  u' "$root/mb.txt")" 10
check "most active: busiest first" eq "$(grep -m1 -E '^ +[0-9]+  u' "$root/mb.txt" | awk '{print $2}')" u14
check "most active: 11th not shown" not grep -q 'u04$' "$root/mb.txt"
: > "$AL"
menu_run "$root/mc.txt" most_active_view
check "most active: empty log says Nobody yet." grep -qx 'Nobody yet.' "$root/mc.txt"

# 5. Records.
cat > "$AL" <<'L'
2026-10-05 call a
2026-10-05 call b
2026-10-03 call c
2026-10-03 call d
2026-10-09 call e
2026-10-07 post a
2026-10-02 wall b
2026-10-02 post c
2026-10-07 post d
L
echo 42 > "$root/state/callers.total"
menu_run "$root/r1.txt" records_view
check "records: calls tie -> earliest date" grep -Eq '^Most calls in a day +2 on 2026-10-03$' "$root/r1.txt"
check "records: posts (wall counts) tie -> earliest date" grep -Eq '^Most posts in a day +2 on 2026-10-02$' "$root/r1.txt"
check "records: total calls" grep -Eq '^Total calls +42$' "$root/r1.txt"
: > "$AL"; rm -f "$root/state/callers.total"
menu_run "$root/r2.txt" records_view
check "records: empty log shows -" grep -Eq '^Most calls in a day +-$' "$root/r2.txt"
check "records: empty log posts -" grep -Eq '^Most posts in a day +-$' "$root/r2.txt"
check "records: no total file -> 0" grep -Eq '^Total calls +0$' "$root/r2.txt"

# 6. menu_item widths.
D="A description that is rather long and will not fit in sixty columns at all."
W=40; menu_run "$root/i40.txt" menu_item 1 Boards "$D" "(3 unread)"
check "menu_item 40 cols: label only" grep -qx '1) Boards (3 unread)' "$root/i40.txt"
check "menu_item 40 cols: no description" not grep -q 'description' "$root/i40.txt"
W=80; menu_run "$root/i80.txt" menu_item 1 Boards "Short text."
check "menu_item 80 cols: label, dash, description" grep -qx '1) Boards             - Short text.' "$root/i80.txt"
W=60; menu_run "$root/i60.txt" menu_item 1 Boards "$D" "(3 unread)"
check "menu_item 60 cols: line fits" fits 60 "$root/i60.txt"
check "menu_item 60 cols: truncated with ..." grep -q '\.\.\. (3 unread)$' "$root/i60.txt"
W=60; menu_run "$root/i60b.txt" menu_item 2 Wall "$D"
check "menu_item 60 cols no suffix: fits" fits 60 "$root/i60b.txt"
W=80; menu_run "$root/i80n.txt" menu_item 3 News
check "menu_item without description: label only" grep -qx '3) News' "$root/i80n.txt"

# 7. board_desc cleans control characters, takes the first line only.
printf 'Nice\033[31m board\a\r\nsecond line\n' > "$root/boards/pub/.desc"
menu_run "$root/d1.txt" board_desc pub
check "board_desc: control characters removed" not grep -qP '[\x00-\x08\x0b-\x1f\x7f]' "$root/d1.txt"
check "board_desc: first line only" not grep -q second "$root/d1.txt"
check "board_desc: text kept" grep -q 'Nice' "$root/d1.txt"
menu_run "$root/d2.txt" board_desc secret
check "board_desc: private without .desc gets the standard text" grep -q 'private board for invited members' "$root/d2.txt"
menu_run "$root/d3.txt" board_desc general
check "board_desc: public without .desc is empty" eq "$(wc -c < "$root/d3.txt")" 0

# 8. board_order.
mkdir -p "$root"/boards/{sharednews,whatsup,zeta,alpha,mid}
touch "$root/meta/mid.meta"
bo_in() { local order; board_order "$1" order; echo "${order[*]}"; }
bo() { menu_run "$root/bo.txt" bo_in "$1"; tr -d '\n' < "$root/bo.txt"; }
check "board_order public: fixed three, then alphabetical, no news, no private" eq "$(bo public)" "general sharednews whatsup alpha pub zeta"
check "board_order private" eq "$(bo private)" "mid secret"

# 9. A private board the user cannot read (no group access) is hidden. The real group
# check is a filesystem permission, so chmod 000 stands in for "not in bbsb-<name>".
# (Running as root would ignore the mode bits, so then this part is skipped.)
if [[ $(id -u) != 0 ]]; then
    chmod 000 "$root/boards/secret"
    check "board_order private: unreadable board is not listed" eq "$(bo private)" "mid"
    check "board_order public: unreadable board is not listed either" eq "$(bo public)" "general sharednews whatsup alpha pub zeta"
    chmod 000 "$root/boards/mid"
    check "board_order private: empty when no private board is readable" eq "$(bo private)" ""
    plist() { redraw() { :; }; menu_key() { MKEY=q; return 0; }; board_menu private; }
    menu_run "$root/pl.txt" plist
    check "private list: empty list says it" grep -q 'You are not in any private boards yet\.' "$root/pl.txt"
    check "private list: unreadable board names are not shown" not grep -qE 'secret|mid' "$root/pl.txt"
    chmod 755 "$root/boards/mid"
    menu_run "$root/pl2.txt" plist
    check "private list: a readable board shows, the empty text does not" not grep -q 'not in any private boards' "$root/pl2.txt"
    check "private list: only the readable board is shown" not grep -q 'secret' "$root/pl2.txt"
    chmod 755 "$root/boards/secret"
else
    echo "skip: running as root, mode bits are ignored (hidden private boards not tested)" >>"$log"
fi

echo "fame_test: $pass passed, $fail failed (log: $log)"
exit $(( fail > 0 ))
