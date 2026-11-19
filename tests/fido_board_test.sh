#!/bin/bash
# Fido boards (meta/<board>.fido): sysop-only posting, no edits, delete keeps the file
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
check "non-sysop rejected (rc)" eq "$rc" 1
check "no file after rejection" eq "$(ls "$root"/boards/fsx_gen | wc -l)" 0
lib handle_post "$root/t/b.post" bbs-carol; rc=$?
check "sysop post accepted" eq "$rc" 0
F=$(ls "$root"/boards/fsx_gen/*.msg | head -1)
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
