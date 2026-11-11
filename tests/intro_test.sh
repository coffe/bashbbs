#!/bin/bash
# Login intro (intro_run in lib/menu.sh): screens from $BBS_ROOT/etc/intro, Space,
# timeouts, the art left unchanged at 80 columns, the narrow fallback at 40/60, and
# Space presses not leaking into the next screen. Runs on a real pty.
# Uses the piewpiew intro in ascii-art/intro when present (not in git), else a built-in one.
# Usage: tests/intro_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/intro_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }

root=$(mktemp -d "$scratch/intro.XXXXXX")
mkdir -p "$root/etc/intro"
src=$here/ascii-art/intro
if [[ -f $src/art-1.txt ]]; then cp "$src"/* "$root/etc/intro/"
else
    printf '\n\nGreetings\n' > "$root/etc/intro/greetings.txt"
    pad=$(printf '%-50s' x | tr ' ' '_')
    printf ' /\\ /\\\n/__\\__\\ one %s\n' "$pad" > "$root/etc/intro/art-1.txt"; printf ' /\\ /\\\n/__\\__\\ two %s\n' "$pad" > "$root/etc/intro/art-2.txt"
    printf 'use an 80-column terminal\n' > "$root/etc/intro/art-narrow.txt"
    printf 'CRASH THE PARTY! SMASH THE SPACEBAR!\n' > "$root/etc/intro/caption.txt"; printf 'CRASH THE PARTY!\nSMASH THE SPACEBAR!\n' > "$root/etc/intro/caption-narrow.txt"
    printf '4 greetings.txt\n10 art-1.txt|art-2.txt art-narrow.txt caption.txt caption-narrow.txt\n' > "$root/etc/intro/intro.conf"
fi
art1=$root/etc/intro/art-1.txt; art2=$root/etc/intro/art-2.txt
[[ -f $root/etc/intro/greetings-narrow.txt ]] && gn=greetings-narrow.txt || gn=-
fastconf() { printf "2 greetings.txt $gn\\n2 art-1.txt|art-2.txt art-narrow.txt caption.txt caption-narrow.txt\n" > "$root/etc/intro/intro.conf"; }
realconf=$(cat "$root/etc/intro/intro.conf")

# run <cols> <script of "delay_s:text" steps> <out>: prints elapsed seconds to <out>.t
python3 - "$here" "$root" <<'PY' > "$root/driver.py.out" 2>&1 || true
PY
cat > "$root/drv.py" <<'PY'
import os, pty, sys, time, select, struct, fcntl, termios
here, root, cols, steps, out = sys.argv[1:6]
code = f'''export BBS_ROOT="{root}" BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=xterm HOME="{root}/home"
mkdir -p "$HOME"; source "{here}/lib/menu.sh"
intro_run; echo; echo SENTINEL; IFS= read -rsn1 -t 3 k; echo "KEY=[$k]"'''
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 40, int(cols), 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid(); fcntl.ioctl(s, termios.TIOCSCTTY, 0); os.dup2(s, 0); os.dup2(s, 1); os.dup2(s, 2)
    os.execvp("bash", ["bash", "-c", code])
os.close(s)
buf = b""; t0 = time.time(); marks = {}
def pump(dur):
    global buf
    end = time.time() + dur
    while time.time() < end:
        r, _, _ = select.select([m], [], [], 0.05)
        if r:
            try: d = os.read(m, 65536)
            except OSError: return False
            if not d: return False
            buf += d
            if b"SENTINEL" in buf and "sent" not in marks: marks["sent"] = time.time() - t0
    return True
for st in steps.split(","):
    if not st: continue
    delay, _, txt = st.partition(":")
    pump(float(delay))
    if txt: os.write(m, txt.encode().replace(b"\\s", b" "))
pump(float(os.environ.get("TAIL", "14")))
open(out, "wb").write(buf)
open(out + ".t", "w").write("%.1f\n" % marks.get("sent", -1))
try: os.kill(pid, 9)
except OSError: pass
PY
run() { python3 "$root/drv.py" "$here" "$root" "$@"; }   # run <cols> <steps> <out>
clean() { tr -d '\r' < "$1"; }

# 1. Real timing at 80 columns: no key; greetings 4 s + art 10 s, then the next screen.
echo "$realconf" > "$root/etc/intro/intro.conf"
total=$(awk '/^[0-9]/{s+=$1} END{print s}' "$root/etc/intro/intro.conf")
TAIL=$((total + 4)) run 80 "" "$root/real.out"
t=$(<"$root/real.out.t")
check "real timeouts: next screen after about $total s ($t)" awk -v t="$t" -v n="$total" 'BEGIN{exit !(t>=n-0.5 && t<=n+2.5)}'
[[ -f $src/art-1.txt ]] && check "greetings text is exact (80 columns)" python3 -c "
import re, sys
t = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', open(sys.argv[1], 'rb').read().decode().replace('\r', ''))
want = ['This BBS sends greetings to', 'the Up Rough Crew (c) and is', 'made in collab with the', 'BashBBS Beta Party (tm)', 'For maximum laz0r experience,', 'please haz the supreme Topaz', 'font handy.']
sys.exit(0 if all(w in t for w in want) else 1)" "$root/real.out"
check "caption below the art" bash -c "tr -d '\r' < '$root/real.out' | grep -q 'CRASH THE PARTY!.*SMASH THE SPACEBAR!'"

# 2. At 80 columns exactly one of the two arts is on screen, unchanged.
# (the escape bytes are removed from the screen text first)
fastconf
TAIL=6 run 80 "" "$root/c80.out"
python3 - "$art1" "$art2" "$root/c80.out" <<'PY' >>"$log" 2>&1
import re, sys
arts = [open(f, "rb").read().decode().replace("\r", "").rstrip().split("\n") for f in sys.argv[1:3]]
scr = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", open(sys.argv[3], "rb").read().decode(errors="replace")).replace("\r", "")
lines = scr.split("\n")
def has(a):
    return any(lines[k:k + len(a)] == a for k in range(len(lines)))
n = sum(has(a) for a in arts)
print("arts on screen:", n)
sys.exit(0 if n == 1 and scr.count("dNo") <= 1 else 1)
PY
check "one art on screen, unchanged, at 80 columns" test $? -eq 0
check "no fallback text at 80 columns" bash -c "! grep -q 'Amiga art by dNo: use' '$root/c80.out' || ! [ -f '$src/art-1.txt' ]"

# 3. Narrow terminals show the fallback, not the art.
for c in 40 60; do
    TAIL=6 run $c "" "$root/c$c.out"
    check "fallback at $c columns" bash -c "grep -q 'use an' '$root/c$c.out' || grep -q small '$root/c$c.out'"
    [[ -f $root/etc/intro/greetings-narrow.txt ]] && check "greetings fit and are shown at $c columns" grep -q 'Party (tm)' "$root/c$c.out"
    check "art not shown at $c columns" bash -c "! grep -q '_/\\\\_____' '$root/c$c.out'"
    check "no line wider than $c at $c columns" python3 -c "
import re, sys
t = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', open(sys.argv[1], 'rb').read().decode().replace('\r', ''))
sys.exit(1 if any(len(l) > int(sys.argv[2]) for l in t.split('\n')) else 0)" "$root/c$c.out" $c
done

# 4. Space skips at once, and smashed spaces do not reach the next screen.
fastconf
TAIL=3 run 80 "0.7: ,0.1: " "$root/skip1.out"
t=$(<"$root/skip1.out.t")
check "two Spaces skip both screens quickly ($t s)" awk -v t="$t" 'BEGIN{exit !(t>=0 && t<=2.5)}'
TAIL=5 run 80 "0.7: ,0.3:\s\s\s\s\s\s,0.05:\s\s\s\s\s\s,0.05:\s" "$root/skip2.out"
check "Space presses are not left for the next screen" grep -q 'KEY=\[\]' "$root/skip2.out"
fastconf
TAIL=4 run 80 "0.7: ,0.3: ,1.5:x" "$root/skip3.out"
check "next screen reads a later key (x)" grep -q 'KEY=\[x\]' "$root/skip3.out"

# 5. Other keys do not skip.
TAIL=0.5 run 80 "0.5:a,0.3:\n" "$root/nokey.out"
check "other keys and Enter do not skip" bash -c "! grep -q SENTINEL '$root/nokey.out'"

# 6. No intro / bad config.
mv "$root/etc/intro/intro.conf" "$root/intro.conf.off"
TAIL=1 run 80 "" "$root/none.out"
check "no intro.conf: straight to the next screen" bash -c "grep -q SENTINEL '$root/none.out' && ! grep -q Greeting '$root/none.out' && ! grep -q greetings '$root/none.out'"
printf '2 ../../etc/passwd\n2 nonexist.txt\nabc greetings.txt\n' > "$root/etc/intro/intro.conf"
TAIL=1.5 run 80 "" "$root/bad.out"
check "bad names and bad seconds are skipped" bash -c "grep -q SENTINEL '$root/bad.out' && ! grep -q root: '$root/bad.out'"

# 6b. intro_pick: alternatives a|b are chosen with the same chance; a single name as it is.
check "intro_pick: both alternatives, about half each" bash -c "
export BBS_ROOT='$root' BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=dumb; source '$here/lib/menu.sh'
[[ \$(intro_pick single.txt) == single.txt ]] || exit 1
for i in \$(seq 400); do intro_pick 'a|b'; done | sort | uniq -c | awk '{ n[\$2] = \$1 } END { exit !(n[\"a\"] >= 150 && n[\"b\"] >= 150) }'"
# 6c. A terminal type without terminfo (SyncTERM sends "syncterm"): redraw still clears.
check "redraw clears with an unknown TERM" bash -c "
export BBS_ROOT='$root' BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=syncterm; source '$here/lib/menu.sh'
redraw | grep -q \$'\\033\\[H\\033\\[2J'"

# 6d. Seasonal art: "season MMDD-MMDD file" in intro.conf, above the first screen only.
[[ -f $root/etc/intro/halloween.txt ]] || printf ' .-.\n(o o) boo\n | |\n\n.:* HaPpY HaLooJen! *:.\n' > "$root/etc/intro/halloween.txt"
check "intro_season: in, out, over New Year, bad window, bad file" bash -c "
export BBS_ROOT='$root' BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=dumb; source '$here/lib/menu.sh'
c='$root/season.conf'
printf 'season 1031-1105 halloween.txt\n' > \$c
for d in 1031 1101 1105; do BASHBBS_TEST_TODAY=\$d intro_season \$c | grep -q halloween.txt || exit 1; done
for d in 1030 1106 0101; do BASHBBS_TEST_TODAY=\$d intro_season \$c && exit 1; done
printf 'season 1220-0106 halloween.txt\n' > \$c
for d in 1231 0103; do BASHBBS_TEST_TODAY=\$d intro_season \$c | grep -q halloween.txt || exit 1; done
BASHBBS_TEST_TODAY=0107 intro_season \$c && exit 1
printf 'season 1031 halloween.txt\nseason 1031-1105 ../../etc/passwd\n# season 1031-1105 halloween.txt\n' > \$c
BASHBBS_TEST_TODAY=1101 intro_season \$c && exit 1
BASHBBS_TEST=0; BASHBBS_TEST_TODAY=1101; [[ \$(intro_today) =~ ^[0-9]{4}\$ ]]"
seasonconf() { fastconf; printf 'season 1031-1105 halloween.txt\n' >> "$root/etc/intro/intro.conf"; }
seasonconf
BASHBBS_TEST_TODAY=1101 TAIL=2.5 run 80 "" "$root/season-in.out"
check "season: skull above the greetings on 1 Nov" python3 -c "
import re, sys
t = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', open(sys.argv[1], 'rb').read().decode(errors='replace')).replace('\r', '')
a, b = t.find('HaLooJen'), t.find('reeting')
sys.exit(0 if 0 <= a < b and t.count('HaLooJen') == 1 else 1)" "$root/season-in.out"
BASHBBS_TEST_TODAY=1106 TAIL=2.5 run 80 "" "$root/season-out.out"
check "season: no skull on 6 Nov" bash -c "grep -q 'reeting' '$root/season-out.out' && ! grep -q HaLooJen '$root/season-out.out'"
BASHBBS_TEST_TODAY=1101 TAIL=2.5 run 40 "" "$root/season-40.out"
w=$(wc -L < "$root/etc/intro/halloween.txt")
(( w > 40 )) && check "season: skull left out when wider than the terminal (40)" bash -c "! grep -q HaLooJen '$root/season-40.out'"
BASHBBS_TEST_TODAY=1101 TAIL=5 run 80 "" "$root/season-2nd.out"
check "season: skull only once, not on the second screen" bash -c "[ \$(grep -c HaLooJen '$root/season-2nd.out') -eq 1 ]"

# 6e. Captions are centred on the art above, whatever its width; colour codes kept.
cdir=$(mktemp -d "$scratch/intro-centre.XXXXXX"); mkdir -p "$cdir/etc/intro"
printf '  ####################\n  #  å°¦ art  #\n' > "$cdir/etc/intro/a.txt"       # columns 2..21: first + end = 2 + 22
printf '            hi\n\n\033[1;33m   abcd\033[0m\n%s\n' "$(printf '%050d' 0)" > "$cdir/etc/intro/c.txt"
check "intro_mid and intro_caption: centred per line, codes kept, clamped" bash -c "
export BBS_ROOT='$cdir' BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 TERM=xterm; source '$here/lib/menu.sh'; COLOR=1
m=\$(intro_mid '$cdir/etc/intro/a.txt'); [[ \$m == 24 ]] || { echo mid=\$m; exit 1; }
out=\$(intro_caption '$cdir/etc/intro/c.txt' \"\$m\" 40)
want=\$(printf '           hi\n\n\033[1;33m          abcd\033[0m')
got=\${out%\$'\n'*}; [[ \$got == \"\$want\" ]] || { printf '%q\n%q\n' \"\$got\" \"\$want\"; exit 1; }
last=\${out##*\$'\n'}; [[ \$last == 0* ]]   # wider than the terminal: starts at column 0"
rm -rf "$cdir"

# 7. The start loop calls intro_run before the welcome screen.
check "start block: intro_run before welcome_screen" bash -c "grep -n -A2 -F '\${BASHBBS_TEST:-} ]]; then' '$here/lib/menu.sh' | tail -3 | tr '\n' ' ' | grep -q 'intro_run.*welcome_screen'"

# 8. intro_anim: orange, the art unchanged, the greeting under it, any key finishes it.
adir=$(mktemp -d "$scratch/anim.XXXXXX"); mkdir -p "$adir/etc/intro"
printf '  .oOo.\n .o  Oo.\n  `oOo`\n' > "$adir/etc/intro/p.txt"
anim() { # anim <keydelay|-> <term>: runs intro_anim on a pipe, prints the raw output and the time
    ( [[ $1 != - ]] && sleep "$1" && echo x; sleep 6 ) | BBS_ROOT="$adir" BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 BASHBBS_COLOR=1 TERM=$2 bash -c "
source '$here/lib/menu.sh'; COLOR=1; S=\$SECONDS; intro_anim '$adir/etc/intro/p.txt' 1; echo; echo \"rc=\$? t=\$((SECONDS-S))\"" 2>&1
}
anim - xterm-256color > "$adir/a.out"
check "intro_anim: 256-colour orange, lighter orange greeting" bash -c "grep -q $'\033\\[38;5;208m' '$adir/a.out' && grep -q $'\033\\[38;5;215m' '$adir/a.out'"
check "intro_anim: the art is drawn as it is, greeting under it" bash -c "sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' '$adir/a.out' | tr -d '\r' | head -4 | diff -q - <(printf '  .oOo.\n .o  Oo.\n  \`oOo\`\n  ... hello sailor, stay a while and listen...\n') >/dev/null || sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' '$adir/a.out' | tr -d '\r' | grep -q 'hello sailor, stay a while and listen'"
check "intro_anim: cursor hidden while drawing, shown again" bash -c "grep -q $'\033\\\\[?25l' '$adir/a.out' && grep -q $'\033\\\\[?25h' '$adir/a.out'"
anim - linux > "$adir/b.out"
check "intro_anim: plain ANSI oranges on a 16-colour terminal" bash -c "grep -q $'\033\\[0;33m' '$adir/b.out' && grep -q $'\033\\[1;33m' '$adir/b.out'"
anim 0.3 xterm > "$adir/c.out"
check "intro_anim: a key during the hold goes on at once" bash -c "grep -q 'rc=0 t=[01]\$' '$adir/c.out'"
rm -rf "$adir"

# 9. intro_boot: green, the text as it is, the bar filled over an empty one, about 3 s,
# any key finishes it, file text never run, a missing file skipped by intro_run.
bdir=$(mktemp -d "$scratch/boot.XXXXXX"); mkdir -p "$bdir/etc/intro"
cp "$here/examples/intro/boot.txt" "$bdir/etc/intro/boot.txt"
printf 'HEAD\n$(touch %s/pwned) `touch %s/pwned2`\n' "$bdir" "$bdir" > "$bdir/etc/intro/evil.txt"
boot() { # boot <keydelay|-> <file> <hold>: runs intro_boot on a pipe, prints output and time
    ( [[ $1 != - ]] && sleep "$1" && echo x; sleep 6 ) | BBS_ROOT="$bdir" BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 BASHBBS_COLOR=1 TERM=xterm bash -c "
source '$here/lib/menu.sh'; COLOR=1; S=\$EPOCHREALTIME; intro_boot '$bdir/etc/intro/$2' $3; rc=\$?; echo; echo \"rc=\$rc ms=\$(( (\${EPOCHREALTIME/./} - \${S/./}) / 1000 ))\"" 2>&1
}
strip() { sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$1" | tr -d '\r'; }
boot - boot.txt 0 > "$bdir/a.out"
check "intro_boot: green" bash -c "grep -q $'\033\\[0;32m' '$bdir/a.out' && grep -q $'\033\\[1;32m' '$bdir/a.out'"
check "intro_boot: the text shown as it is" bash -c "diff <(sed -e 's/\[ *\]\x1b\[[0-9]*D/[/' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' '$bdir/a.out' | grep -v '^rc=' | sed -e '/./,\$!d' | sed -e :a -e '/^\n*\$/{\$d;N;ba' -e '}') <(sed -e :a -e '/^\n*\$/{\$d;N;ba' -e '}' '$bdir/etc/intro/boot.txt')"
check "intro_boot: empty bar drawn first, cursor back over it" bash -c "grep -qF '[                                ]'$'\033''[33D' '$bdir/a.out'"
check "intro_boot: about 3 s with no hold" bash -c "ms=\$(grep -o 'ms=[0-9]*' '$bdir/a.out' | cut -d= -f2); echo ms=\$ms; (( ms >= 2400 && ms <= 4500 ))"
check "intro_boot: cursor hidden, shown again" bash -c "grep -q $'\033\\[?25l' '$bdir/a.out' && grep -q $'\033\\[?25h' '$bdir/a.out'"
boot 0.4 boot.txt 5 > "$bdir/b.out"
check "intro_boot: a key finishes it at once and skips the hold" bash -c "ms=\$(grep -o 'ms=[0-9]*' '$bdir/b.out' | cut -d= -f2); echo ms=\$ms; (( ms <= 1500 )) && grep -q 'REMOTE SESSION ACTIVE' '$bdir/b.out'"
boot - evil.txt 0 > "$bdir/c.out"
check "intro_boot: file text is printed, never run" bash -c "[[ ! -e '$bdir/pwned' && ! -e '$bdir/pwned2' ]] && grep -qF '\$(touch' '$bdir/c.out'"
printf 'boot missing.txt 1\n' > "$bdir/etc/intro/intro.conf"
check "intro_run: a missing boot file is skipped" bash -c "cd '$bdir' && script -qec \"env BBS_ROOT='$bdir' BASHBBS_TEST_ID=bbs-alice BASHBBS_TEST=1 bash -c 'source $here/lib/menu.sh; intro_run; echo RC=\\\$?'\" /dev/null < /dev/null | grep -q RC=0"
rm -rf "$bdir"

echo "intro_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
