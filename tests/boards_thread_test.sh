#!/bin/bash
# Threads on boards: the list shows one row per thread (subject of the root, post count,
# "*" when a post is newer than the last login), a thread opens at its first new post
# and moves with Space / P, a reply gets "Re:" once and an optional quote of up to 6
# lines (existing ">" lines skipped), the colour of new and old rows, the Reply-mail
# switch in My account, and the reply mail sent by the publisher (not on opt-out,
# self-reply, deleted or missing parent, unknown account, non-member of a private board).
# Everything uses a temporary BBS_ROOT; sendmail is a stub. Usage: tests/boards_thread_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/boards_thread_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }
has() { grep -q -- "$2" "$1"; }
fits() { tr -d '\r' < "$1" | awk -v w="$2" 'length($0) > w { bad = 1 } END { exit bad }'; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/bt.XXXXXX")
out=$(mktemp -d "$scratch/btout.XXXXXX")
ESC=$'\033'
T0=1500000000
mkdir -p "$root"/{boards/general,boards/priv,meta,queue/incoming,home,mail,t}

# mk <n> <id> <parent|-> <active|deleted> [subject]: boards/general/<T0+10n>-<id>.msg
mk() {
    local f=$root/boards/general/$((T0 + 10 * $1))-$2.msg subj=${5:-"Post $2"} extra=""
    [[ $4 == deleted ]] && { subj="[deleted]"; extra="Deleted: 2017-07-14T05:00:00+00:00"$'\n'; }
    {
        printf 'Msgid: %s\nAuthor: bob\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: %s\n' "$2" "$subj"
        [[ $3 != - ]] && printf 'Parent: %s\n' "$3"
        printf '%s\n' "$extra"
        [[ $4 == deleted ]] || printf 'Body of %s\n' "$2"
    } > "$f"
}
#  n id parent state
mk 1 r1 -  active  "Sommarens synthar"   # thread 1: r1 <- a <- b (reply to a reply)
mk 2 a1 r1 active
mk 3 b1 a1 active
mk 25 r2 - active "Lone thread"          # thread 2: no replies
mk 4 d3 -  deleted                         # thread 3: deleted root with an active reply
mk 5 c3 d3 active
mk 6 l1 nope active "Orphan"              # Parent that does not exist -> its own thread
mk 7 g1 -  deleted                         # deleted, nothing below -> not listed
# files: r1=10 a1=20 b1=30 r2=250 d3=40 c3=50 l1=60 (g1 hidden). Order by last activity:
# r2(250) l1(60) d3-thread(50) r1-thread(30)

lib() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
          BASHBBS_SEEN_PREV="${SEEN:-}" BASHBBS_COLOR="${COL:-0}" COLUMNS=80
          source "$here/lib/menu.sh"; "$@" ); }
roots() { lib board_threads "$@" | awk -F'\t' '{ n = split($1, p, "-"); sub(/\.msg$/, "", p[n]); printf "%s:%s:%s:%s ", p[n], $2, $3, $4 }'; }

# 1. Grouping, counts, order, new flag.
check "threads: grouped, counted, newest activity first" eq "$(roots general)" \
    "r2:1:$((T0 + 250)):0 l1:1:$((T0 + 60)):0 d3:2:$((T0 + 50)):0 r1:3:$((T0 + 30)):0 "
check "threads: reply to a reply stays in the root's thread" eq "$(roots general "$((T0 + 35))" | grep -o 'r1:[0-9]*')" "r1:3"
check "threads: nothing is new without a login epoch" not grep -q ':1 ' <(roots general)
check "threads: new = a post newer than the epoch (r2, l1, d3 via c3)" eq "$(roots general $((T0 + 45)) | grep -o '[a-z0-9]*:[0-9]*:[0-9]*:1' | tr '\n' ' ')" "r2:1:$((T0 + 250)):1 l1:1:$((T0 + 60)):1 d3:2:$((T0 + 50)):1 "
check "threads: deleted starter without replies is not listed" not grep -q g1 <(roots general)
check "threads: members of a thread in file order" eq "$(lib board_threads general '' "$root/boards/general/$((T0 + 10))-r1.msg" | sed 's/.*[0-9]-//; s/\.msg//' | tr '\n' ' ')" "r1 a1 b1 "
check "threads: empty board lists nothing" eq "$(lib board_threads nosuch)" ""

# 2. Real terminal: rows, count, star, colour.
run_list() { # run_list <out> <cols> <seen> <color> <keys...>
    local o=$1 w=$2 s=$3 c=$4; shift 4
    python3 "$here/tests/pty_drive.py" --cols "$w" --out "$o" --timeout 30 "$@" -- \
        env BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
        BASHBBS_SEEN_PREV="$s" BASHBBS_COLOR="$c" \
        bash -c "source $here/lib/menu.sh; board_view general; echo DONE" 2>>"$log"
}
for w in 40 80; do
    run_list "$out/l0-$w.txt" $w $((T0 + 45)) 0 --step 'Q) Back=>q'
    first=$(tr -d '\r' < "$out/l0-$w.txt")
    check "list $w: 4 thread rows" eq "$(grep -c '^ *[0-9]*) ' <<<"$first")" 4
    check "list $w: new thread has count and star, deleted root shown" bash -c "grep -q '^  3) (deleted) *(2) \*\$' <<<'$first'"
    check "list $w: old thread has count, no star" bash -c "grep -q '^  4) Sommarens synthar *(3)\$' <<<'$first'"
    check "list $w: no row wider than $w" fits "$out/l0-$w.txt" $w
    check "list $w: plain mode has no ESC" not grep -q "$ESC\[[0-9;]*m" "$out/l0-$w.txt"
    check "list $w: session ends" has "$out/l0-$w.txt" DONE
done
run_list "$out/lc.txt" 80 $((T0 + 45)) 1 --step 'Q) Back=>q'
check "colour: new row has mint number and gold star" bash -c "grep -q \"  $ESC\[1;36m3)$ESC\[0m (deleted) .*(2) $ESC\[1;33m\*$ESC\[0m\" '$out/lc.txt'"
check "colour: old row has mint number, no other colour" bash -c "grep -q \"  $ESC\[1;36m4)$ESC\[0m Sommarens synthar .*(3).\$\" '$out/lc.txt'"
check "colour: no dark grey 1;30 anywhere in the list" not grep -q "$ESC\[1;30m" "$out/lc.txt"
run_list "$out/lc4.txt" 40 $((T0 + 45)) 1 --step 'Q) Back=>q'
check "colour 40: every coloured row line has a reset" eq "$(grep "$ESC\[1;3[63]m" "$out/lc4.txt" | tr -d '\r' | grep -vc "$ESC\[0m")" 0
run_list "$out/ln.txt" 80 "" 1 --step 'Q) Back=>q'
check "no login epoch: all rows old, no gold star" not grep -q "$ESC\[1;33m\*" "$out/ln.txt"

# 3. Reading a thread: starts at the first new post, Space/P, back to the list.
run_list "$out/v1.txt" 80 $((T0 + 45)) 0 --step 'Q) Back=>3' --step 'Prev=>q' --step 'Q) Back=>q'
check "thread: starts at the first new post, reply to #1" has "$out/v1.txt" '#2/2  bob  .*reply to #1'
run_list "$out/v2.txt" 80 $((T0 + 45)) 0 --step 'Q) Back=>4' --step 'Prev=>\x20' --step 'Prev=>\x20' --step 'Prev=>p' --step 'Prev=>\x20' --step 'Prev=>\x20' --step 'New post=>q'
v2=$(tr -d '\r' < "$out/v2.txt")
check "thread: no new post starts at #1 without 'reply to'" bash -c "grep -q '^#1/3  bob  .*[0-9]\$' <<<'$v2'"
check "thread: #2/3 replies to #1, #3/3 replies to #2" bash -c "grep -q '#2/3.*reply to #1' <<<'$v2' && grep -q '#3/3.*reply to #2' <<<'$v2'"
check "thread: P goes back" eq "$(grep -c '^#2/3' <<<"$v2")" 2
check "thread: Space after the last post returns to the list" eq "$(grep -c '^  1) ' <<<"$v2")$(grep -c DONE <<<"$v2")" 21
check "thread: key line" has "$out/v2.txt" '^R) Reply  Q) Back'
run_list "$out/v3.txt" 40 "" 0 --step 'Q) Back=>4' --step 'Prev=>q' --step 'Q) Back=>q'
check "thread 40: no row wider than 40" fits "$out/v3.txt" 40
run_list "$out/v4.txt" 80 "" 0 --step 'Q) Back=>3' --step 'Prev=>q' --step 'Q) Back=>q'
check "thread: stub as root has no Reply" bash -c "tr -d '\r' < '$out/v4.txt' | awk '/^#1\/2/ { f = 1 } f && /^\[Space\] Next/ { getline; print; exit }' | grep -qx 'Q) Back'"

# 3b. Per-thread read marks (~/.bashbbs-read): reading a thread clears its star.
rf=$root/home/.bashbbs-read
r1new() { roots general $((T0 + 5)) | grep -o 'r1:[0-9]*:[0-9]*:[01]' | sed 's/.*://'; }
mkdir -p "$root/home"; : > "$rf"
check "marks: r1 is new before reading" eq "$(r1new)" 1
run_list "$out/m1.txt" 80 $((T0 + 5)) 0 --step 'Q) Back=>4' --step 'Prev=>\x20' --step 'Prev=>q' --step 'Q) Back=>q'
check "marks: two of three posts read, the third keeps the thread new" eq "$(r1new)" 1
check "marks: file has board, root id and epoch of the last post seen" eq "$(grep -c "^general r1 $((T0 + 20))\$" "$rf")" 1
run_list "$out/m2.txt" 80 $((T0 + 5)) 0 --step 'Q) Back=>4' --step 'Prev=>q' --step 'Q) Back=>q'
check "marks: thread reopens at the first unread post (#3)" has "$out/m2.txt" '^#3/3'
check "marks: reading the last post clears the star" eq "$(r1new)" 0
run_list "$out/m3.txt" 80 $((T0 + 5)) 0 --step 'Q) Back=>q'
check "marks: list row for r1 has no star" bash -c "tr -d '\r' < '$out/m3.txt' | grep -q '^  4) Sommarens synthar *(3)\$'"
check "marks: one line per thread" eq "$(grep -c '^general r1 ' "$rf")" 1
mk 40 f1 b1 active
check "marks: a later reply makes the thread new again" eq "$(r1new)" 1
mv "$root/boards/general/$((T0 + 400))-f1.msg" "$out/f1.msg"
printf 'Msgid: own1\nAuthor: alice\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: Re: x\nParent: b1\n\nmine\n' > "$root/boards/general/$((T0 + 500))-own1.msg"
check "marks: own post does not make the thread new" eq "$(r1new)" 0
mv "$root/boards/general/$((T0 + 500))-own1.msg" "$out/own1.msg"
printf 'general r1 abc\nbad line\nGENERAL r1 5\ngeneral r1 %s extra\n' "$((T0 + 5))" > "$rf"
check "marks: bad lines are ignored (thread is new)" eq "$(r1new)" 1
: > "$rf"
for i in $(seq 1 2100); do printf 'general t%s 5\n' "$i"; done > "$rf"
lib read_mark_save general r1 99
check "marks: file is capped at 2000 lines, new mark kept" eq "$(wc -l < "$rf") $(tail -n 1 "$rf")" "2000 general r1 99"
: > "$rf"

# 4. Reply: Re: once, quote of up to 6 lines without ">" lines, new thread without either.
f1=$root/q.msg
{ printf 'Msgid: m1\nAuthor: bob\nDate: 2017-07-14T04:00:00+00:00\nSubject: Hej\n\n'
  printf '> old quote\nline1\nline2\n\nline3\nline4\n> more\nline5\nline6\nline7\nline8\n'; } > "$f1"
check "quote_lines: 6 lines, '> ' prefix, skips > lines and blanks" eq "$(lib quote_lines "$f1" | tr '\n' '|')" "> line1|> line2|> line3|> line4|> line5|> line6|"
drive() { # drive <cmd...> with fixed steps in $STEPS
    local -a st=(); local s
    for s in "${STEPS[@]}"; do st+=(--step "$s"); done
    python3 "$here/tests/pty_drive.py" --cols 80 --out "$out/c.txt" --timeout 30 "${st[@]}" -- \
        env BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
        bash -c "source $here/lib/menu.sh; $1; echo DONE" 2>>"$log"
}
lastq() { ls -1t "$root"/queue/incoming/*.post | head -n 1; }
STEPS=('Subject=>\n' 'Quote?=>y' 'Write text=>svar\n.\n' 'Any key=>x')
check "reply: runs" drive "reply_to general $f1"
q=$(lastq)
check "reply: subject Re: Hej, Parent = that post's Msgid" bash -c "grep -qx 'Subject: Re: Hej' '$q' && grep -qx 'Parent: m1' '$q'"
check "reply: quote on top, then the text" eq "$(sed '1,/^$/d' "$q" | head -n 8 | tr '\n' '|')" "> line1|> line2|> line3|> line4|> line5|> line6||svar|"
sed -i 's/^Subject: Hej/Subject: Re: Hej/' "$f1"; sleep 1.1
STEPS=('Subject=>\n' 'Quote?=>n' 'Write text=>svar\n.\n' 'Any key=>x')
check "reply 2: runs" drive "reply_to general $f1"
q=$(lastq)
check "reply: Re: not doubled" grep -qx 'Subject: Re: Hej' "$q"
check "reply: Quote n gives no quote" not grep -q '^>' "$q"
long=$(printf 'x%.0s' $(seq 1 120)); sed -i "s/^Subject: .*/Subject: $long/" "$f1"; sleep 1.1
STEPS=('Subject=>\n' 'Quote?=>n' 'Write text=>s\n.\n' 'Any key=>x')
check "reply 3: runs" drive "reply_to general $f1"
check "reply: subject cut to 100 characters" eq "$(sed -n 's/^Subject: //p' "$(lastq)" | head -n 1 | wc -c)" 101
sleep 1.1
STEPS=('Subject=>nytt\n' 'Write text=>hej\n.\n' 'Any key=>x')
check "new thread: runs without a Quote question" drive "compose general ''"
check "new thread: no Parent, no quote, no Quote? prompt" bash -c "! grep -q '^Parent' '$(lastq)' && ! grep -q Quote '$out/c.txt' && ! grep -q '^>' '$(lastq)'"

# 5. Reply mail switch in My Account > 3 Settings.
mkdir -p "$root/users/alice"; printf 'name=alice\nuuid=x\n' > "$root/users/alice/profile"
check "prefs: default is on" eq "$(lib eval 'prefs_load; echo $REPLYMAIL')" 1
STEPS=('Q) Back=>3' 'Reply mail: on=>n' 'Reply mail: off=>x' 'Q) Back=>q')
check "my_account: N turns reply mail off" drive "me=alice; my_account"
check "my_account: saved with both keys" bash -c "grep -qx 'replymail=0' '$root/home/.bashbbs-prefs' && grep -qx 'color=0' '$root/home/.bashbbs-prefs'"
check "prefs: read back as off" eq "$(lib eval 'prefs_load; echo $REPLYMAIL')" 0
STEPS=('Q) Back=>3' 'Reply mail: off=>n' 'Reply mail: on=>x' 'Q) Back=>q')
check "my_account: N turns it on again" drive "me=alice; my_account"
check "prefs: on again" grep -qx 'replymail=1' "$root/home/.bashbbs-prefs"

# 6. The publisher's reply mail. Accounts, homes and groups are stubbed.
cat > "$root/t/sendmail" <<SH
#!/bin/bash
f=$root/mail/\$(date +%s%N).\$\$; { printf 'ARGS: %s\n' "\$*"; cat; } > "\$f"
SH
chmod +x "$root/t/sendmail"
printf 'bbs-alice bbsb-priv\nbbs-bob bbsb-priv\n' > "$root/test-groups"
: > "$root/meta/priv.meta"
for a in alice bob erin; do mkdir -p "$root/h/$a"; done
pub() { ( export BBS_ROOT="$root" BBS_LOCK_WAIT=2 BASHBBS_TEST=1 BBS_SENDMAIL="$root/t/sendmail"
          source "$here/sbin/bbs-publish"
          in_group() { grep -qxF "$1 $2" "$root/test-groups" 2>/dev/null; }
          chgrp() { return 0; }
          id() { case $1 in bbs-alice|bbs-bob|bbs-erin) return 0 ;; *) return 1 ;; esac; }
          getent() { [[ $1 == passwd ]] && echo "$2:x:1:1::$root/h/${2#bbs-}:/bin/sh"; }
          "$@" ) >>"$log" 2>&1; }
n=0
# post <board> <owner> <parent|-> <body>: publishes through handle_post, sets P to the file
post() {
    n=$((n + 1)); local f=$root/t/p$n.post
    { printf 'Board: %s\nSubject: Tråd %s\n' "$1" "$n"; [[ $3 != - ]] && printf 'Parent: %s\n' "$3"; printf '\n%b\n' "$4"; } > "$f"
    pub handle_post "$f" "$2" || return 1
    P=$(grep -l "^Subject: Tråd $n\$" "$root/boards/$1"/*.msg)
}
mid() { sed -n 's/^Msgid: //p' "$1" | head -n 1; }
mails() { ls "$root/mail" | wc -l; }
lastmail() { ls -1 "$root/mail"/* | tail -n 1; }
sleep 1.1; post general bbs-alice - "ursprung"; A=$P; AID=$(mid "$A")
before=$(mails); sleep 0.1
body=$(printf 'rad%s\\n' 1 2 3 4 5 6 7 8 9 10 11 12)
check "mail: bob replies to alice, post published" post general bbs-bob "$AID" "$body"
check "mail: one mail sent" eq "$(( $(mails) - before ))" 1
m=$(lastmail)
check "mail: recipient on the command line, sender bbs-bob" has "$m" '^ARGS: -i -f bbs-bob bbs-alice$'
check "mail: headers From/To/Subject" bash -c "grep -q '^From: bob@' '$m' && grep -q '^To: alice@' '$m' && grep -q '^Subject: Reply on general: Tråd 1\$' '$m'"
check "mail: first 10 lines of the reply, not the 11th" bash -c "grep -qx rad10 '$m' && ! grep -qx rad11 '$m'"
check "mail: ends with the Read it line" has "$m" 'Read it: B) Boards .* general$'
b=$(mails); sleep 0.1
check "no mail: alice replies to herself" post general bbs-alice "$AID" "själv"
check "no mail: self-reply" eq "$(mails)" "$b"
printf 'color=1\nreplymail=0\n' > "$root/h/alice/.bashbbs-prefs"
check "no mail: opt-out publishes" post general bbs-bob "$AID" "x"
check "no mail: opt-out (replymail=0)" eq "$(mails)" "$b"
mv "$root/h/alice/.bashbbs-prefs" "$root/t/real-prefs"; ln -s "$root/t/real-prefs" "$root/h/alice/.bashbbs-prefs"
check "symlinked prefs publishes" post general bbs-bob "$AID" "x"
check "symlinked prefs are not followed: mail sent" eq "$(mails)" "$((b + 1))"
b=$(mails); rm "$root/h/alice/.bashbbs-prefs"; printf 'replymail=0 \nxreplymail=0\n' > "$root/h/alice/.bashbbs-prefs"
check "malformed prefs line publishes" post general bbs-bob "$AID" "x"
check "malformed prefs line is not an opt-out: mail sent" eq "$(mails)" "$((b + 1))"
b=$(mails); rm "$root/h/alice/.bashbbs-prefs"
sleep 1.1; post general bbs-alice - "andra"; D=$P; DID=$(mid "$D")
sed -i "s/^Subject: .*/&\nDeleted: 2017-07-14T05:00:00+00:00/" "$D"
check "no mail: reply to a deleted parent publishes" post general bbs-bob "$DID" "x"
check "no mail: deleted parent" eq "$(mails)" "$b"
check "no mail: parent missing publishes" post general bbs-bob "00000000-0000-0000-0000-000000000000" "x"
check "no mail: parent missing" eq "$(mails)" "$b"
# author without an account
sleep 1.1; post general bbs-bob - "bobs"; B=$P; sed -i 's/^Author: bob/Author: zed/' "$B"
check "no mail: author has no account (publishes)" post general bbs-bob "$(mid "$B")" "x"
check "no mail: unknown account" eq "$(mails)" "$b"
# private board
sleep 1.1; post priv bbs-alice - "hemligt"; PA=$P
check "private: member replies to member (publishes)" post priv bbs-bob "$(mid "$PA")" "x"
check "private: mail sent to the member" eq "$(mails)" "$((b + 1))"
b=$(mails); sleep 1.1
printf 'Msgid: 11111111-1111-1111-1111-111111111111\nAuthor: erin\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: Gammal\n\nx\n' > "$root/boards/priv/$(date +%s)-11111111-1111-1111-1111-111111111111.msg"
check "private: author left the group (publishes)" post priv bbs-bob "11111111-1111-1111-1111-111111111111" "x"
check "private: no mail to a non-member author" eq "$(mails)" "$b"
check "rejected: non-member cannot post to the private board" not post priv bbs-erin "$(mid "$PA")" "x"
check "rejected: no mail for a rejected post" eq "$(mails)" "$b"
check "no mail: a new thread (no Parent)" bash -c "true"
sleep 1.1; post general bbs-bob - "ny"
check "no mail: new thread sends nothing" eq "$(mails)" "$b"

echo "boards_thread_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
