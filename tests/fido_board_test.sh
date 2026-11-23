#!/bin/bash
# Fido boards (meta/<board>.fido): everyone posts with a day limit (sysops unlimited), no edits, delete keeps the file
# name, fido=off hides the board, imported posts display. Own BBS_ROOT under the scratchpad.
# Usage: tests/fido_board_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/d1734d7a-ba5d-4ad7-aeee-cb0f3089f2e5/scratchpad}
log=${1:-$scratch/fido_board_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
hval() { sed '/^$/q' "$1" | sed -n "s/^$2: *//p" | head -n 1; }

root=$(mktemp -d "$scratch/fido.XXXXXX")
mkdir -p "$root"/{boards/general,boards/fsx_gen,meta,queue/incoming,state,drop/rejected,lib,t,home}
cp "$here/lib/news-categories.conf" "$root/lib/"
: > "$root/meta/fsx_gen.fido"
printf 'carol\n' > "$root/sysops"

lib() {
    ( export BBS_ROOT="$root" BBS_LOCK_WAIT=2
      source "$here/sbin/bbs-publish"
      in_group() { return 1; }
      chgrp() { return 0; }
      "$@" ) >>"$log" 2>&1
}
mkreq() { printf 'Board: %s\nSubject: S\n\nbody\n' "$1" > "$root/t/$2"; }

mkreq fsx_gen a.post; mkreq fsx_gen b.post; mkreq general c.post
lib handle_post "$root/t/a.post" bbs-alice; rc=$?
check "user post on fido board accepted" eq "$rc" 0
for i in 2 3 4 5 6 7 8 9 10; do mkreq fsx_gen a$i.post; lib handle_post "$root/t/a$i.post" bbs-alice; done
check "ten posts in a day" eq "$(ls "$root"/boards/fsx_gen | wc -l)" 10
mkreq fsx_gen a11.post; lib handle_post "$root/t/a11.post" bbs-alice; rc=$?
check "eleventh post the same day rejected" eq "$rc" 1
check "no file after rejection" eq "$(ls "$root"/boards/fsx_gen | wc -l)" 10
for i in 1 2 3 4 5 6 7 8 9 10; do echo "$(date -u +%F) carol"; done >> "$root/state/fido/echo-day.log"
lib handle_post "$root/t/b.post" bbs-carol; rc=$?
check "sysop not limited" eq "$rc" 0
F=$(grep -l '^Author: carol$' "$root"/boards/fsx_gen/*.msg | head -1)
id=$(hval "$F" Msgid)
lib handle_post "$root/t/c.post" bbs-alice
check "normal board still takes users" eq "$(ls "$root"/boards/general | wc -l)" 1

printf 'Action: edit-post\nBoard: fsx_gen\nMsgid: %s\nSubject: New\n\nnew body\n' "$id" > "$root/t/e.req"
lib change_post edit-post "$root/t/e.req" bbs-carol fsx_gen "$id"; rc=$?
check "edit on fido board rejected for the author" eq "$rc" 1
check "post unchanged" eq "$(hval "$F" Subject)" S

printf 'Action: delete-post\nBoard: fsx_gen\nMsgid: %s\n\n' "$id" > "$root/t/d.req"
lib change_post delete-post "$root/t/d.req" bbs-carol fsx_gen "$id"; rc=$?
check "sysop delete works" eq "$rc" 0
check "delete keeps the file name" test -f "$F"
check "post is a stub" eq "$(hval "$F" Subject)" "[deleted]"

# imported-style post
cat > "$root/boards/fsx_gen/1700000000-11111111-2222-3333-4444-555555555555.msg" <<'M'
Msgid: 11111111-2222-3333-4444-555555555555
Author: Some Name@fsx
Node: 21:1/101
Date: 2026-11-18T10:00:00Z
Subject: Hello fsx
Fido-Msgid: 21:1/101 1a2b3c4d

Imported body line
M
t() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice
        source "$here/lib/menu.sh"; set +e +u 2>/dev/null; "$@" ); }
out=$(t show_post "$root/boards/fsx_gen/1700000000-11111111-2222-3333-4444-555555555555.msg" 60)
check "imported body shown" grep -q 'Imported body line' <<<"$out"
check "Fido-Msgid not shown as body" bash -c '! grep -q "Fido-Msgid" <<<"$1"' _ "$out"
check "author header read" eq "$(t post_hdr "$root/boards/fsx_gen/1700000000-11111111-2222-3333-4444-555555555555.msg" Author)" "Some Name@fsx"

# echo posts left today: counted from the user's own posts on fido boards
check "echo_left: ten posts today leaves 0" eq "$(t echo_left)" 0
out=$(t eval 'pause() { :; }; compose fsx_gen "" </dev/null' 2>&1)
check "compose at the limit says so" grep -q "used today's 10 echo posts" <<<"$out"
check "compose at the limit queues nothing" eq "$(ls "$root/queue/incoming" | wc -l)" 0
old=$(grep -l '^Author: alice$' "$root"/boards/fsx_gen/*.msg | head -1)
mv "$old" "$root/boards/fsx_gen/$(( $(date -u -d "$(date -u +%F) 00:00" +%s) - 10 ))-${old##*/[0-9]*-}"
check "echo_left: a post from yesterday does not count" eq "$(t echo_left)" 1
check "echo_left: sysop has no limit" bash -c '! ( export BBS_ROOT="$1" HOME="$1/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-carol; source "$2/lib/menu.sh"; set +e +u; echo_left )' _ "$root" "$here"
out=$(t board_view fsx_gen </dev/null 2>&1)
check "board view shows the counter" grep -q "1 of 10 echo posts left today" <<<"$out"

# a long echo pages: 59 threads do not all land on one 24-row screen; Space shows the next page
mkdir -p "$root/boards/fsx_ads"; : > "$root/meta/fsx_ads.fido"
for (( i = 10; i < 69; i++ )); do
    printf 'Msgid: 111111%02d-2222-3333-4444-555555555555\nAuthor: Ad@fsx\nDate: 2026-11-18T10:00:00Z\nSubject: Ad number %d\n\nbody\n' \
        "$i" "$i" > "$root/boards/fsx_ads/17000000$i-111111$i-2222-3333-4444-555555555555.msg"
done
out=$(printf ' q' | TERM_SIZE="24 80" t board_view fsx_ads 2>&1)
first=${out%%Space) More*}
check "long echo: first page starts at 1" grep -q '^ *1) ' <<<"$first"
check "long echo: first page fits 24 rows" bash -c '! grep -q "^ *1[0-9]) " <<<"$1"' _ "$first"
check "long echo: Space) More offered" grep -q 'Space) More' <<<"$out"
check "long echo: Space shows the next page" bash -c 'n=$(grep -o "^ *[0-9]*) " <<<"$1" | tr -d " )" | sort -n | tail -1); (( n > 7 && n < 59 ))' _ "$out"
rm -rf "$root/boards/fsx_ads" "$root/meta/fsx_ads.fido"

# netmail in the inbox: the fido address stays in From, a local sender is cut at @
printf 'Message-ID: <a@fido>\nDate: Wed, 18 Nov 2026 08:05:09 -0000\nFrom: Jane@21:99/1\nTo: alice\nSubject: Hej\nX-Fido-Msgid: 21:99/1 abc\n\nnetmail body\n' > "$root/t/nm"
sed 's/^From: .*/From: kitty@bbs.example/' "$root/t/nm" > "$root/t/pm"
check "show_post: netmail sender keeps address" grep -q 'by Jane@21:99/1' <<<"$(t show_post "$root/t/nm" 60)"
check "show_post: local sender cut at @" bash -c 'grep -q "by kitty," <<<"$1" && ! grep -q "bbs.example" <<<"$1"' _ "$(t show_post "$root/t/pm" 60)"
mr() { pause() { :; }; mail_write() { echo "WRITE $*"; }; mail_reply "$1"; }
check "mail_reply: netmail prefills the address and REPLY" grep -q '^WRITE Jane@21:99/1 Re: Hej 21:99/1 abc$' <<<"$(t mr "$root/t/nm" 2>&1)"

# netmail out (bbs-publish): owner is the author, checks again, 10 a day, sysop unlimited
nmo=$root/state/fido/netmail/out
mknet() { printf 'Author: carol\nTo-Name: %s\nTo-Addr: %s\nSubject: Hej\n\nbody\n' "$2" "$3" > "$root/t/$1"; }
mknet n0.net Jane 21:99/1
lib handle_netmail "$root/t/n0.net" bbs-alice; rc=$?
N=$(ls "$nmo"/*.msg 2>/dev/null | head -1)
check "netmail accepted (rc)" eq "$rc" 0
check "netmail forged Author -> owner" bash -c '[[ $(sed -n "s/^Author: //p" "$1") == alice ]] && [[ $(grep -c "^Author:" "$1") == 1 ]]' _ "$N"
check "netmail out file root-only" eq "$(stat -c %a "$N")" 600
mknet bad.net Jane 21:1
lib handle_netmail "$root/t/bad.net" bbs-alice; rc=$?
check "netmail bad address rejected" eq "$rc" 1
for i in 1 2 3 4 5 6 7 8 9; do mknet n$i.net Jane 21:99/1; lib handle_netmail "$root/t/n$i.net" bbs-alice; done
check "netmail 10 a day accepted" eq "$(ls "$nmo" | wc -l)" 10
mknet n10.net Jane 21:99/1
lib handle_netmail "$root/t/n10.net" bbs-alice; rc=$?
check "netmail 11th the same day rejected" eq "$rc" 1
for i in 1 2 3 4 5 6 7 8 9 10 11; do printf '%s carol\n' "$(date -u +%F)"; done >> "$root/state/fido/netmail/day.log"
lib handle_netmail "$root/t/n10.net" bbs-carol; rc=$?
check "netmail sysop not limited" eq "$rc" 0
check "mail_reply: local reply unchanged" grep -q '^WRITE kitty Re: Hej <a@fido>' <<<"$(t mr "$root/t/pm" 2>&1)"

# ANSI ad: A) ANSI shows the original from published/<id> (CP437, colour), gone -> message
mkdir -p "$root/published"
pa() { menu_key() { return 1; }; n=1; me=bbs-alice; post_actions fsx_gen "$1"; }
va() { pause() { :; }; view_ansi "$1"; }
printf '\033[2J\033[H\033[1;31m\xdb\033[0m ad\r\n' > "$root/published/1700000000-deadbeef"
P=$root/boards/fsx_gen/1700000001-ad.msg
printf 'Msgid: m-ad\nAuthor: X@fsx\nDate: 2026-11-18T10:00:00Z\nSubject: Ad\nAnsi: 1700000000-deadbeef\n\nad text\n' > "$P"
keys_out=$(BASHBBS_COLOR=0 t pa "$P" 2>&1)
check "A) ANSI offered" grep -q 'A) ANSI' <<<"$keys_out"
v=$(BASHBBS_COLOR=1 t va 1700000000-deadbeef 2>&1)
check "view_ansi: CP437 block and colour" bash -c '[[ $1 == *$'"'"'\e[0;1;31m█\e[0m ad'"'"'* ]]' _ "$v"
v=$(t va 1700000000-00000000 2>&1)
check "view_ansi: expired file gives a message" grep -q 'gone' <<<"$v"
sed -i 's/^Ansi: .*/Ansi: ..\/etc/' "$P"
keys_out=$(BASHBBS_COLOR=0 t pa "$P" 2>&1)
check "bad Ansi id: no key" bash -c '! grep -q "A) ANSI" <<<"$1"' _ "$keys_out"

# ANSI netmail: A) ANSI draws the base64 original in X-Fido-Ansi; S) Save archives, as A did
ma() { menu_key() { return 1; }; me=bbs-alice; mail_actions Inbox "$1"; }
vm() { pause() { :; }; view_ansi_mail "$1"; }
M=$root/t/ansi-mail
printf 'From: Ann@21:99/1\nTo: alice\nSubject: Art\nX-Fido-Ansi: %s\n\nRED\n' \
    "$(printf '\033[1;31m\xdb\033[0m RED\r\n' | base64 -w0)" > "$M"
keys_out=$(BASHBBS_COLOR=0 t ma "$M" 2>&1)
check "mail: A) ANSI offered" grep -q 'A) ANSI' <<<"$keys_out"
check "mail: S) Save, no A) Archive" bash -c 'grep -q "S) Save" <<<"$1" && ! grep -q "A) Archive" <<<"$1"' _ "$keys_out"
v=$(BASHBBS_COLOR=1 t vm "$M" 2>&1)
check "view_ansi_mail: CP437 block and colour" bash -c '[[ $1 == *$'"'"'\e[0;1;31m█\e[0m RED'"'"'* ]]' _ "$v"
sed -i '/^X-Fido-Ansi/d' "$M"
keys_out=$(BASHBBS_COLOR=0 t ma "$M" 2>&1)
check "mail without original: no A) ANSI" bash -c '! grep -q "A) ANSI" <<<"$1"' _ "$keys_out"

# fido switch (real features file)
ord() { source "$here/lib/features.sh"; features_load; board_order "$1" res; echo "${res[*]}"; }
order() { t ord "$1"; }
printf 'fido=off\n' > "$root/features"
check "fido=off: not in Public" bash -c '[[ $1 != *fsx_gen* ]]' _ "$(order public)"
check "fido=off: no fsxNet list" eq "" "$(order fido)"
printf 'fido=on\n' > "$root/features"
check "fido=on: still not in Public" bash -c '[[ $1 != *fsx_gen* ]]' _ "$(order public)"
check "fido=on: fsxNet list" eq "fsx_gen" "$(order fido)"
echo "pass=$pass fail=$fail"; rm -rf "$root"; (( fail == 0 ))
