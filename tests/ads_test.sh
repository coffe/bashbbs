#!/bin/bash
# BashBBS Ads 1.0 (ad_pick, ad_remember, ad_run in lib/menu.sh): one ad after Goodbye,
# never the same ad twice in a row, Space ends it, end of input ends it, no ads means no
# screen, and the Goodbye screen is unchanged. Runs against a temporary root and HOME;
# the screens run in a real pty at 80 columns. Usage: tests/ads_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/ads_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }

root=$(mktemp -d "$scratch/ads.XXXXXX")
home=$root/home; mkdir -p "$home" "$root/etc/ads"
lib=$here/lib/menu.sh
ads=$root/etc/ads

# Runs one function of lib/menu.sh with the temp root and HOME.
menu_fn() { # menu_fn <lib> <command...>
    local l=$1; shift
    env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-adtest bash -c 'source "$1"; shift; "$@"' x "$l" "$@"
}
pick() { menu_fn "$lib" ad_pick; }

# 1. No ads: nothing is picked.
check "no ads: nothing picked" eq "$(pick)" ""

# 2. One ad: always that one, also after it was shown.
printf '%s\n' '   _   _ _ _' '  | |_(_) |_' '  | __| | __|' '' '  Call the sysop. 80 columns.' > "$ads/a.txt"
check "one ad: picked" eq "$(pick)" "a.txt"
menu_fn "$lib" ad_remember a.txt
check "one ad: still picked after it was shown" eq "$(pick)" "a.txt"

# 3. Several ads: never the last one at once, and every other one comes up.
printf 'Ad B\n' > "$ads/b.txt"; printf 'Ad C\n' > "$ads/c.txt"
picks=$(for i in $(seq 300); do pick; done)
check "several ads: the last one is not picked at once" eq "$(printf '%s\n' "$picks" | grep -cx a.txt)" 0
check "several ads: both others come up" bash -c 'printf "%s\n" "$1" | grep -qx b.txt && printf "%s\n" "$1" | grep -qx c.txt' x "$picks"

# 4. Bad files are skipped and never block the rest.
printf 'Bad\n' > "$ads/Bad.TXT"; ln -s "$ads/a.txt" "$ads/link.txt"
head -c 17000 /dev/zero | tr '\0' x > "$ads/big.txt"; printf 'no ext\n' > "$ads/noext"
picks=$(for i in $(seq 300); do pick; done)
check "bad names, symlinks and big files are never picked" eq "$(printf '%s\n' "$picks" | grep -cxE 'Bad.TXT|link.txt|big.txt|noext')" 0

# 5. The memory file: whole name, no temp files left behind.
menu_fn "$lib" ad_remember c.txt
check "memory holds the name" eq "$(head -n 1 "$home/.bashbbs-ad")" "c.txt"
check "no temp files after a write" eq "$(ls -A "$home" | grep -c '^\.bashbbs-ad\.')" 0

# 6. Overlapping logouts: 30 writes at once leave one whole name and no temp files.
for i in $(seq 30); do
    if (( i % 2 )); then menu_fn "$lib" ad_remember b.txt & else menu_fn "$lib" ad_remember c.txt & fi
done
wait
check "30 overlapping writes leave one whole name" eq "$(wc -l < "$home/.bashbbs-ad")" 1
check "the file holds b.txt or c.txt" bash -c 'grep -qxE "b.txt|c.txt" "$1"' x "$home/.bashbbs-ad"
check "no temp files after overlapping writes" eq "$(ls -A "$home" | grep -c '^\.bashbbs-ad\.')" 0

# 7. Goodbye is unchanged against the committed version.
mkdir -p "$root/head" && git -C "$here" archive HEAD lib | tar -x -C "$root/head"
check "goodbye screen unchanged" cmp -s <(menu_fn "$root/head/lib/menu.sh" goodbye) <(menu_fn "$lib" goodbye)

# 8. Screens in a pty at 80 columns: Space ends it, end of input ends it, no ads is silent.
drv=$root/ads_drv.py
cat > "$drv" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
LIB, ROOT, HOME, MODE = sys.argv[1:5]
ads = [n for n in os.listdir(ROOT + "/etc/ads")]
art = open(ROOT + "/etc/ads/" + ads[0], "rb").read() if ads else b"\x00none"
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
env = dict(os.environ, BBS_ROOT=ROOT, HOME=HOME, BASHBBS_TEST="1", BASHBBS_TEST_ID="bbs-adtest", TERM="xterm")
p = subprocess.Popen(["bash", "-c", 'source "$1"; ad_run; echo DONE', "x", LIB],
                     stdin=s, stdout=s, stderr=s, env=env, start_new_session=True)
os.close(s)
out, end, sent = b"", time.time() + 5, False
while time.time() < end:
    r, _, _ = select.select([m], [], [], 0.1)
    if r:
        try:
            d = os.read(m, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
    if MODE != "none" and not sent and b"[Space] Bye" in out:
        sent = True
        if MODE == "space":
            os.write(m, b" ")
        else:
            break
    if p.poll() is not None and not r:
        break
os.close(m)
try:
    rc = p.wait(timeout=3)
except subprocess.TimeoutExpired:
    p.kill(); rc = "HANG"
art_ok = int(art.replace(b"\r", b"") in out.replace(b"\r", b"")) if ads else 0
print("RESULT %s rc=%s art=%d bye=%d done=%d" % (MODE, rc, art_ok, int(b"[Space] Bye" in out), int(b"DONE" in out)))
PY
pty_root=$root/pty; mkdir -p "$pty_root/etc/ads" "$pty_root/home"
cp "$ads/a.txt" "$pty_root/etc/ads/"
check "the ad is 80 columns or less" bash -c 'test "$(awk "{ if (length > m) m = length } END { print m }" "$1")" -le 80' x "$ads/a.txt"
check "space: ad shown unchanged, Space ends it, logout completes" eq \
    "$(python3 "$drv" "$lib" "$pty_root" "$pty_root/home" space)" "RESULT space rc=0 art=1 bye=1 done=1"
# Input closed mid-screen: the shell gets SIGHUP (rc=-1) and must not hang (rc=HANG).
check "end of input: logout does not hang" bash -c \
    'python3 "$1" "$2" "$3" "$4" eof | grep -qE "^RESULT eof rc=-?[0-9]+ art=1 bye=1 done=0$"' x \
    "$drv" "$lib" "$pty_root" "$pty_root/home"
empty_root=$root/empty; mkdir -p "$empty_root/etc/ads" "$empty_root/home"
check "no ads: no screen, logout completes" eq \
    "$(python3 "$drv" "$lib" "$empty_root" "$empty_root/home" none)" "RESULT none rc=0 art=0 bye=0 done=1"

echo "pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
