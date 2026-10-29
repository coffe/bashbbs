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
want = 'This BBS sends greetings to\nthe Up Rough Crew (c) and is made in collab\nwith the BashBBS Beta Party (tm)\n\nFor maximum laz0r experience, please haz\nthe supreme Topaz font handy.'
sys.exit(0 if want in t else 1)" "$root/real.out"
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

# 7. The start loop calls intro_run before the welcome screen.
check "start block: intro_run before welcome_screen" bash -c "grep -n -A2 -F '\${BASHBBS_TEST:-} ]]; then' '$here/lib/menu.sh' | tail -3 | tr '\n' ' ' | grep -q 'intro_run.*welcome_screen'"

echo "intro_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
