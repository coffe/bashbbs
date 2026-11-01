#!/bin/bash
# ANSI colour and ANSI art (colour block in lib/menu.sh): the saved choice and the
# first-login question, the palette on the screen frame, no ESC at all in plain mode,
# CP437 .ans files (block characters, SAUCE cut off), the 80-column intro that is not
# mistaken for wide because of colour codes, OSC removed, and C in My account.
# Runs against a temporary root and HOME; the screens that need a terminal run on a pty.
# Usage: tests/color_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/color_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
has() { grep -q -- "$2" "$1"; }

root=$(mktemp -d "$scratch/color.XXXXXX")
home=$root/home; mkdir -p "$home" "$root/etc/intro" "$root/etc/ads"
lib=$here/lib/menu.sh
ESC=$'\033'

fn() { # fn <color 0|1> <command...>: one function of lib/menu.sh, COLOR forced
    local c=$1; shift
    env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest BASHBBS_COLOR="$c" TERM=xterm COLUMNS=80 \
        bash -c 'source "$1"; shift; "$@"' x "$lib" "$@"
}

# Fixtures. A CP437 .ans: a red full block (0xDB), text, then a SAUCE record after Ctrl-Z.
ans=$root/t.ans
printf '\033[1;31m\xdb\xdb\xdb\033[0m ok\r\n\x1aSAUCE00Title            ' > "$ans"

# (b) colour on: ESC in the bar, same text once ESC is gone
fn 1 top_bar > "$root/b1.out"; fn 0 top_bar > "$root/b0.out"
check "(b) colour bar has ESC[" has "$root/b1.out" "$ESC\\["
check "(b) colour bar text equals plain bar" eq "$(fn 1 top_bar | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')" "$(cat "$root/b0.out")"
check "(b) title is coloured" bash -c '[[ $(cat "$1") == *"$2[1;35m== X =="* ]]' x <(fn 1 screen_header X) "$ESC"

# (c) colour off: no ESC at all in the frame
check "(c) plain bar has no ESC" bash -c '! grep -q "$2" "$1"' x "$root/b0.out" "$ESC"
check "(c) plain headers have no ESC" bash -c '[[ $(cat "$1") != *"$2"* ]]' x <(fn 0 screen_header X; fn 0 local_header Y; fn 0 goodbye) "$ESC"
check "(c) news_rule: colour only when on" bash -c '[[ $(cat "$1") != *"$3"* && $(cat "$2") == *"$3[1;35m"* ]]' x \
    <(env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest BASHBBS_COLOR=0 bash -c 'source "$1"; source "$2"; NEWS_W=10; news_rule' x "$lib" "$here/lib/news.sh") \
    <(env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest BASHBBS_COLOR=1 bash -c 'source "$1"; source "$2"; NEWS_W=10; news_rule' x "$lib" "$here/lib/news.sh") "$ESC"

# (d) CP437 -> UTF-8, SAUCE gone
fn 1 art_cat "$ans" > "$root/d1.out"; fn 0 art_cat "$ans" > "$root/d0.out"
check "(d) 0xDB becomes U+2588" has "$root/d1.out" "███"
check "(d) SAUCE is not shown" bash -c '! grep -q SAUCE "$1"' x "$root/d1.out"
check "(d) colour mode keeps SGR and resets" bash -c '[[ $(cat "$1") == *"$2[1;31m"* && $(cat "$1") == *"$2[0m" ]]' x "$root/d1.out" "$ESC"
check "(d) plain mode: block kept, no ESC" bash -c 'grep -q "███ ok" "$1" && ! grep -q "$2" "$1"' x "$root/d0.out" "$ESC"
check "(d) CR dropped" bash -c '! grep -q $'"'"'\r'"'"' "$1"' x "$root/d1.out"

# (f) OSC and other non-CSI sequences are removed, also in colour mode
printf 'a\033]0;evil title\007b\033]8;;http://x\033\\c\033(Bd\033[31mred\033[0m\n' > "$root/osc.txt"
check "(f) colour: OSC and charset switch removed, SGR kept" eq "$(fn 1 art_cat "$root/osc.txt")" "abcd${ESC}[31mred${ESC}[0m"
check "(f) plain: everything removed" eq "$(fn 0 art_cat "$root/osc.txt")" "abcdred"

# (e) a coloured 80-column picture is 80 wide, not wider, and the narrow file is not used
line80=$(printf '%80s' '' | tr ' ' 'x')
printf '\033[1;37m%s\033[0m\r\n' "$line80" > "$root/etc/intro/wide.txt"
printf '\033[1;36m\xdb%s\033[0m\r\n' "$(printf '%79s' '' | tr ' ' 'x')" > "$root/etc/intro/wide.ans"
printf 'NARROWFILE\n' > "$root/etc/intro/narrow.txt"
printf '2 wide.txt narrow.txt\n' > "$root/etc/intro/intro.conf"
check "(e) intro_width ignores colour codes" eq "$(fn 1 intro_width "$root/etc/intro/wide.ans")" 80
cat > "$root/intro_drv.sh" <<'EOF'
export BBS_ROOT="$1" HOME="$2" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest BASHBBS_COLOR=1 TERM=xterm
source "$3"
intro_run; echo INTRO_DONE
EOF
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/e.out" --timeout 15 --step 'x=>\x20' -- \
    bash "$root/intro_drv.sh" "$root" "$home" "$lib" >>"$log" 2>&1
check "(e) 80 columns: the wide .ans is shown, not the narrow file" bash -c 'grep -q "█x" "$1" && ! grep -q NARROWFILE "$1"' x "$root/e.out"
check "(e) the intro ended on Space" has "$root/e.out" INTRO_DONE

# .ans before .txt in ads; a lone .ans only in colour
printf 'plain ad\n' > "$root/etc/ads/p.txt"; printf '\033[32mcolour ad\033[0m\n' > "$root/etc/ads/p.ans"; printf 'lone\n' > "$root/etc/ads/solo.ans"
check "ads: colour picks p.ans or solo.ans" bash -c '[[ $1 == p.ans || $1 == solo.ans ]]' x "$(fn 1 ad_pick)"
check "ads: plain picks p.txt only" eq "$(fn 0 ad_pick)" "p.txt"

# (a) first login: the question appears, "n" saves color=0; an answer is saved once
cat > "$root/ask_drv.sh" <<'EOF'
export BBS_ROOT="$1" HOME="$2" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest BASHBBS_COLOR=ask TERM=xterm
source "$3"
prefs_ask; echo "RESULT=$COLOR"
EOF
h2=$root/home2; mkdir -p "$h2"
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/a.out" --timeout 15 --step '[A/n] =>n' -- bash "$root/ask_drv.sh" "$root" "$h2" "$lib" >>"$log" 2>&1
check "(a) question shown, n gives RESULT=0" has "$root/a.out" "RESULT=0"
check "(a) n is saved as color=0" eq "$(cat "$h2/.bashbbs-prefs" 2>/dev/null)" "$(printf 'color=0\nreplymail=1')"
h3=$root/home3; mkdir -p "$h3"
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/a2.out" --timeout 15 --step '[A/n] =>\n' -- bash "$root/ask_drv.sh" "$root" "$h3" "$lib" >>"$log" 2>&1
check "(a) Enter means colour, saved as color=1" eq "$(cat "$h3/.bashbbs-prefs" 2>/dev/null)" "$(printf 'color=1\nreplymail=1')"
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/a3.out" --timeout 15 -- bash "$root/ask_drv.sh" "$root" "$h3" "$lib" >>"$log" 2>&1
check "(a) not asked again once saved" bash -c '! grep -q "A/n" "$1" && grep -q RESULT=1 "$1"' x "$root/a3.out"
check "(a) test mode with no prefs does not ask" eq "$(env BBS_ROOT="$root" HOME="$root/home4" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest bash -c 'mkdir -p "$HOME"; source "$1"; echo "$COLOR$COLOR_ASK"' x "$lib")" "00"

# (g) My account: C toggles and saves
h5=$root/home5; mkdir -p "$h5"; printf 'color=1\n' > "$h5/.bashbbs-prefs"
cat > "$root/acct_drv.sh" <<'EOF'
export BBS_ROOT="$1" HOME="$2" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coltest TERM=xterm USER=bbs-coltest
source "$3"
my_account; echo "RESULT=$COLOR"
EOF
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/g.out" --timeout 15 \
    --step 'Any key=>c' --step 'Any key=>q' -- bash "$root/acct_drv.sh" "$root" "$h5" "$lib" >>"$log" 2>&1
check "(g) C turns colour off and saves it" bash -c 'grep -q "RESULT=0" "$1" && grep -qx "color=0" "$2" && grep -qx "replymail=1" "$2"' x "$root/g.out" "$h5/.bashbbs-prefs"
check "(g) the menu showed Colour: on, then off" bash -c 'grep -q "Colour: on" "$1" && grep -q "Colour: off" "$1"' x "$root/g.out"
check "(g) no temp files left" eq "$(ls -A "$h5" | grep -c '^\.bashbbs-prefs\.')" 0

# (h) key prompts: coloured with colour on, unchanged with colour off
check "(h) prompts coloured" bash -c '[[ $(cat "$1") == *"$2[1;36mAny key$2[0m]"*"Main"* ]]' x <(fn 1 paint_bar "[Any key] Main") "$ESC"
check "(h) prompts plain unchanged" eq "$(fn 0 paint_bar "[Space] Bye")" "[Space] Bye"
check "(h) pause prompt: ESC on / none off" bash -c '[[ $(cat "$1") == *"$3"* && $(cat "$2") != *"$3"* ]]' x \
    <(fn 1 paint_bar "[Any key] ") <(fn 0 paint_bar "[Any key] ") "$ESC"

# (i) a scene .ans of 160 visible bytes with no newline: two lines of 80, fits the intro
printf '%0160d' 0 | tr 0 'x' > "$root/nl.ans"
check "(i) 160 bytes wrap to 80+80" eq "$(fn 0 art_raw "$root/nl.ans" | awk '{printf "%d,", length($0)}')" "80,80,"
check "(i) intro_width <= 80" bash -c '(( $1 <= 80 ))' x "$(fn 1 intro_width "$root/nl.ans")"
# (j) ESC[5C counts as 5 columns
{ printf 'x%.0s' $(seq 1 77); printf '\033[5Cab'; } > "$root/cuf.ans"
check "(j) ESC[5C counts 5 columns" eq "$(fn 0 art_raw "$root/cuf.ans" | LC_ALL=C sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | awk '{printf "%d,", length($0)}')" "77,2,"
{ printf 'x%.0s' $(seq 1 70); printf '\033[1;31m'; printf 'y%.0s' $(seq 1 15); } > "$root/sgr.ans"
check "(j) SGR counts 0 columns" eq "$(fn 1 art_raw "$root/sgr.ans" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' | awk '{printf "%d,", length($0)}')" "80,5,"

# (k) mail menu: Inbox in gold only with unread mail and colour; the 1) key stays mint
mkdir -p "$home/Maildir"/{new,cur,tmp}
mm() { fn "$1" mail_menu </dev/null 2>/dev/null | tr -d '\r'; }
mm 1 > "$root/k0.out"                                   # no unread
printf 'From: b\nSubject: s\n\nx\n' > "$home/Maildir/new/1700000000.k.h"
mm 1 > "$root/k1.out"; mm 0 > "$root/k2.out"
check "(k) unread + colour: Inbox is 1;33, 1) is 1;36" bash -c 'grep -q "$2\[1;36m1)$2\[0m $2\[1;33mInbox$2\[0m   " "$1"' x "$root/k1.out" "$ESC"
check "(k) no unread + colour: Inbox plain" bash -c '! grep -q "$2\[1;33mInbox" "$1" && grep -q "Inbox   " "$1"' x "$root/k0.out" "$ESC"
check "(k) unread + COLOR=0: plain line" bash -c 'grep -qx "1) Inbox   2) Write" "$1"' x "$root/k2.out"
mv "$home/Maildir/new/1700000000.k.h" "$root/"

# (l) roles: only 1;35 1;36 1;33 0 are ever emitted by the frame and key helpers
allsgr() { fn 1 eval 'screen_header X "[Q] Back"; local_header Y; goodbye; keyline "1) a   Q) b"; paint HEAD x; key "N)" New; paint ACC "*"' 2>/dev/null | LC_ALL=C grep -ao $'\033\\[[0-9;]*m' | sort -u | tr -d '\033' | tr '\n' ' '; }
check "(l) only the four roles' SGR" eq "$(allsgr)" "[0m [1;33m [1;35m [1;36m "
check "(l) COLOR=0: no ESC from helpers" bash -c '[[ $(cat "$1") != *"$2"* ]]' x <(fn 0 eval 'keyline "1) a"; paint HEAD x; key N\) y; top_bar; screen_header X' 2>/dev/null) "$ESC"
# (m) user text never carries an ESC into the screen
evil=$'a\033[31mb\033]0;x\007c'
{ printf 'From: b\nSubject: %s\n\nbody\n' "$evil"; } > "$home/Maildir/cur/1700000001.e.h"
check "(m) mail list subject: no ESC from the text" bash -c '[[ $(cat "$1") != *"$2[31m"* && $(cat "$1") != *"$2]0"* ]]' x <(fn 0 mail_view Inbox </dev/null 2>&1) "$ESC"
check "(m) mail list subject, colour: no ESC[31m" bash -c '[[ $(cat "$1") != *"$2[31m"* && $(cat "$1") != *"$2]0"* ]]' x <(fn 1 mail_view Inbox </dev/null 2>&1) "$ESC"

# (n) An open post or mail: the subject in orange (0;33), each line closed; a blank line
# under the rule; no colour without COLOR; an ESC in the subject never reaches the screen.
printf 'Subject: Hej %s[31mrod\nAuthor: bbs-kitty\nDate: 2026-11-01T18:54:00Z\n\nbody line\n' "$ESC" > "$root/post.msg"
sp1=$(fn 1 show_post "$root/post.msg" 40 2>&1); sp0=$(fn 0 show_post "$root/post.msg" 40 2>&1)
check "(n) post subject in orange, closed on the line" bash -c '[[ $(head -n1 <<<"$1") == "$2[0;33mHej "*"$2[0m" ]]' x "$sp1" "$ESC"
check "(n) post subject: no ESC[31m from the text" bash -c '[[ $1 != *"$2[31m"* ]]' x "$sp1" "$ESC"
check "(n) no colour codes without COLOR" bash -c '[[ $1 != *"$2["* ]]' x "$sp0" "$ESC"
check "(n) blank line between the rule and the body" bash -c 'grep -A1 "^----" <<<"$1" | sed -n 2p | grep -q "^$" && grep -A2 "^----" <<<"$1" | grep -q "^body line$"' x "$sp0"

echo "color_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
