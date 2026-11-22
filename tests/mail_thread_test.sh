#!/bin/bash
# Threaded Inbox: one row per thread (Sent replies, fido X-Fido-Reply, subject fallback), newest
# first, * for unread, dates, thread view keys (Space/N/P/#), "you (sent)" without R, new -> cur,
# A/D back to the list, no ESC from a subject. Temporary BBS_ROOT and HOME; keys go through a fifo.
# Usage: tests/mail_thread_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/mail_thread_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/mailthr.XXXXXX")
trap 'exec 7>&- 2>/dev/null; kill $menu_pid 2>/dev/null; rm -rf "$root"' EXIT
mkdir -p "$root"/{state,queue/xfer,users/alice,home/Maildir/{cur,new,tmp,.Sent/cur,.Sent/new,.Trash/cur,.Archive/cur}}
H=$root/home/Maildir
printf 'name=Alice\n' > "$root/users/alice/profile"
# msg <file> <from> <to> <subject> <date> [extra header lines...]
msg() { local f=$1 from=$2 to=$3 subj=$4 date=$5; shift 5
    { printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\n' "$from" "$to" "$subj" "$date"
      (( $# )) && printf '%s\n' "$@"
      printf '\nbody of %s\n' "$(basename "$f")"; } > "$f"; }
D=$(date -u -R)
K=kitty@bbs.localdomain; A=alice@bbs.localdomain
# A -> you -> A through Sent; the last one is unread
msg "$H/cur/1700000100.a:2,S"       $K $A "Middag?"    "$D" "Message-ID: <a1@h>"
msg "$H/.Sent/cur/1700000200.b:2,S" $A $K "Re: Middag?" "$D" "Message-ID: <b1@h>" "In-Reply-To: <a1@h>"
msg "$H/new/1700000300.c"           $K $A "Re: Middag?" "$D" "Message-ID: <c1@h>" "In-Reply-To: <b1@h>"
# fido reply with a different subject; To is a bare name
msg "$H/cur/1700001000.f1:2,S" "Jane Doe@21:3/100" alice "Echo" "$D" "X-Fido-Msgid: 21:3/100 aaaa1111"
msg "$H/cur/1700001100.f2:2,S" "Jane Doe@21:3/100" alice "Hej"  "$D" "X-Fido-Msgid: 21:3/100 aaaa2222" "X-Fido-Reply: 21:3/100 aaaa1111"
# subject fallback: bob's two, carol's same subject stays apart
msg "$H/cur/1700002000.s1:2,S" bob@bbs.localdomain   $A "Lunch"     "$D"
msg "$H/cur/1700002100.s2:2,S" bob@bbs.localdomain   $A "SV: Lunch" "$D"
msg "$H/cur/1700002200.s3:2,S" carol@bbs.localdomain $A "Lunch"     "$D"
# no epoch in the name: the date comes from the Date header
msg "$H/cur/olddate:2,S" dave@bbs.localdomain $A "Old one" "Mon, 02 Nov 2020 10:00:00 +0000"
# ESC in the subject
msg "$H/cur/1700003000.e1:2,S" erin@bbs.localdomain $A $'Esc\e[31mred' "$D"

fifo=$root/keys; mkfifo "$fifo"; out=$root/screen; menu_pid=; mk=0
start() { : > "$out"; mk=0; exec 7<>"$fifo"
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100 XFER_POLL=0.1 BBS_MAILEXPORT="$here/lib/mailexport.py"
      source "$here/lib/menu.sh"; mail_menu; echo END ) <"$fifo" >"$out" 2>&1 7>&- &
    menu_pid=$!; }
keys() { printf '%s' "$1" >&7; }
mark() { sleep 0.4; mk=$(stat -c %s "$out"); }                  # later checks look only after this
new() { tail -c +"$((mk + 1))" "$out"; }
seen() { local i; for (( i = 0; i < 50; i++ )); do new | grep -qE -- "$1" && return 0; sleep 0.1; done; return 1; }
unseen() { sleep 0.4; ! new | grep -qE -- "$1"; }
finish() { exec 7>&-; local i; for (( i = 0; i < 50; i++ )); do kill -0 "$menu_pid" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
gone() { ! compgen -G "$1" >/dev/null; }
here_() { compgen -G "$1" >/dev/null; }
md() { date -d "@$1" +'%m-%d %H:%M'; }
ymd() { date -d "@$1" +'%Y-%m-%d %H:%M'; }

# The list. Newest first: 1 Esc, 2 Lunch carol, 3 Lunch bob (2), 4 Echo (2), 5 Middag (3), 6 Old one.
start
keys 1
check "list: Esc row first"     seen '1\) +.*erin +Esc'
check "list: no ESC byte"       unseen $'\e\\[31m'
check "list: carol Lunch alone" seen "2\) +$(md 1700002200) +carol +Lunch +\(1\)"
check "list: bob Lunch (2)"     seen "3\) +$(md 1700002100) +bob +Lunch +\(2\)"
check "list: fido (2)"          seen "4\) +$(md 1700001100) +Jane Do.* +(Hej|Echo) +\(2\)"
check "list: Middag (3), new *" seen "5\) \* +$(md 1700000300) +kitty +Middag\? +\(3\)"
check "list: Date header row"   seen "6\) +$(date -d 'Mon, 02 Nov 2020 10:00:00 +0000' +'%m-%d %H:%M') +dave +Old one"
check "list: read rows no *"    unseen "[1-4]\) \*"
check "list: no Sent row"       unseen '7\)'

# Thread 5 opens at its first unread mail (#3): Space/N/P/#, you (sent), no R on Sent, new -> cur.
mark; keys 5
check "thread: opens at unread #3/3" seen "#3/3 +kitty +$(ymd 1700000300) +· reply to #2"
check "thread: nav line"        seen '\[Space\] Next +P\) Prev +#\) Go to'
check "thread: R on received"   seen 'R\) '
check "thread: read moved to cur" here_ "$H/cur/1700000300.c*"
check "thread: gone from new"   gone "$H/new/1700000300.c"
mark; keys p
check "thread: P, #2/3 you (sent)" seen "#2/3 +you \(sent\) +$(ymd 1700000200) +· reply to #1"
check "thread: Sent has A/D"    seen 'A\) Archive.*D\) Delete'
check "thread: Sent has no R"   unseen 'R\) '
mark; keys p
check "thread: P, #1/3 header"  seen "#1/3 +kitty +$(ymd 1700000100)"
mark; keys ' '
check "thread: Space is next"   seen '#2/3 +you \(sent\)'
mark; keys '#'; keys 3; keys $'\n'
check "thread: # goes to #3"    seen '#3/3 +kitty'
mark; keys n
check "thread: N at the last mail goes to the list" seen '5\) +'"$(md 1700000300)"' +kitty +Middag\? +\(3\)'
check "list: * cleared"         unseen '5\) \*'
mark; keys 4
check "fido thread: 2 messages" seen '#1/2 +Jane Doe'
mark; keys ' '
check "fido: reply to #1"       seen '#2/2 .*reply to #1'
keys q
mark; keys 2
check "single: no nav line"     unseen 'Go to'
keys q

# A and D from a thread return to the rebuilt list.
mark; keys 3; seen '#1/2 +bob' >/dev/null
keys a
check "A: archived"             seen 'Archived\.'
check "A: file in .Archive"     here_ "$H/.Archive/cur/1700002000.s1*"
mark; keys x          # any key
check "A: list rebuilt, Lunch now alone" seen '3\) +.*bob +SV: Lunch +\(1\)'
mark; keys 3; seen '#1/1|bob' >/dev/null
keys d; keys y
check "D: moved to Trash"       seen 'Moved to Trash\.'
check "D: file in .Trash"       here_ "$H/.Trash/cur/1700002100.s2*"
mark; keys x          # any key
check "D: back in the list"     seen '1\) +.*erin'
keys q; keys q; finish
echo "mail_thread_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
