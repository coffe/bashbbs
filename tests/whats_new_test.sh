#!/bin/bash
# What's new (1.3.1): the welcome screen after login. Counts of unread private
# messages, new Public board posts and new Wall greetings, the last login time,
# navigation keys and the real 40/80-column width. Nothing is marked as read.
# Must run as a normal user: a private board is hidden with chmod 000.
# Usage: tests/whats_new_test.sh [logfile]   (full log in the file; the screen
# shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/81c6d1f3-937f-4f45-baab-9156c4599c8c/scratchpad}
log=${1:-$scratch/whats_new_test.log}
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }
fits() { # fits <file> <width>: no line wider than <width> (CR from the pty removed)
    tr -d '\r' < "$1" | awk -v w="$2" 'length($0) > w { bad = 1 } END { exit bad }'
}
ends() { # ends <text> <file>: a line ends with <text> (the pty puts it after the "> " prompt)
    tr -d '\r' < "$2" | grep -q "$1\$"
}

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/wn.XXXXXX")
home=$root/home/bbs-alice
T0=1500000000                       # the previous login (2017), 10 digits like a real epoch
mkdir -p "$root"/{boards/general,boards/secret,boards/news/general,wall} \
         "$home"/Maildir/{new,cur}

# Public board posts: <publish epoch>-<msgid>.msg
: > "$root/boards/general/$((T0 + 500))-a1.msg"           # new
: > "$root/boards/general/$((T0 - 500))-a2.msg"           # old
: > "$root/boards/secret/$((T0 + 600))-s1.msg"            # new, but private and hidden from alice
: > "$root/boards/news/general/$((T0 + 700))-n1.msg"      # news: not counted
chmod 000 "$root/boards/secret"

# Wall greetings: <date +%s%N>-<msgid>.msg
: > "$root/wall/$((T0 + 500))123456789-w1.msg"            # new
: > "$root/wall/$((T0 - 500))123456789-w2.msg"            # old

# Private messages: two unread (new/), one read (cur/)
: > "$home/Maildir/new/m1"
: > "$home/Maildir/new/m2"
: > "$home/Maildir/cur/m3"

# welcome <input> <out>: welcome_screen as bbs-alice, input on stdin, then NAV=<nav_req>.
welcome() {
    local input=$1 out=$2
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 \
          TERM=dumb HOME="$home"
      source "$here/lib/menu.sh"
      printf '%s\n' "$input" | { welcome_screen; echo "NAV=$nav_req"; } ) > "$out" 2>>"$log"
}
# snapshot: names and sizes of everything the login could touch.
snapshot() { find "$root/boards" "$root/wall" "$home/Maildir" -printf '%p %s\n' 2>/dev/null | sort; }

# 1. First visit: no baseline yet, so no counts; the login file is created, mode 600.
rm -f "$home/.bashbbs-seen"
welcome "" "$root/first.txt"
check "first visit: greeting shown" grep -qx 'First visit. Welcome to BashBBS.' "$root/first.txt"
check "first visit: no board or wall counts" not grep -q 'new post' "$root/first.txt"
check "first visit: login file created, mode 600" eq "$(stat -c %a "$home/.bashbbs-seen")" 600

# 2. Later login: counts since the previous login only.
printf 'login=%s\n' "$T0" > "$home/.bashbbs-seen"
before=$(snapshot)
welcome "" "$root/second.txt"
check "later login: last login shown" grep -q '^Last login: ' "$root/second.txt"
check "later login: 2 unread private messages" grep -qx '  2 unread private messages' "$root/second.txt"
check "later login: 1 new post (old, private and news excluded)" grep -qx '  1 new post on Public boards' "$root/second.txt"
check "later login: 1 new greeting on the Wall" grep -qx '  1 new greeting on the Wall' "$root/second.txt"

# 3. Login marks nothing as read and moves nothing; only the login time changes.
check "login: nothing moved or marked read (same files and sizes)" eq "$(snapshot)" "$before"
check "login: unread stays 2 in new/" eq "$(ls "$home/Maildir/new" | wc -l)" 2
check "login: baseline is now this login" test "$(sed -n 's/^login=//p' "$home/.bashbbs-seen")" -gt "$T0"

# 4. Navigation keys: B, P, W, G and M/Enter (main menu). Anything else goes to main.
printf 'login=%s\n' "$T0" > "$home/.bashbbs-seen"
welcome "b" "$root/nav-b.txt";   check "key B opens Public boards" grep -qx 'NAV=boards' "$root/nav-b.txt"
welcome "p" "$root/nav-p.txt";   check "key P opens Mail" grep -qx 'NAV=mail' "$root/nav-p.txt"
welcome "w" "$root/nav-w.txt";   check "key W opens the Wall" grep -qx 'NAV=wall' "$root/nav-w.txt"
welcome "gy" "$root/nav-g.txt";  check "key G, then y, quits" grep -qx 'NAV=quit' "$root/nav-g.txt"
welcome "" "$root/nav-e.txt";    check "Enter goes to the main menu" grep -qx 'NAV=main' "$root/nav-e.txt"
welcome "x" "$root/nav-x.txt";   check "unknown key goes to the main menu" grep -qx 'NAV=main' "$root/nav-x.txt"
welcome "gn" "$root/nav-gn.txt"; check "key G, then n, stays logged in (main menu)" grep -qx 'NAV=main' "$root/nav-gn.txt"

# 5. The real terminal width, not a stub: pty at 40 and 80 columns.
for w in 40 80; do
    # Expect-style: the key is sent when the prompt text is on the screen, no fixed delay.
    check "pty $w: the prompt appeared and the key was sent" python3 "$here/tests/pty_drive.py" --cols "$w" --out "$root/pty-$w.txt" --timeout 30 \
        --step '[Any key] Main=>m' -- \
        env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
        bash -c "source $here/lib/menu.sh; printf 'login=%s\\n' $T0 > \$HOME/.bashbbs-seen; welcome_screen; echo NAV=\$nav_req" 2>>"$log"
    check "pty $w: no row wider than $w" fits "$root/pty-$w.txt" "$w"
    check "pty $w: key M goes to the main menu" ends 'NAV=main' "$root/pty-$w.txt"
done

chmod 700 "$root/boards/secret"
echo "whats_new_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
