#!/bin/bash
# BashBBS line editor (rline_edit, rline_clean in lib/menu.sh): arrow keys move within the
# line instead of printing escape codes, Backspace/Delete/Home/End/Ctrl-A/E/K/U work,
# up/down and other keys are ignored, readline keys that run shell code (Esc Ctrl-E,
# Ctrl-X Ctrl-E) do nothing, Ctrl-D on an empty line ends input, and piped input has
# escape codes and control characters removed. Runs in a real pty against a temporary
# root and HOME. Usage: tests/rline_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/rline_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]] || { printf 'got: %q\nwant: %q\n' "$1" "$2"; return 1; }; }

root=$(mktemp -d "$scratch/rline.XXXXXX")
mkdir -p "$root/home"
lib=$here/lib/menu.sh
drv=$root/drive.py
cat > "$drv" <<'PY'
import os, pty, time, select, sys, signal, re, fcntl, termios, struct
lib, d = sys.argv[1:3]
keys = [k.encode("utf-8").decode("unicode_escape").encode("latin-1") for k in sys.argv[3:]]
env = dict(os.environ, RL_PROMPT=os.environ.get("RL_PROMPT", "> "), BBS_ROOT=d, HOME=d + "/home", BASHBBS_TEST="1", BASHBBS_TEST_ID="bbs-rltest")
pid, m = pty.fork()
cols = int(os.environ.get("RL_COLS", "80")); prompt = os.environ.get("RL_PROMPT", "> ")
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
    os.execvpe("bash", ["bash", "--norc", "-c",
        'source "$1"; rline x "$RL_PROMPT"; echo "rc=$?"; printf "GOT[%s]\\n" "$x"', "x", lib], env)
out = b""
def rd(t):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([m], [], [], 0.05)
        if r:
            try: out += os.read(m, 4096)
            except OSError: return
rd(0.8)
for k in keys: os.write(m, k); rd(0.3)
rd(0.5)
try: os.kill(pid, signal.SIGKILL)
except OSError: pass
os.waitpid(pid, 0)
t = out.decode(errors="replace")
res = [l.strip() for l in t.splitlines() if l.startswith(("rc=", "GOT["))]
if os.environ.get("RL_COLS"):
    # what stays on screen: the text after the last \r on each line, without colour codes
    rows = [l.rstrip("\r").split("\r")[-1] for l in re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", t).split("\n")]
    res.append("own-line" if prompt + "\r\n" in t else "same-line")
    rows = [r for r in rows if not r.startswith(("rc=", "GOT["))]   # the driver's own output
    res.append("fits" if max(len(r) for r in rows) <= cols else "too-wide")
print(" ".join(res))
PY
drive() { python3 "$drv" "$lib" "$root" "$@"; }
L='\x1b[D'
# Keys are written one argument at a time; \xNN are bytes (UTF-8 given as its bytes).

check "left arrow inserts mid-line, End, up/down ignored" eq \
    "$(drive hej "$L" "$L" X '\x1b[F' '!' '\x1b[A' '\x1b[B' '\r')" "rc=0 GOT[hXej!]"
check "backspace and Delete mid-line" eq \
    "$(drive abcd "$L" '\x7f' '\x1b[3~' '\r')" "rc=0 GOT[ab]"
check "Home then Ctrl-K clears the line" eq \
    "$(drive abc '\x1b[H' '\x0b' Z '\r')" "rc=0 GOT[Z]"
check "Ctrl-A, Ctrl-E, Ctrl-U" eq \
    "$(drive bc '\x01' a '\x05' d '\x15' e '\r')" "rc=0 GOT[e]"
check "UTF-8 letters move as one character" eq \
    "$(drive '\xc3\xa5\xc3\xa4\xc3\xb6' "$L" '\xc3\xa9' '\r')" "rc=0 GOT[åäéö]"
check "tab becomes space, PgUp and Ctrl-arrow ignored" eq \
    "$(drive 'a\tb' '\x1b[5~' '\x1b[1;5C' '\r')" "rc=0 GOT[a b]"
check "Ctrl-D on an empty line ends input" eq "$(drive '\x04')" "rc=1"
check "Esc Ctrl-E does not expand shell code" eq \
    "$(drive "\$(touch $root/pwn)" '\x1b\x05' '\r')" "rc=0 GOT[\$(touch $root/pwn)]"
check "Ctrl-X Ctrl-E opens no editor" eq "$(drive hej '\x18\x05' '\r')" "rc=0 GOT[hej]"
check "no file created by shell keys" eq "$(ls "$root" | grep -c pwn)" "0"
long="Name (a-z, 0-9, - and _; 2-24 chars): "
check "40 columns, long prompt: input on its own line, no row too wide" eq \
    "$(RL_COLS=40 RL_PROMPT=$long drive nyttbrade_med_langt_namn '\r')" "rc=0 GOT[nyttbrade_med_langt_namn] own-line fits"
check "40 columns, short prompt: input on the same line, scrolls" eq \
    "$(RL_COLS=40 RL_PROMPT='Subject: ' drive "$(printf 'x%.0s' {1..50})" '\r')" "rc=0 GOT[$(printf 'x%.0s' {1..50})] same-line fits"

# Piped (non-tty) input: escape codes and control characters are removed.
piped=$(printf 'ab\033[Dc\033OA\x01d\te\n' | env BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 \
    BASHBBS_TEST_ID=bbs-rltest bash -c 'source "$1"; rline x "> " 2>/dev/null; printf "%s" "$x"' x "$lib")
check "piped input is cleaned" eq "$piped" "abcd e"

echo "pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
