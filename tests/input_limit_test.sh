#!/bin/bash
# Tests for the input line limit (rline, read_body in lib/menu.sh): a line over
# INPUT_MAX is rejected, the rest of it is discarded up to its Enter and never
# reaches the next read, memory stays bounded, and a terminal still edits with
# backspace. Only the helper block and two functions are sourced, not the menu.
# Usage: tests/input_limit_test.sh   (failures and the summary are printed)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $d"; fi
}

lib=$(mktemp)
trap 'rm -f "$lib"' EXIT
{ echo 'safe() { LC_ALL=C.UTF-8 sed "s/[[:cntrl:]]//g"; }'
  sed -n '/^# ---- Input lines/,/^# One key, no draining/p' "$here/lib/menu.sh" | sed '$d'
  sed -n '/^read_body() {/,/^}/p' "$here/lib/menu.sh"
} > "$lib"

eq() { [[ $1 == "$2" ]]; }
rep() { head -c "$1" /dev/zero | tr '\0' a; }

# two <stdin-producer> : rline twice, print "<rc1>|<a>|<long1>|<rc2>|<b>"
two() { bash -c 'source "$1"; rline a; r1=$?; l=$RLINE_LONG; rline b; echo "$r1|$a|$l|$?|$b"' _ "$lib"; }

# $INPUT_MAX is 8192: lengths around the limit
check "short line is trimmed" eq "$(printf '  hi  \nnext\n' | two)" "0|hi||0|next"
check "exactly the limit fits" eq "$(printf '%s\nnext\n' "$(rep 8192)" | two | cut -d'|' -f1,3-)" "0||0|next"
check "one over is rejected, next line intact" eq "$(printf '%s\nnext\n' "$(rep 8193)" | two)" "0||1|0|next"
check "100 KB line rejected, next line intact" eq "$(printf '%s\nnext\n' "$(rep 100000)" | two)" "0||1|0|next"
for extra in 4095 4096 4097 8191 8192; do
    check "limit+$extra then next line" eq "$(printf '%s\nnext\n' "$(rep $((8192 + extra)))" | two)" "0||1|0|next"
done
check "rest of a long line is not read as input" eq "$(printf '%sQ\nnext\n' "$(rep 8192)" | two)" "0||1|0|next"
check "line at end of input without Enter gives 1" bash -c 'source "$1"; printf "abc" | { rline x; [[ $? -eq 1 ]]; }' _ "$lib"
check "8192 chars then end of input gives 1" bash -c 'source "$1"; head -c 8192 /dev/zero | tr "\0" a | { rline x; [[ $? -eq 1 ]]; }' _ "$lib"
check "raw keeps blanks" eq "$(printf '  hi  \n' | bash -c 'source "$1"; rline x "" raw; printf "[%s]" "$x"' _ "$lib")" "[  hi  ]"
check "empty line is empty, not long" eq "$(printf '\nnext\n' | two)" "0|||0|next"

# 6 MB without any Enter: finishes, bounded memory, nothing left over
t0=$SECONDS
out=$(head -c 6000000 /dev/zero | tr '\0' a | bash -c 'ulimit -v 200000; source "$1"; rline a; echo "$?|${#a}|$RLINE_LONG"' _ "$lib")
check "6 MB without Enter: returns, flagged long, within 200 MB" eq "$out" "0|0|1"
check "that took under 20 s" test $((SECONDS - t0)) -lt 20

# read_body: a long line is skipped with a notice, the other lines and the end dot survive
body=$(printf 'one\n%s\ntwo\n.\nAFTER\n' "$(rep 9000)" | bash -c 'source "$1"; read_body 2>/dev/null' _ "$lib")
check "read_body skips the long line" eq "$body" $'one\ntwo'
check "read_body notice goes to stderr" bash -c 'source "$1"; printf "%s\n.\n" "$2" | read_body 2>&1 >/dev/null | grep -q "too long"' _ "$lib" "$(rep 9000)"
nolines=$(rep 9000 | bash -c 'source "$1"; read_body | wc -c' _ "$lib")
check "read_body: endless line gives no body" eq "$nolines" "0"

# A terminal: the kernel edits the line (backspace) and the limit applies after it
tty() { python3 -I - "$lib" "$1" <<'PY'
import os, pty, sys, time, select
lib, data = sys.argv[1], sys.argv[2].encode().decode('unicode_escape').encode('latin1')
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', '-c', 'source "$1"; rline x "> "; echo "[$x][$RLINE_LONG]"', '_', lib])
time.sleep(0.3); os.write(fd, data)
out = b''; end = time.time() + 5
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try: chunk = os.read(fd, 65536)
        except OSError: break
        if not chunk: break
        out += chunk
    elif b']' in out and out.rstrip().endswith(b']'): break
print(out.decode('latin1').replace('\r', ' ').split('\n')[-2 if out.endswith(b'\n') else -1].strip()[-40:] if False else out.decode('latin1').replace('\r',''))
PY
}
r=$(tty 'abc\r'); check "tty: plain line read" grep -q '\[abc\]\[\]' <<<"$r"
r=$(tty 'ab\x7fc\r'); check "tty: backspace edits the line" grep -q '\[ac\]\[\]' <<<"$r"
r=$(tty '  spaced  \r'); check "tty: blanks trimmed" grep -q '\[spaced\]\[\]' <<<"$r"

echo "input_limit_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
