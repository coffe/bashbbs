#!/bin/bash
# U and D in the Files section: the ticket, the link, the wait and its ways out.
# Temporary BBS_ROOT, no accounts needed. Keys go through a fifo, so a test can look at
# the screen before any key is pressed. Usage: tests/xfer_menu_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/xfer_menu_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/xfermenu.XXXXXX")
mkdir -p "$root"/{published,state/xfer-results,queue/xfer,queue/filedel,users/alice,home}
printf 'name=Alice\n' > "$root/users/alice/profile"
: > "$root/state/transfers.log"
ID=1500000100-aaaaaaaa
printf 'x' > "$root/published/$ID"
printf 'user=bbs-alice\nname=mid.lha\nsize=1\ndate=2026-11-04T09:00:00Z\nsha256=0\n' > "$root/published/$ID.meta"

fifo=$root/keys
mkfifo "$fifo"
out=$root/screen
menu_pid=

# start [VAR=value...]: the Files section with no keys yet.
start() {
    : > "$out"
    exec 7<>"$fifo"
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100 XFER_POLL=0.1 "$@"
      source "$here/lib/menu.sh"; files_menu ) <"$fifo" >"$out" 2>&1 7>&- &
    menu_pid=$!
}
keys() { printf '%s' "$1" >&7; }
# Close our end: end of input for the menu. It has to stop by itself.
finish() {
    exec 7>&-
    local i
    for (( i = 0; i < 100; i++ )); do
        kill -0 "$menu_pid" 2>/dev/null || { wait "$menu_pid" 2>/dev/null; return 0; }
        sleep 0.1
    done
    kill "$menu_pid" 2>/dev/null
    return 1
}
seen() { # seen <text>: waits up to 5 s for the text on the screen
    local i
    for (( i = 0; i < 50; i++ )); do
        grep -qF -- "$1" "$out" && return 0
        sleep 0.1
    done
    return 1
}
newest_ticket() { ls -t "$root/queue/xfer" | head -n 1; }
clear_tickets() { find "$root/queue/xfer" -type f -delete; }

# 1. The list offers the keys, scp stays as a side note.
start
check "list: keys" seen "U) Upload   D) Download   Q) Back"
check "list: scp is only a side note" seen "Also works: scp -O -P 6464 FILE bbs-alice@bbs.piewpiew.se:"
keys q; check "list: Q leaves" finish

# 2. U: a ticket, a link on its own line, Q always answers.
start
seen "U) Upload" >/dev/null
keys u
check "upload: waits for the browser" seen "Waiting for your browser... (Q) back to menu."
check "upload: says the transfer goes on" seen "The transfer goes on if you leave."
check "upload: shows the limits" seen "up to 10.0 MB"
token=$(newest_ticket)
check "ticket: token has the form x.cgi accepts" bash -c '[[ $1 =~ ^[A-Za-z0-9_-]{22}$ ]]' _ "$token"
check "ticket: says up" grep -qx 'dir=up' "$root/queue/xfer/$token"
check "ticket: no id lines for an upload" not grep -q '^id=' "$root/queue/xfer/$token"
check "ticket: www-data can read it" bash -c '[[ $(stat -c %a "$1") == 644 ]]' _ "$root/queue/xfer/$token"
check "upload: the link alone on a line" grep -qx "https://bbs.piewpiew.se/x.cgi/$token" "$out"
check "upload: link fits 80 columns" bash -c '(( ${#1} <= 80 ))' _ "https://bbs.piewpiew.se/x.cgi/$token"
keys x
sleep 0.3
check "upload: other keys do not leave" not grep -q 'Download which' "$out"
mark=$(wc -l < "$out")
keys q
check "upload: Q goes back to the list" bash -c 'for i in {1..50}; do [[ $(tail -n +$(($2 + 1)) "$1" | grep -c "U) Upload") -gt 0 ]] && exit 0; sleep 0.1; done; exit 1' _ "$out" "$mark"
check "upload: the ticket stays after Q" test -e "$root/queue/xfer/$token"
keys q; check "upload: leaves cleanly" finish
clear_tickets

# 3. Results show without any key being pressed.
start
seen "U) Upload" >/dev/null
keys u
seen "Waiting for your browser" >/dev/null
token=$(newest_ticket)
res=$root/state/xfer-results/$token
printf 'ok\tfirst.zip\t1500000200-bbbbbbbb\n' >> "$res"
check "results: first line shows with no key pressed" seen "OK        first.zip"
printf 'rejected\tsecond.zip\tduplicate of an existing file\n' >> "$res"
check "results: rejection shows its reason" seen "Rejected  second.zip: duplicate of an existing file"
printf 'rejected\tbad\033[31m.zip\twhy\033[2J\n' >> "$res"
check "results: control characters are stripped" seen "Rejected  bad[31m.zip: why[2J"
check "results: no raw escape in a result line" not grep -q "Rejected.*"$'\033' "$out"
check "results: no summary before done" not grep -q 'Finished:' "$out"
printf 'done\n' >> "$res"
check "results: done ends the wait with no key" seen "Finished: 1 published, 2 rejected."
keys x
keys q; check "results: back and out" finish
check "results: each line shown once" bash -c '[[ $(grep -c "OK        first.zip" "$1") == 1 ]]' _ "$out"
clear_tickets

# 4. Refused before a link is made.
start UPLOAD_USER_QUOTA=0
seen "U) Upload" >/dev/null
keys u
check "closed: says why" seen "Uploads are closed right now: user quota exceeded."
check "closed: no ticket" bash -c '[[ -z $(ls -A "$1") ]]' _ "$root/queue/xfer"
keys x; keys q; check "closed: back and out" finish

# 5. The link runs out.
start XFER_TTL_UP=1
seen "U) Upload" >/dev/null
keys u
check "expired: says so" seen "The link has run out. Press U for a new one."
keys x; keys q; check "expired: back and out" finish
clear_tickets

# 6. End of input while waiting: the menu stops, no spinning.
start
seen "U) Upload" >/dev/null
keys u
seen "Waiting for your browser" >/dev/null
check "end of input: the wait stops" finish
clear_tickets

# 7. No queue directory: an answer, not a crash.
mv "$root/queue/xfer" "$root/queue/xfer.away"
start
seen "U) Upload" >/dev/null
keys u
check "no ticket: says so" seen "Could not make a link right now."
keys x; keys q; check "no ticket: back and out" finish
mv "$root/queue/xfer.away" "$root/queue/xfer"

# 8. D in the file view.
start
seen "1)" >/dev/null
keys 1
check "view: offers D" seen "D) Download   R) Remove   Q) Back"
check "view: scp is only a side note" seen "scp -O -P 6464 bbs-alice@bbs.piewpiew.se:mid.lha ."
keys d
seen "Waiting for your browser" >/dev/null
token=$(newest_ticket)
check "download: ticket says down" grep -qx 'dir=down' "$root/queue/xfer/$token"
check "download: ticket names the file" grep -qx "id=$ID" "$root/queue/xfer/$token"
check "download: not finished before the log says so" not grep -q 'Downloaded.' "$out"
# Someone else's download of the same file does not count, nor another file of ours.
printf '2026-11-04T10:00:00Z\tbbs-bob\tdown\t%s\tmid.lha\t1\t192.0.2.1\n' "$ID" >> "$root/state/transfers.log"
printf '2026-11-04T10:00:00Z\tbbs-alice\tdown\t1500000999-cccccccc\tother\t1\t192.0.2.1\n' >> "$root/state/transfers.log"
sleep 0.4
check "download: other lines in the log do not count" not grep -q 'Downloaded.' "$out"
printf '2026-11-04T10:00:01Z\tbbs-alice\tdown\t%s\tmid.lha\t1\t192.0.2.1\n' "$ID" >> "$root/state/transfers.log"
check "download: the log line ends the wait, no key" seen "Downloaded."
keys x
check "view: count goes up after the download" seen "Downloads:  1"
keys q; seen "U) Upload" >/dev/null; keys q; check "download: back and out" finish
clear_tickets

# 9. An earlier download of the same file does not end a new wait at once.
start
seen "1)" >/dev/null
keys d
check "list D: asks for a number" seen "Download which number?"
keys 1
check "list D: wait starts, the old log line does not end it" seen "Waiting for your browser"
sleep 0.4
check "list D: still waiting" not grep -q 'Downloaded.' "$out"
token=$(newest_ticket)
check "list D: ticket names the file" grep -qx "id=$ID" "$root/queue/xfer/$token"
keys q
sleep 0.3
keys d
seen "Download which number?" >/dev/null
keys x
sleep 0.3
keys q; check "list D: a wrong key goes back" finish
clear_tickets

# 10. A machine with its own address.
printf 'http://192.0.2.9/x.cgi\n' > "$root/xfer-url"
start
seen "U) Upload" >/dev/null
keys u
seen "Waiting for your browser" >/dev/null
token=$(newest_ticket)
check "xfer-url: replaces the public address" grep -qx "http://192.0.2.9/x.cgi/$token" "$out"
keys q; seen "U) Upload" >/dev/null; keys q; finish
mv "$root/xfer-url" "$root/xfer-url.away"
clear_tickets

# 11. No files: U is there, D is not.
find "$root/published" -type f -delete
start
check "empty: U offered" seen "U) Upload   Q) Back"
check "empty: D not offered" not grep -q 'D) Download' "$out"
keys d
sleep 0.3
check "empty: D does nothing" not grep -q 'Download which' "$out"
keys q; check "empty: back and out" finish

exec 7>&- 2>/dev/null
echo "xfer_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
