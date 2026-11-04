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
mkdir -p "$root"/{published,state/xfer-results,queue/xfer,queue/filedel,queue/filedesc,queue/kick,users/alice,home}
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
      source "$here/lib/menu.sh"; files_menu; echo "END nav_req=${nav_req:-}"; echo "QUIET=${LOGOUT_QUIET:-0}" ) <"$fifo" >"$out" 2>&1 7>&- &
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
check "list: keys" seen "U) Upload   D) Download   A) Flag   O) Options   Q) Back"
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
check "results: first line shows with no key pressed" seen "  Testing first.zip... OK"
printf 'rejected\tsecond.zip\tduplicate of an existing file\n' >> "$res"
check "results: rejection shows its reason" seen "  Testing second.zip... Rejected: duplicate of an existing file"
printf 'rejected\tbad\033[31m.zip\twhy\033[2J\n' >> "$res"
check "results: control characters are stripped" seen "  Testing bad[31m.zip... Rejected: why[2J"
check "results: no raw escape in a result line" not grep -q "Rejected.*"$'\033' "$out"
check "results: no summary before done" not grep -q 'Finished:' "$out"
printf 'done\n' >> "$res"
check "results: done ends the wait with no key" seen "Finished: 1 published, 2 rejected."
check "results: asks for a description" seen "Enter a description for first.zip."
keys $'\n'
sleep 0.3
keys x
keys q; check "results: back and out" finish
check "results: each line shown once" bash -c '[[ $(grep -c "Testing first.zip... OK" "$1") == 1 ]]' _ "$out"
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
check "view: offers D" seen "D) Download   F) Flag   E) Describe   R) Remove   Q) Back"
check "view: scp is only a side note" seen "scp -O -P 6464 bbs-alice@bbs.piewpiew.se:mid.lha ."
keys d
check "download: last chance first" seen "LAST CHANCE!"
keys $'\n'
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
seen "LAST CHANCE!" >/dev/null
keys $'\n'
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

# --- The rest of the flow gets more files to work with. Newest first: 1 three.txt, 2 two.zip, 3 mid.lha.
ID2=1500000200-bbbbbbbb
ID3=1500000300-cccccccc
printf 'xx' > "$root/published/$ID2"
printf 'user=bbs-bob\nname=two.zip\nsize=2048\ndate=2026-11-04T09:00:00Z\nsha256=0\ndesc=Two line one\ndesc=Two line two\n' > "$root/published/$ID2.meta"
printf 'xxx' > "$root/published/$ID3"
printf 'user=bbs-bob\nname=three.txt\nsize=3\ndate=2026-11-04T09:00:00Z\nsha256=0\n' > "$root/published/$ID3.meta"
flags=$root/home/.bashbbs-flags
logdown() { printf '2026-11-04T11:00:00Z\tbbs-alice\tdown\t%s\t%s\t1\t192.0.2.1\n' "$1" "$2" >> "$root/state/transfers.log"; }
# gone: the menu stops with its input still open.
gone() { local i; for (( i = 0; i < 50; i++ )); do kill -0 "$menu_pid" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
flagkey() { # flagkey <key>: A, then that key once the question is on the screen
    local m
    m=$(wc -l < "$out")
    keys a
    after "$m" "Flag which" >/dev/null
    keys "$1"
    sleep 0.4
}
after() { # after <mark> <text>: the text comes after line <mark> of the screen
    local i
    for (( i = 0; i < 50; i++ )); do
        tail -n +"$(( $1 + 1 ))" "$out" | grep -qF -- "$2" && return 0
        sleep 0.1
    done
    return 1
}

# 12. LAST CHANCE: says what goes, and nothing happens until Enter or G.
start
seen "1)" >/dev/null
keys d; seen "Download which number?" >/dev/null; keys 2
check "last chance: the prompt" seen "LAST CHANCE! (Enter) to Start, (G)oodbye after transfer, (A)bort?"
check "last chance: the file by name" seen "two.zip"
check "last chance: count and size" seen "1 file, 2 KB."
check "last chance: no ticket yet" bash -c '[[ -z $(ls -A "$1") ]]' _ "$root/queue/xfer"
keys $'\e[A'
sleep 0.4
check "last chance: an arrow key does not start it" not grep -q 'Waiting for your browser' "$out"
keys a
sleep 0.4
check "last chance: A aborts" not grep -q 'Waiting for your browser' "$out"
check "last chance: A leaves no ticket" bash -c '[[ -z $(ls -A "$1") ]]' _ "$root/queue/xfer"
keys q; check "last chance: back and out" finish
start
seen "1)" >/dev/null
keys d; seen "Download which number?" >/dev/null; keys 2; seen "LAST CHANCE" >/dev/null; keys q
sleep 0.4
check "last chance: Q aborts too" not grep -q 'Waiting for your browser' "$out"
keys q; finish

# 13. Flags: A toggles, the list marks them, D takes them.
rm -f "$flags"
start
seen "1)" >/dev/null
keys a
check "flag: asks which" seen "Flag which number? (C) clears all:"
keys 2
check "flag: marked in the list" seen " 2)+two.zip"
check "flag: counted" seen "Flagged: 1 file. D takes them."
check "flag: saved" grep -qx "$ID2" "$flags"
check "flag: no temp file left" bash -c '[[ -z $(find "$1" -name ".bashbbs-flags.*") ]]' _ "$root/home"
mark=$(wc -l < "$out")
keys a; after "$mark" "Flag which" >/dev/null; keys 2
check "flag: A again takes it away" after "$mark" " 2) two.zip"
check "flag: gone from the file" not grep -q "$ID2" "$flags"
flagkey 2; flagkey 1
check "flag: a second one" seen " 1)+three.txt"
check "flag: both saved" bash -c '[[ $(wc -l < "$1") == 2 ]]' _ "$flags"
mark=$(wc -l < "$out")
keys d
check "flagged D: asks no number" after "$mark" "LAST CHANCE"
check "flagged D: both files" after "$mark" "2 files, 2 KB."
keys $'\n'
check "flagged D: the wait" after "$mark" "Waiting for your browser"
token=$(newest_ticket)
check "flagged D: ticket has both" bash -c '[[ $(grep -c "^id=" "$1") == 2 ]]' _ "$root/queue/xfer/$token"
logdown "$ID2" two.zip
check "flagged D: one line per file" after "$mark" "  Sent  two.zip"
sleep 0.3
check "flagged D: one is not all" not grep -q 'Downloaded.' "$out"
logdown "$ID3" three.txt
check "flagged D: all sent ends the wait" after "$mark" "Downloaded."
check "flagged D: sent files stop being flagged" bash -c '[[ ! -s $1 ]]' _ "$flags"
mark=$(wc -l < "$out")
keys x
after "$mark" "U) Upload" >/dev/null
flagkey 1; flagkey 2
check "clear: two flagged" bash -c '[[ $(wc -l < "$1") == 2 ]]' _ "$flags"
flagkey c
check "clear: C empties the list" bash -c '[[ ! -s $1 ]]' _ "$flags"
keys q; check "clear: back and out" finish
clear_tickets

# 14. Leaving a flagged D early: what got through is unflagged, the rest stays.
printf '%s\n' "$ID2" "$ID3" > "$flags"
start
seen "1)" >/dev/null
keys d; seen "LAST CHANCE" >/dev/null; keys $'\n'
seen "Waiting for your browser" >/dev/null
logdown "$ID2" two.zip
seen "  Sent  two.zip" >/dev/null
keys q
sleep 0.4
check "left early: the sent one is unflagged" not grep -q "$ID2" "$flags"
check "left early: the other stays" grep -qx "$ID3" "$flags"
check "left early: back at the list" seen "Flagged: 1 file."
keys q; finish
clear_tickets

# 15. A flag file is only a hint: odd lines and removed files drop out.
{ echo "$ID2"; echo "$ID2"; echo "not-an-id"; echo "../../etc/passwd"; echo "1500009999-ffffffff"; echo "$ID"; } > "$flags"
start
check "flag file: only what exists, once each" seen "Flagged: 2 files."
keys q; finish
rm -f "$flags"

# 16. Goodbye: logged out when it is done, or when the link has run out. Q stays.
start
seen "1)" >/dev/null
keys d; seen "Download which number?" >/dev/null; keys 1; seen "LAST CHANCE" >/dev/null; keys g
check "goodbye: says it" seen "You will be logged out when it is done. (Q) stays logged in."
sleep 0.3
check "goodbye: not before the transfer" not grep -q 'END nav_req' "$out"
logdown "$ID3" three.txt
check "goodbye: done" seen "Downloaded."
check "goodbye: leaves with no key" gone
check "goodbye: asks for the log out" grep -qx 'END nav_req=quit' "$out"
check "goodbye: no ad to wait at" grep -qx 'QUIET=1' "$out"
finish
clear_tickets
start
seen "1)" >/dev/null
keys d; seen "Download which number?" >/dev/null; keys 1; seen "LAST CHANCE" >/dev/null; keys g
seen "Waiting for your browser" >/dev/null
sleep 0.2
keys q
sleep 0.4
keys q
gone
check "goodbye: Q stays logged in" grep -q 'END nav_req=$' "$out"
check "goodbye: Q keeps the ad" grep -qx 'QUIET=0' "$out"
finish
clear_tickets
start XFER_TTL_DOWN=1
seen "1)" >/dev/null
keys d; seen "Download which number?" >/dev/null; keys 1; seen "LAST CHANCE" >/dev/null; keys g
check "goodbye: the link runs out" seen "The link has run out."
check "goodbye: also leaves then" gone
check "goodbye: log out then too" grep -qx 'END nav_req=quit' "$out"
finish
clear_tickets

# 17. The description on the file's page, and E.
start
seen "2)" >/dev/null
check "list: first line of the description" seen "Two line one"
check "list: only the first line" not grep -q 'Two line two' "$out"
keys 2
check "view: every line of the description" seen "Two line two"
check "view: F offered, not E or R on someone else's file" seen "D) Download   F) Flag   Q) Back"
keys e; sleep 0.3
check "view: E refused on someone else's file" not grep -q 'Enter a description' "$out"
mark=$(wc -l < "$out")
keys f
check "view: F flags" after "$mark" "F) Unflag"
check "view: F saved" grep -qx "$ID2" "$flags"
keys f
keys q; sleep 0.3
keys 3
check "view: E on your own" seen "D) Download   F) Flag   E) Describe   R) Remove   Q) Back"
keys e
check "describe: asks" seen "Enter a description for mid.lha."
long=$(printf 'y%.0s' {1..70})
keys $'First line\n'"$long"$'\n\n'
check "describe: confirms" seen "Saved. It shows within a minute."
req=$root/queue/filedesc/$ID.desc
check "describe: request written" grep -qx 'First line' "$req"
check "describe: cut at 60" bash -c '[[ $(sed -n 2p "$1" | wc -L) == 60 ]]' _ "$req"
check "describe: nothing half written left" bash -c '[[ -z $(find "$1" -name ".tmp.*") ]]' _ "$root/queue/filedesc"
check "describe: wakes the sorter" bash -c '[[ -n $(ls -A "$1") ]]' _ "$root/queue/kick"
keys x
sleep 0.3
keys q; sleep 0.3; keys q; finish
rm -f "$req"
find "$root/queue/kick" -type f -delete
start
seen "3)" >/dev/null
keys 3; seen "E) Describe" >/dev/null; keys e; seen "Enter a description" >/dev/null
keys $'\n'
sleep 0.4
check "describe: nothing typed, nothing there, no request" test ! -e "$req"
keys q; sleep 0.3; keys q; finish
start
seen "2)" >/dev/null
printf 'user=bbs-alice\nname=two.zip\nsize=2048\ndate=2026-11-04T09:00:00Z\nsha256=0\ndesc=Mine now\n' > "$root/published/$ID2.meta"
: # the list was read before the change: leave and come back
keys q; finish
start
seen "2)" >/dev/null
keys 2; seen "E) Describe" >/dev/null; keys e; seen "Enter a description" >/dev/null
keys $'\n'
check "describe: empty text asks to remove it" seen "Saved."
check "describe: the empty request" bash -c '[[ -e $1 && ! -s $1 ]]' _ "$root/queue/filedesc/$ID2.desc"
keys x; sleep 0.3; keys q; sleep 0.3; keys q; finish
rm -f "$root/queue/filedesc/$ID2.desc"
mv "$root/queue/filedesc" "$root/queue/filedesc.away"
start
seen "3)" >/dev/null
keys 3; seen "E) Describe" >/dev/null; keys e; seen "Enter a description" >/dev/null
keys $'Text\n\n'
check "describe: no queue, says so" seen "Could not save that right now."
keys x; sleep 0.3; keys q; sleep 0.3; keys q; finish
mv "$root/queue/filedesc.away" "$root/queue/filedesc"

# 18. After an upload: what was tested, then a description for what brought none.
start
seen "U) Upload" >/dev/null
keys u
check "testing: says it is no virus scan" seen "This is not a virus scan."
seen "Waiting for your browser" >/dev/null
token=$(newest_ticket)
res=$root/state/xfer-results/$token
A=1500000400-dddddddd B=1500000401-dddddddd C=1500000402-dddddddd
printf 'ok\ta.zip\t%s\tarchive\n' "$A" >> "$res"
check "testing: an archive that opens" seen "  Testing a.zip... OK, the archive opens"
printf 'ok\tb.lha\t%s\tarchive+diz\n' "$B" >> "$res"
check "testing: with a description" seen "  Testing b.lha... OK, the archive opens, description found"
printf 'ok\tc.txt\t%s\n' "$C" >> "$res"
check "testing: a plain file" seen "  Testing c.txt... OK"
check "testing: no question before done" not grep -q 'Enter a description' "$out"
printf 'done\n' >> "$res"
check "describe new: asks for the first" seen "Enter a description for a.zip."
keys $'Text for a\n\n'
check "describe new: skips the one with a FILE_ID.DIZ" seen "Enter a description for c.txt."
check "describe new: never b" not grep -q 'description for b.lha' "$out"
keys $'\n'
sleep 0.4
check "describe new: request written" grep -qx 'Text for a' "$root/queue/filedesc/$A.desc"
check "describe new: an empty answer writes nothing" test ! -e "$root/queue/filedesc/$C.desc"
keys x; sleep 0.3; keys q; check "describe new: back and out" finish
find "$root/queue/filedesc" -type f -delete
clear_tickets
start
seen "U) Upload" >/dev/null
keys u
seen "Waiting for your browser" >/dev/null
token=$(newest_ticket)
printf 'ok\ta.zip\t%s\tarchive\ndone\n' "$A" >> "$root/state/xfer-results/$token"
seen "Enter a description" >/dev/null
check "describe new: end of input stops" finish
clear_tickets

# 19. O: what there is, and nothing to choose yet.
start
seen "O) Options" >/dev/null
keys o
check "options: the web link" seen "Web link"
check "options: scp" seen "scp -O -P 6464 FILE bbs-alice@bbs.piewpiew.se:"
keys x; sleep 0.3
keys q; check "options: back and out" finish

# 20. Many files with descriptions: a page holds what fits. No tty counts as 24 lines,
# so 14 lines for the list: 7 files with a description each. And at most 20 flags.
for n in {10..30}; do
    i=15000010$n-eeeeeeee
    printf 'x' > "$root/published/$i"
    printf 'user=bbs-bob\nname=many%s.txt\nsize=1\ndate=2026-11-04T09:00:00Z\nsha256=0\ndesc=About %s\n' "$n" "$n" > "$root/published/$i.meta"
done
start
check "page: seven fit" seen " 7) many24.txt"
sleep 0.2
check "page: the eighth does not" not grep -q ' 8) many23' "$out"
check "page: N offered" seen "N) More"
mark=$(wc -l < "$out")
keys n
check "page: N goes on from the next file" after "$mark" " 8) many23.txt"
keys q; finish
: > "$flags"
for n in {10..29}; do echo "15000010$n-eeeeeeee" >> "$flags"; done
start
check "flag cap: twenty flagged" seen "Flagged: 20 files."
keys a; seen "Flag which" >/dev/null; keys $'1\n'
check "flag cap: the 21st is refused" seen "You can flag up to 20 files at a time."
keys x; sleep 0.3
check "flag cap: nothing added" bash -c '[[ $(wc -l < "$1") == 20 ]]' _ "$flags"
keys q; finish
rm -f "$flags"

# 21. No files: U is there, D is not.
find "$root/published" -type f -delete
start
check "empty: U offered" seen "U) Upload   O) Options   Q) Back"
check "empty: D not offered" not grep -q 'D) Download' "$out"
keys d
sleep 0.3
check "empty: D does nothing" not grep -q 'Download which' "$out"
keys q; check "empty: back and out" finish

exec 7>&- 2>/dev/null

# The ad waits for Space, so it is left out when nobody may be there.
logout_with() { ( BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb BASHBBS_COLOR=0 BBS_ROOT="$root" HOME="$root/home" bash -c 'source "$1/lib/menu.sh"; ad_run() { echo AD-SHOWN; }; LOGOUT_QUIET=$2; logout_screen' _ "$here" "$1" ) 2>&1; }
check "logout: the ad as usual" grep -q AD-SHOWN <<< "$(logout_with 0)"
check "logout: quiet, no ad" not grep -q AD-SHOWN <<< "$(logout_with 1)"
check "logout: quiet still says bye" grep -q 'Bye\.' <<< "$(logout_with 1)"

echo "xfer_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
