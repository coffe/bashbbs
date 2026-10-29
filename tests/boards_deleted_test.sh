#!/bin/bash
# Deleted posts in Public boards: a post with a Deleted header stays on disk (soft
# delete) but is listed only while an active post is below it, at any depth. Also:
# What's New does not count deleted posts, and nothing on disk changes.
# Logic checks source lib/menu.sh; the 40/60/80-column checks run board_view in a pty.
# Everything uses a temporary BBS_ROOT. Nothing outside it is read or written.
# Usage: tests/boards_deleted_test.sh [logfile]   (full log in the file; the screen
# shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/b81958b1-d888-4669-a367-89842baf6a52/scratchpad}
[[ -d $scratch ]] || scratch=${TMPDIR:-/tmp}
log=${1:-$scratch/boards_deleted_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }
fits() { tr -d '\r' < "$1" | awk -v w="$2" 'length($0) > w { bad = 1 } END { exit bad }'; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/bd.XXXXXX")
out=$(mktemp -d "$scratch/bdout.XXXXXX")   # pty output stays outside the snapshot
T0=1500000000
mkdir -p "$root"/{boards/general,boards/chat,boards/news,wall,state/admin-backup}

# mk <board> <n> <id> <parent|-> <active|deleted>: file <T0+10n>-<id>.msg
mk() {
    local f=$root/boards/$1/$((T0 + 10 * $2))-$3.msg subj="Post $3" extra=""
    [[ $5 == deleted ]] && { subj="[deleted]"; extra="Deleted: 2017-07-14T05:00:00+00:00"$'\n'; }
    {
        printf 'Msgid: %s\nAuthor: bbs-bob\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: %s\n' "$3" "$subj"
        [[ $4 != - ]] && printf 'Parent: %s\n' "$4"
        printf '%s\n' "$extra"
        [[ $5 == deleted ]] || printf 'Body of %s\n' "$3"
    } > "$f"
}
#  board   n  id    parent  state
mk general  1 s1    -     deleted   # deleted starter, no replies             -> hidden
mk general  2 s2    -     deleted   # deleted starter with an active reply    -> shown as [deleted]
mk general  3 r2    s2    active
mk general  4 a3    -     active
mk general  5 x3    a3    deleted   # deleted reply, no children              -> hidden
mk general  6 a4    -     active
mk general  7 x4    a4    deleted   # deleted reply with an active sub-reply  -> shown as [deleted]
mk general  8 y4    x4    active
mk general  9 z4    y4    deleted   # deleted below an active post, no active below -> hidden
mk general 10 w4    z4    deleted
mk general 11 s5    -     deleted   # thread of only deleted posts            -> hidden
mk general 12 c5    s5    deleted
mk general 13 cc5   c5    deleted
mk general 14 s7    -     deleted   # nested: deleted, deleted, active        -> first two shown
mk general 15 c7    s7    deleted
mk general 16 g7    c7    active
mk general 17 p8    q8    deleted   # Parent loop between deleted posts       -> hidden, must end
mk general 18 q8    p8    deleted
mk general 19 dg    nope  deleted   # Parent that does not exist              -> hidden
mk general 20 keep6 -     active    # the post that must stay
mk chat     1 c1    -     deleted
mk chat     2 c2    -     active
mk news    30 n1    -     active    # News is never counted here
: > "$root/state/admin-backup/keep.txt"

snapshot() { (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
before=$(snapshot)

lib() { # lib <command...>: run a command with lib/menu.sh sourced, as bbs-alice
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb
      source "$here/lib/menu.sh"; "$@" )
}
ids() { lib visible_posts "$1" | sed 's/.*[0-9]-//; s/\.msg$//' | tr '\n' ' '; }

# 1. Which posts are listed.
check "general: exactly the expected posts, in order" eq "$(ids general)" "s2 r2 a3 a4 x4 y4 s7 c7 g7 keep6 "
check "deleted starter without replies is hidden"    not grep -qw s1 <(ids general)
check "deleted starter with an active reply is kept" grep -qw s2 <(ids general)
check "deleted reply without replies is hidden"      not grep -qw x3 <(ids general)
check "deleted reply with an active sub-reply kept"  grep -qw x4 <(ids general)
check "deleted tail below an active reply is hidden" not grep -Eqw 'z4|w4' <(ids general)
check "nested deleted chain above an active post kept" grep -qw 'c7' <(ids general)
check "thread of only deleted posts is hidden"       not grep -Eqw 's5|c5|cc5' <(ids general)
check "parent loop and missing parent: hidden, ends" not grep -Eqw 'p8|q8|dg' <(ids general)
check "the post to keep is listed"                   grep -qw keep6 <(ids general)
check "other board: only its active post"            eq "$(ids chat)" "c2 "
check "a board without posts lists nothing"          eq "$(lib visible_posts nosuch)" ""

# 2. What's New: deleted posts are not new activity.
check "new since T0: 7 active posts, no deleted, no news" eq "$(lib new_board_posts "$T0")" 7
check "new since T0+100: only the active ones after it" eq "$(lib new_board_posts $((T0 + 100)))" 2
check "news board is still not counted" eq "$(lib new_board_posts $((T0 + 250)))" 0

# 3. Soft delete is untouched: no file changed, none removed (Msgid, Parent included).
check "no file on disk changed or removed" eq "$(snapshot)" "$before"
check "20 posts still in general" eq "$(ls "$root/boards/general" | wc -l)" 20
check "Parent and Msgid headers intact" grep -q '^Parent: c7$' "$root/boards/general/$((T0 + 160))-g7.msg"

# 4. Sysop: the review side is unchanged (a stub still opens, admin backup is left alone).
echo alice > "$root/sysops"; before=$(snapshot)
check "sysop is still recognised" lib is_sysop
check "a stub still shows [deleted] and who/when" bash -c "
    export BBS_ROOT='$root' BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb; source '$here/lib/menu.sh'
    show_post '$root/boards/general/$((T0 + 10))-s1.msg' 40 | grep -q '^\[deleted\]$' &&
    show_post '$root/boards/general/$((T0 + 10))-s1.msg' 40 | grep -q '^deleted '"
check "admin backup left alone" test -f "$root/state/admin-backup/keep.txt"

# 5. Real terminal widths. Entries are numbered 1..10 over the visible posts only.
for w in 40 60 80; do
    first_screen() { tr -d '\r' < "$out/p1-$w.txt" | sed '/N) New/q'; }
    run() { # run <out> <key to open>
        python3 "$here/tests/pty_drive.py" --cols "$w" --out "$1" --timeout 30 \
            --step 'Q) Back=>'"$2" --step 'Q) Back=>q' --step 'Q) Back=>q' -- \
            env BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
            bash -c "source $here/lib/menu.sh; board_view general; echo DONE" 2>>"$log"
    }
    check "pty $w: open entry 1 (a stub), back, quit" run "$out/p1-$w.txt" '1\n'
    check "pty $w: open entry 2 (a reply), back, quit" run "$out/p2-$w.txt" 2
    check "pty $w: no row wider than $w" fits "$out/p1-$w.txt" "$w"
    check "pty $w: list has 10 entries" eq "$(first_screen | grep -c '^ *[0-9]*) ')" 10
    check "pty $w: last entry is number 10, the kept post" bash -c "tr -d '\r' < '$out/p1-$w.txt' | grep -q '^ *10) Post keep6'"
    check "pty $w: 4 context stubs, no others" eq "$(first_screen | grep -c '\[deleted\]')" 4
    check "pty $w: hidden posts do not appear" not grep -Eq 'Post (s1|x3|z4|w4|s5|c5|cc5|p8|q8|dg)\b' "$out/p1-$w.txt"
    check "pty $w: a stub offers no Reply" not grep -q 'R) Reply' "$out/p1-$w.txt"
    check "pty $w: an active reply offers Reply" grep -q 'R) Reply' "$out/p2-$w.txt"
    check "pty $w: the session ends normally" grep -q DONE "$out/p1-$w.txt"
done

check "no file changed by the pty runs either" eq "$(snapshot)" "$before"
echo "boards_deleted_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
