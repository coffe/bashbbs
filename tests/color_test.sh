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
check "(b) title is coloured" bash -c '[[ $(cat "$1") == *"$2[1;37m== X =="* ]]' x <(fn 1 screen_header X) "$ESC"

# (c) colour off: no ESC at all in the frame
check "(c) plain bar has no ESC" bash -c '! grep -q "$2" "$1"' x "$root/b0.out" "$ESC"
check "(c) plain headers have no ESC" bash -c '[[ $(cat "$1") != *"$2"* ]]' x <(fn 0 screen_header X; fn 0 local_header Y; fn 0 goodbye) "$ESC"
check "(c) news_rule: colour only when on" bash -c '[[ $(cat "$1") != *"$3"* && $(cat "$2") == *"$3[0;34m"* ]]' x \
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
check "(a) n is saved as color=0" eq "$(cat "$h2/.bashbbs-prefs" 2>/dev/null)" "color=0"
h3=$root/home3; mkdir -p "$h3"
python3 "$here/tests/pty_drive.py" --cols 80 --out "$root/a2.out" --timeout 15 --step '[A/n] =>\n' -- bash "$root/ask_drv.sh" "$root" "$h3" "$lib" >>"$log" 2>&1
check "(a) Enter means colour, saved as color=1" eq "$(cat "$h3/.bashbbs-prefs" 2>/dev/null)" "color=1"
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
    --step '[Any key] =>c' --step '[Any key] =>q' -- bash "$root/acct_drv.sh" "$root" "$h5" "$lib" >>"$log" 2>&1
check "(g) C turns colour off and saves it" bash -c 'grep -q "RESULT=0" "$1" && [[ $(cat "$2") == color=0 ]]' x "$root/g.out" "$h5/.bashbbs-prefs"
check "(g) the menu showed Colour: on, then off" bash -c 'grep -q "Colour: on" "$1" && grep -q "Colour: off" "$1"' x "$root/g.out"
check "(g) no temp files left" eq "$(ls -A "$h5" | grep -c '^\.bashbbs-prefs\.')" 0

echo "color_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
