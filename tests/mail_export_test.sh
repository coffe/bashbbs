#!/bin/bash
# Mail archive and mail export: A archives, D in the Archive goes to Trash, E makes a zip
# snapshot with a threaded text export. Temporary BBS_ROOT and HOME; keys go through a fifo.
# Usage: tests/mail_export_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/mail_export_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/mailexp.XXXXXX")
trap 'exec 7>&- 2>/dev/null; kill $menu_pid 2>/dev/null; rm -rf "$root"' EXIT
mkdir -p "$root"/{state,queue/xfer,users/alice,home/Maildir/{cur,new,tmp,.Sent/cur,.Trash/cur,.Archive/cur}}
H=$root/home/Maildir
printf 'name=Alice\n' > "$root/users/alice/profile"
msg() { # msg <file> <id> <reply> <from> <to> <subject> <date>
    { echo "Message-ID: <$2@h>"; [[ -n $3 ]] && echo "In-Reply-To: <$3@h>"
      printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\n\nbody of %s\n' "$4" "$5" "$6" "$7" "$2"; } > "$1"; }
msg "$H/cur/m1:2,S" m1 "" bob@bbs.localdomain alice@bbs.localdomain "Plans" "Mon, 02 Nov 2026 10:00:00 +0000"
msg "$H/.Sent/cur/m2:2,S" m2 m1 alice@bbs.localdomain bob@bbs.localdomain "Re: Plans" "Mon, 02 Nov 2026 11:00:00 +0000"
msg "$H/cur/m3:2,S" m3 "" bob@bbs.localdomain alice@bbs.localdomain "Zebra topic" "Tue, 03 Nov 2026 10:00:00 +0000"
msg "$H/.Trash/cur/m4:2,S" m4 "" bob@bbs.localdomain alice@bbs.localdomain "Trashedmail" "Wed, 04 Nov 2026 10:00:00 +0000"

fifo=$root/keys; mkfifo "$fifo"; out=$root/screen; menu_pid=
start() { : > "$out"; exec 7<>"$fifo"
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100 XFER_POLL=0.1 BBS_MAILEXPORT="$here/lib/mailexport.py"
      source "$here/lib/menu.sh"; mail_menu; echo END ) <"$fifo" >"$out" 2>&1 7>&- &
    menu_pid=$!; }
keys() { printf '%s' "$1" >&7; }
seen() { local i; for (( i = 0; i < 50; i++ )); do grep -qF -- "$1" "$out" && return 0; sleep 0.1; done; return 1; }
finish() { exec 7>&-; local i; for (( i = 0; i < 50; i++ )); do kill -0 "$menu_pid" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
gone() { ! compgen -G "$1" >/dev/null; }
here_() { compgen -G "$1" >/dev/null; }

# X on an open message: only that message's thread (m1 + the Sent reply m2, not m3).
start
keys 1
seen "Zebra topic" >/dev/null
keys 2          # the Inbox lists threads newest first: 1 is m3, 2 is the m1+m2 thread
check "thread: X offered" seen "X) Export thread"
keys x
check "thread: link shown" seen "x.cgi/"
tok1=$(ls "$root/queue/xfer" | grep -v '\.snap$' | head -n 1)
check "thread: snap holds one thread" bash -c 'python3 - "$1" <<PY
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); t = z.read(sorted(z.namelist())[1]).decode()
assert "1 threads, 2 messages" in t and "body of m2" in t and "Zebra" not in t, t[-400:]
PY' _ "$root/queue/xfer/$tok1.snap"
keys q; keys q; keys q; finish

# A in the Inbox: open thread 1 (m3, the newest), archive it.
start
check "menu: Archive item" seen "6) Archive"
check "menu: E key" seen "E) Export"
keys 1
seen "Zebra topic" >/dev/null
keys 1          # first Inbox thread is m3
seen "A) Archive" >/dev/null || true
keys a
check "archive: one-line message" seen "Archived."
keys x; keys q
check "archive: moved to .Archive/cur" here_ "$H/.Archive/cur/m3*"
check "archive: gone from Inbox" gone "$H/cur/m3*"
keys 6
check "archive: listed under 6" seen "Zebra topic"
keys 1
seen "D) Delete" >/dev/null
keys d; keys y
check "archive: D moves to Trash" seen "Moved to Trash."
keys x; keys q
check "archive delete: file in Trash" here_ "$H/.Trash/cur/m3*"
check "archive delete: gone from Archive" gone "$H/.Archive/cur/m3*"

# E: a snapshot beside the ticket.
keys e
check "export: link shown" seen "x.cgi/"
tok=$(ls "$root/queue/xfer" | grep -v '\.snap$' | grep -vx "$tok1" | head -n 1)
check "export: ticket says export=mail" grep -qx 'export=mail' "$root/queue/xfer/$tok"
snap=$root/queue/xfer/$tok.snap
check "export: snap is a zip with both members" bash -c 'python3 - "$1" <<PY
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); n = sorted(z.namelist())
assert len(n) == 2 and n[0].endswith(".cp437.txt") and n[1].endswith(".txt"), n
t = z.read(n[1]).decode()
assert "Trashedmail" not in t and "Plans" in t
assert t.index("body of m1") < t.index("body of m2")
assert t.count("THREAD") == 1 and "Zebra" not in t  # m3 was deleted
PY' _ "$snap"
keys q; keys q; finish
echo "mail_export_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
