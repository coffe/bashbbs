#!/bin/bash
# Width sweep: every main screen at 40, 60 and 80 columns with COLOR=0 and COLOR=1. The
# longest visible line (ESC sequences removed) must not exceed the width. Also: with
# COLOR=0 no screen carries an ESC except the clear-screen sequence.
# Screens run with stdin at EOF (they return at once); term_width is forced to the width.
# Usage: tests/width_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/width_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }

root=$(mktemp -d "$scratch/width.XXXXXX")
home=$root/home
mkdir -p "$root"/{boards/general,boards/news/ai,meta,state,wall,queue/incoming} "$home"/Maildir/{new,cur,tmp}
: > "$root/meta/news.sections"
long="A very long subject line that has to wrap or be cut at forty columns without ever overflowing åäö"
printf 'Msgid: r1\nAuthor: bobbie\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: %s\n\n%s %s\n' "$long" "$long" "$long" > "$root/boards/general/1500000010-r1.msg"
printf 'Msgid: a1\nAuthor: carolina\nNode: n\nDate: 2017-07-14T05:00:00+00:00\nSubject: Re: x\nParent: r1\n\nreply %s\n' "$long" > "$root/boards/general/1500000020-a1.msg"
printf 'From: bertil@bbs.localdomain\nDate: Sat, 14 Jul 2017 04:00:00 +0000\nSubject: %s\n\nbody %s\n' "$long" "$long" > "$home/Maildir/new/1700000000.w1.host"
printf 'From: cissi@bbs.localdomain\nSubject: Short\n\nhi\n' > "$home/Maildir/cur/1700000001.w2.host"
printf 'Author: bobbie\nDate: 2017-07-14T04:00:00+00:00\n\nWall text %s\n' "$long" > "$root/wall/1500000010-w1.msg"
printf 'Board: news\nSubject: %s\nMsgid: 00000000-0000-4000-8000-000000001001\nAuthor: news\nNode: t\nDate: 2026-11-01T10:00:00Z\nCategory: ai\nArticle-Id: %s\nSource: Wire Service\nPublished: 2026-11-01T10:00:00Z\nLink: https://example.org/a\n\nBody %s\n' \
    "$long" "$(printf 'a%.0s' {1..64})" "$long $long" > "$root/boards/news/ai/1793000000-00000000-0000-4000-8000-000000001001.msg"
env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-wtest bash -c 'source "$1"; news_rebuild_index "$BBS_ROOT"' x "$here/lib/menu.sh" >>"$log" 2>&1

# screen <cols> <color> <code>: the screen text on stdout
screen() {
    env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-wtest BASHBBS_COLOR="$2" TERM=xterm \
        BBS_COLS="$1" BASHBBS_SEEN_PREV=1500000005 W="$1" \
        bash -c 'source "$1"; term_width() { echo "$W"; }; list_width() { echo "$W"; }; shift; eval "$1"' x "$here/lib/menu.sh" "$3" </dev/null 2>/dev/null
}
maxw() { python3 -I -c '
import re, sys, unicodedata
t = sys.stdin.read()
t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", t).replace("\r", "")
def w(s): return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
print(max((w(l) for l in t.split("\n")), default=0))'; }
fits() { local out; out=$(screen "$1" "$2" "$3" | maxw); [[ $out =~ ^[0-9]+$ ]] && (( out > 0 && out <= $1 )); }
plain_ok() { ! screen "$1" 0 "$2" | sed 's/\x1b\[[0-9;?]*[HJ]//g' | grep -q $'\033'; }

f1=$(ls "$root"/boards/general/*r1.msg); mfile=$(ls "$home"/Maildir/new/*)
declare -A screens=(
  [main menu]='main_menu'
  [boards list]='board_menu'
  [thread list]='board_view general'
  [thread view]="thread_view general $f1"
  [inbox]='mail_view Inbox'
  [mail menu]='mail_menu'
  [mail read]="mail_open Inbox $mfile"
  [news sections]='news_board'
  [news list]='news_load_index; ctx=("${NEWS_ORDER[@]}"); news_list ctx all'
  [news article]='news_load_index; ctx=("${NEWS_ORDER[@]}"); news_read ctx 0'
  [wall]='wall_menu'
)
for name in "${!screens[@]}"; do
    for w in 40 60 80; do
        for c in 0 1; do
            check "$name @$w color=$c: widest line <= $w" fits "$w" "$c" "${screens[$name]}"
        done
        check "$name @$w color=0: no ESC but clear" plain_ok "$w" "${screens[$name]}"
    done
done
echo "width_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
