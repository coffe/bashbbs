#!/bin/bash
# Tests for the local live chat (chat_* in lib/menu.sh): author from the file
# owner, cleaning on write and read, half lines, the limits, presence and
# ghosts, the session-file takeover guard, TERM=dumb, the menu item, and two
# sessions talking through a pty. Every run uses its own BBS_ROOT under the
# scratchpad. The owner lookup (chat_owner) is replaced in the test: here the
# owner is the name after "s."/"h." in the file name, or a pid looked up in
# t/names for the files chat_room makes itself.
# Usage: tests/chat_test.sh [logfile]   (full log in the file; the screen shows
# only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai-coding-bashbbs/15374c20-cb5c-4205-9db5-ac1a2889166c/scratchpad}
log=${1:-$scratch/chat_test.log}
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }

newroot() {
    root=$(mktemp -d "$scratch/chat.XXXXXX")
    mkdir -p "$root"/{state/chat,meta,t}
    cd_=$root/state/chat
}

# run <outfile> <command...>: the command in a subshell with menu.sh sourced.
run() {
    local out=$1; shift
    ( export BBS_ROOT="$root" HOME="$root" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=${T:-xterm}
      source "$here/lib/menu.sh"
      chat_owner() {
          local b=${1##*/}; b=${b#?.}; b=${b%%.*}
          [[ $b =~ ^[0-9]+$ ]] && b=$(awk -v p="$b" '$1 == p { print $2 }' "$BBS_ROOT/t/names")
          printf '%s' "${b:-?}"
      }
      "$@" ) > "$out" 2>>"$log"
}
now=$EPOCHSECONDS

# --- author, cleaning on read, half lines ---------------------------------------------
newroot
printf '%s\tkitty: hi\n' "$now" > "$cd_/s.bob.1"
printf '%s\tx\e[2J\ry\tz\n' "$now" > "$cd_/s.eve.1"
printf '%s\thel' "$now" > "$cd_/s.dan.1"
pump() { # the history pass: every line into hist, printed one per row
    local -A FD=() BUF=() OWN=(); local -a hist=(); local hist_from=0
    chat_scan; chat_pump; printf '%s\n' "${hist[@]#*$'\t'}"
    printf 'lo\n' >> "$CHAT_DIR/s.dan.1"; hist=(); chat_pump; printf 'AFTER %s\n' "${hist[@]#*$'\t'}"
}
run "$root/t/pump" pump
check "author is the file owner, not the text"     grep -qxF 'bob: kitty: hi' "$root/t/pump"
check "ESC, CR and TAB are removed on read"         grep -qxF 'eve: x[2Jyz' "$root/t/pump"
check "a half line is not shown"                    bash -c "! grep -q '^dan' '$root/t/pump'"
check "a half line is shown once it is whole"       grep -qxF 'AFTER dan: hello' "$root/t/pump"

# --- cleaning on write, the limits ----------------------------------------------------
newroot
send() {
    local mine=$CHAT_DIR/s.me sent=0 ROWS=24 COLS=80 a
    chat_send $'a\e[1mb\rc\td'; echo "rc=$?"
    chat_send "too soon"; echo "soon=$?"
    sent=0; printf -v a '%201s' ''; chat_send "${a// /a}"; echo "long=$?"
    head -c 65536 /dev/zero > "$CHAT_DIR/s.full"; mine=$CHAT_DIR/s.full; sent=0
    chat_send "more"; echo "full=$?"
}
run "$root/t/send" send
check "a line is written"                           grep -qx 'rc=0' "$root/t/send"
check "ESC, CR and TAB are removed on write"        eq "$(cut -f2- "$cd_/s.me" | head -n 1)" 'a[1mbcd'
check "a second line within 1 s is refused"         grep -q 'soon=1$' "$root/t/send"
check "a 201-character line is cut to 200"         eq "$(sed -n 2p "$cd_/s.me" | cut -f2 | tr -d '\n' | wc -c)" 200
check "only the two good lines are in the file"     eq "$(wc -l < "$cd_/s.me")" 2
check "a 64 KB session file takes no more"          grep -q 'full=1$' "$root/t/send"
check "the full file is unchanged"                  eq "$(stat -c %s "$cd_/s.full")" 65536

# --- presence, ghosts, entry and exit -------------------------------------------------
newroot
: > "$cd_/h.bob.1"; : > "$cd_/h.old.1"; touch -d '-4 min' "$cd_/h.old.1"
run "$root/t/here" eval 'chat_here; echo "here=$CHAT_HERE"'
check "a ghost (over 3 min) is not counted"         grep -qx 'here=1' "$root/t/here"
room() { echo "$$ alice" >> "$BBS_ROOT/t/names"; printf '/who\r/quit\r' | chat_room; }
run "$root/t/room" room
check "/who lists who is here"                      grep -qa 'Here: alice bob' "$root/t/room"
check "own ghost is removed on entry"               test ! -e "$cd_/h.old.1"
check "own presence file is gone on exit"           eq "$(cd "$cd_" && echo h.*)" h.bob.1
check "joined and left are written"                 eq "$(cut -f3 "$cd_"/s.[0-9]*)" $'joined\nleft'

# --- a session file made beforehand is not taken over ---------------------------------
newroot
grab() {
    local e r; RANDOM=7; r=$RANDOM
    for e in 0 1 2; do echo evil > "$CHAT_DIR/s.$$.$((EPOCHSECONDS + e)).$r"; done
    RANDOM=7; chat_room < /dev/null
}
run "$root/t/grab" grab
check "files made beforehand are untouched"         eq "$(cat "$cd_"/s.* | grep -c evil)" 3
check "the session got a new name"                  eq "$(cat "$cd_"/s.* | grep -c joined)" 1

# --- TERM=dumb, the menu item ---------------------------------------------------------
newroot
T=dumb run "$root/t/dumb" chat_room < /dev/null
check "TERM=dumb gets an explanation"               grep -q 'TERM=dumb' "$root/t/dumb"
check "TERM=dumb makes no files"                    eq "$(ls "$cd_")" ''
: > "$cd_/h.bob.1"
run "$root/t/menu" eval 'main_menu < /dev/null'
check "the main menu has 0) Chat (1 here)"          grep -qa '0) Chat.*(1 here)' "$root/t/menu"

# --- two sessions through a pty -------------------------------------------------------
newroot
sess() { # sess <name> <out> <steps...>
    local name=$1 out=$2; shift 2
    local a=() s; for s in "$@"; do a+=(--step "$s"); done
    python3 "$here/tests/pty_drive.py" --cols 80 --out "$out" --timeout 20 "${a[@]}" -- \
        env BBS_ROOT="$root" HOME="$root" BASHBBS_TEST=1 BASHBBS_TEST_ID="bbs-$name" TERM=xterm \
        bash -c 'source "$1/lib/menu.sh"
            chat_owner() { local p=${1##*/}; p=${p#?.}; awk -v p="${p%%.*}" "\$1 == p { print \$2 }" "$BBS_ROOT/t/names"; }
            echo "$$ $2" >> "$BBS_ROOT/t/names"; chat_room' _ "$here" "$name"
}
sess alice "$root/t/a.out" 'bob: hello=>/quit\r' >>"$log" 2>&1 & apid=$!
sess bob "$root/t/b.out" 'alice joined=>hello\r' 'alice left=>/quit\r' >>"$log" 2>&1; brc=$?
wait "$apid"; arc=$?
check "pty: both sessions end cleanly"              eq "$arc$brc" 00
check "pty: alice sees bob join and talk"           grep -qa 'bob: hello' "$root/t/a.out"
check "pty: bob sees alice leave"                   grep -qa '\* alice left' "$root/t/b.out"
check "pty: no presence file left"                  eq "$(cd "$cd_" && echo h.*)" 'h.*'

echo "chat_test: $pass passed, $fail failed" | tee -a "$log"
(( fail == 0 ))
