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
if [[ -f $src/art.txt ]]; then cp "$src"/* "$root/etc/intro/"
else
    printf '\n\nGreetings\n' > "$root/etc/intro/greetings.txt"
    printf ' /\\ /\\\n/__\\__\\ x\n' > "$root/etc/intro/art.txt"
    printf 'small\n' > "$root/etc/intro/art-narrow.txt"
    printf 'CAPTION\n' > "$root/etc/intro/caption.txt"; printf 'cap\n' > "$root/etc/intro/caption-narrow.txt"
    printf '4 greetings.txt\n10 art.txt art-narrow.txt caption.txt caption-narrow.txt\n' > "$root/etc/intro/intro.conf"
fi
art=$root/etc/intro/art.txt
fastconf() { printf '2 greetings.txt\n2 art.txt art-narrow.txt caption.txt caption-narrow.txt\n' > "$root/etc/intro/intro.conf"; }
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
TAIL=18 run 80 "" "$root/real.out"
t=$(<"$root/real.out.t")
check "real timeouts: next screen after about 14 s ($t)" awk -v t="$t" 'BEGIN{exit !(t>=13.5 && t<=16.5)}'
check "greetings text is exact" bash -c "clean() { tr -d '\r' < \"\$1\"; }; clean '$root/real.out' | grep -qF 'the Up Rough Crew©' && clean '$root/real.out' | grep -qF 'with the BashBBS Beta Party™'"
check "caption below the art" bash -c "tr -d '\r' < '$root/real.out' | grep -q 'CRASH THE PARTY!.*SMASH THE SPACEBAR!'"

# 2. Art unchanged at 80 columns: every non-empty art line is on screen as it is.
# (the escape bytes are removed from the screen text first)
fastconf
TAIL=6 run 80 "" "$root/c80.out"
python3 - "$art" "$root/c80.out" <<'PY' >>"$log" 2>&1
import re, sys
art = open(sys.argv[1], "rb").read().decode().replace("\r", "").rstrip().split("\n")
scr = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", open(sys.argv[2], "rb").read().decode(errors="replace")).replace("\r", "")
lines = scr.split("\n")
# the art block must appear as consecutive lines, byte for byte
i = next((k for k in range(len(lines)) if lines[k] == art[0]), None)
ok = i is not None and lines[i:i + len(art)] == art
print("art block found at", i, "identical:", ok)
sys.exit(0 if ok else 1)
PY
check "art identical at 80 columns" test $? -eq 0
check "no fallback text at 80 columns" bash -c "! grep -q 'Amiga art by dNo: use' '$root/c80.out' || ! [ -f '$src/art.txt' ]"

# 3. Narrow terminals show the fallback, not the art.
for c in 40 60; do
    TAIL=6 run $c "" "$root/c$c.out"
    check "fallback at $c columns" bash -c "grep -q 'use an' '$root/c$c.out' || grep -q small '$root/c$c.out'"
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

# 7. The start loop calls intro_run before the welcome screen.
check "start block: intro_run before welcome_screen" bash -c "grep -n -A2 -F '\${BASHBBS_TEST:-} ]]; then' '$here/lib/menu.sh' | tail -3 | tr '\n' ' ' | grep -q 'intro_run.*welcome_screen'"

echo "intro_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
