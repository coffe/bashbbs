#!/bin/bash
# Private messages: confirmation, size limits, headers, identity, recipients and
# parallel delivery. Sendmail is a stub that stores what it gets; nothing is delivered.
# Usage: tests/pm_security_test.sh [logfile]   (full log in the file; the
# screen shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/9506b390-481f-488f-a1f9-0e791791c883/scratchpad}
log=${1:-$scratch/pm_security_test.log}
: > "$log"
pass=0; fail=0
hostn=$(hostname)

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }

root=$(mktemp -d "$scratch/pm.XXXXXX")
mkdir -p "$root"/{users/alice,users/bob,users/carol,users/coffe,users/news,t}
for u in alice bob carol coffe news; do : > "$root/users/$u/profile"; done
printf 'carol\ncoffe\n' > "$root/sysops"
cat > "$root/t/sendmail" <<'SH'
#!/bin/bash
d=$(dirname "$0")/delivered
mkdir -p "$d"
[[ ! -e $(dirname "$0")/fail ]] || { cat >/dev/null; exit 1; }
printf '%s\n' "$*" >> "$d/args"
cat > "$(mktemp "$d/msg.XXXXXX")"
SH
chmod +x "$root/t/sendmail"

# run_as <user> <command...>: menu functions as bbs-<user>, with the test identity seam.
run_as() {
    local u=$1; shift
    mkdir -p "$root/home/bbs-$u"
    ( export BBS_ROOT="$root" USER="bbs-$u" BASHBBS_TEST=1 BASHBBS_TEST_ID="bbs-$u" \
          HOME="$root/home/bbs-$u" TERM=dumb BBS_SENDMAIL="$root/t/sendmail"
      source "$here/lib/menu.sh"
      "$@" )
}
reset() { rm -rf "$root/t/delivered" "$root/home"; }
delivered() { ls "$root/t/delivered" 2>/dev/null | grep -c '^msg\.'; }
sent() { ls "$root/home/bbs-alice/Maildir/.Sent/cur" 2>/dev/null | wc -l; }
onemsg() { ls "$root"/t/delivered/msg.* 2>/dev/null | head -n 1; }
ab() { # ab <count> [char]: a string of <count> copies; built per character, so å is one character
    local s='' i
    for ((i = 0; i < $1; i++)); do s+=${2:-a}; done
    printf '%s' "$s"
}

# --- 1. Confirmation and cancel: only an explicit y sends -------------------
reset; printf 'bob\nHej\nText\n.\nn\n\n' | run_as alice mail_write >>"$log" 2>&1
check "confirm: n sends nothing" eq "$(delivered)" 0
reset; printf 'bob\nHej\nText\n.\n\n\n' | run_as alice mail_write >>"$log" 2>&1
check "confirm: empty answer sends nothing" eq "$(delivered)" 0
reset; printf '\n\n\n' | run_as alice mail_write >>"$log" 2>&1
check "confirm: leftover Enter at To, Subject and Body sends nothing" eq "$(delivered)" 0
reset; printf 'bob\nHej\ny\n.\n' | run_as alice mail_write >>"$log" 2>&1
check "confirm: a y inside the body does not confirm" eq "$(delivered)" 0
reset; printf 'bob\nHej\nText\n/cancel\n' | run_as alice mail_write >>"$log" 2>&1
check "cancel: /cancel in the body sends nothing" eq "$(delivered)" 0
reset; printf '/cancel\n' | run_as alice mail_write >>"$log" 2>&1
check "cancel: /cancel at To sends nothing" eq "$(delivered)" 0
reset; printf 'bob\n/cancel\n' | run_as alice mail_write >>"$log" 2>&1
check "cancel: /cancel at Subject sends nothing" eq "$(delivered)" 0
reset; printf 'bob\nHej\nText\n.\ny\n\n' | run_as alice mail_write >>"$log" 2>&1
check "confirm: y sends one message" eq "$(delivered)" 1
check "confirm: y keeps one Sent copy" eq "$(sent)" 1

# --- 2. Subject: 60 characters, no control characters ----------------------
s60=$(ab 60); s61=$(ab 61)
a60=$(ab 60 å); a61=$(ab 61 å)
check "subject: 60 characters accepted" run_as alice mail_subject "$s60"
check "subject: 61 characters rejected" not run_as alice mail_subject "$s61"
check "subject: 60 å accepted (120 bytes)" run_as alice mail_subject "$a60"
check "subject: 61 å rejected" not run_as alice mail_subject "$a61"
check "subject: Swedish text accepted" run_as alice mail_subject "Hälsning åäö"
check "subject: CR rejected" not run_as alice mail_subject $'Hej\rdar'
check "subject: LF rejected" not run_as alice mail_subject $'Hej\ndar'
check "subject: tab rejected" not run_as alice mail_subject $'Hej\tdar'
check "subject: escape character rejected" not run_as alice mail_subject $'Hej\x1b[2J'

# --- 3. Body: 8 192 bytes UTF-8, line ends included -----------------------
x1000=$(ab 1000 x); x183=$(ab 183 x); x184=$(ab 184 x)
body_of() { local i; for i in 1 2 3 4 5 6 7 8; do printf '%s\n' "$x1000"; done; printf '%s\n' "$1"; printf '.\n'; }
body_ok() { body_of "$1" | run_as alice mail_body >/dev/null; }
body_over() { ! body_ok "$1"; }
one_ok() { printf '%s\n.\n' "$1" | run_as alice mail_body >/dev/null; }
one_over() { ! one_ok "$1"; }
check "body: 8 192 bytes accepted" body_ok "$x183"
check "body: 8 193 bytes rejected" body_over "$x184"
a4095=$(ab 4095 å); a4096=$(ab 4096 å)
check "body: 4 095 å (8 190 bytes + line end) accepted" one_ok "$a4095"
check "body: 4 096 å (8 192 bytes + line end) rejected" one_over "$a4096"

# --- 4. Headers: In-Reply-To only when it is a Message-ID, no injection -----
reset; printf 'Hej\n.\ny\n\n' | run_as alice mail_send bob "Rubrik" "<ok-1@$hostn>" >>"$log" 2>&1
check "reply: valid In-Reply-To kept" grep -qxF "In-Reply-To: <ok-1@$hostn>" "$(onemsg)"
reset; printf 'Hej\n.\ny\n\n' | run_as alice mail_send bob "Rubrik" "$(printf '<a>\nBcc: x@y>')" >>"$log" 2>&1
check "reply: newline in In-Reply-To dropped" not grep -q '^Bcc:\|^In-Reply-To' "$(onemsg)"
reset; printf 'Hej\n.\ny\n\n' | run_as alice mail_send bob "Rubrik" "<bad" >>"$log" 2>&1
check "reply: malformed In-Reply-To dropped" not grep -q '^In-Reply-To' "$(onemsg)"
reset; printf 'Hej\n.\ny\n\n' | run_as alice mail_send bob 'Rubrik $(id)' >>"$log" 2>&1
check "subject: shell text stays text" grep -qxF 'Subject: Rubrik $(id)' "$(onemsg)"

# --- 5. Identity: From is the verified login, never $USER -------------------
reset
printf 'Hej\n.\ny\n\n' | ( export BBS_ROOT="$root" USER=bbs-mallory BASHBBS_TEST=1 \
    BASHBBS_TEST_ID=bbs-alice HOME="$root/home/bbs-alice" TERM=dumb BBS_SENDMAIL="$root/t/sendmail"
    source "$here/lib/menu.sh"; mail_send bob "Spoof" ) >>"$log" 2>&1
check "identity: USER=bbs-mallory does not change From" grep -qxF "From: alice@$hostn" "$(onemsg)"
check "identity: no mallory anywhere in the message" not grep -q mallory "$(onemsg)"
reset
printf 'Hej\n.\ny\n\n' | ( export BBS_ROOT="$root" USER=bbs-mallory BASHBBS_TEST=1 \
    HOME="$root/home/bbs-alice" TERM=dumb BBS_SENDMAIL="$root/t/sendmail"
    source "$here/lib/menu.sh"; mail_send bob "Spoof" ) >>"$log" 2>&1
check "identity: without the seam a non-bbs login is refused" eq "$(delivered)" 0
check "identity: refusal says Bad account" grep -q 'Bad account' "$log"

# --- 6. Recipients: registered users only, never sysops or news --------------
reset
for to in coffe carol news bbs-news bbs-bob nope ../bob; do
    printf '%s\n\n' "$to" | run_as alice mail_write >>"$log" 2>&1
done
check "recipients: sysops, news and unknown names get nothing" eq "$(delivered)" 0

# --- 7. Parallel sends: 20 at once, 20 messages and 20 Sent copies ----------
reset
for i in $(seq 20); do
    ( printf 'Hej %s\n.\ny\n\n' "$i" | run_as alice mail_send bob "Par $i" ) >>"$log" 2>&1 &
done
wait
check "parallel: 20 sends give 20 delivered messages" eq "$(delivered)" 20
check "parallel: 20 sends give 20 Sent copies" eq "$(sent)" 20

# --- 8. Top bar: all five keys, no line wider than the terminal -------------
for w in 40 60 80; do
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb
      source "$here/lib/menu.sh"; term_width() { echo "$w"; }; top_bar "[Q] Back" ) > "$root/bar-$w.txt" 2>>"$log"
    check "top bar $w: no line wider than $w" awk -v w="$w" 'length($0) > w { exit 1 }' "$root/bar-$w.txt"
    check "top bar $w: keys B, G, M, Q, W present" eq "$(grep -o '\[[BGMQW]\]' "$root/bar-$w.txt" | sort | tr -d '\n')" "[B][G][M][Q][W]"
done

echo "pm_security_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
