#!/bin/bash
# Address book: B on fsx posts and netmail, limits, mode, picker in Write, card, M/B only on fsx posts.
# Usage: tests/addressbook_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/addressbook_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"; else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }

root=$(mktemp -d "$scratch/ab.XXXXXX")
mkdir -p "$root"/{boards/fsx_gen,boards/general,meta,queue/incoming,users/alice,home}
: > "$root/users/alice/profile"; : > "$root/meta/fsx_gen.fido"
B=$root/home/.addressbook
run() { ( export BBS_ROOT="$root" HOME="$root/home" USER=bbs-alice BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb BASHBBS_COLOR=0
          source "$here/lib/menu.sh"; set +e +u 2>/dev/null; pause() { :; }; "$@" ); }
# post_actions with fixed keys: stdin supplies them, n=1 so no # key
pa() { n=1 root=x; post_actions "$@"; }
P=$root/boards/fsx_gen/1700000001-a.msg
printf 'Msgid: m1\nAuthor: Zip@fsx\nNode: 21:1/202\nFido-Msgid: 21:1/202 abc\nDate: 2026-11-18T10:00:00Z\nSubject: Hello\n\ntext\n' > "$P"
L=$root/boards/general/1700000002-b.msg
printf 'Msgid: m2\nAuthor: kitty\nDate: 2026-11-18T10:00:00Z\nSubject: Hi\n\ntext\n' > "$L"

out=$(printf 'b' | run pa fsx_gen "$P" 2>&1)
check "fsx post offers M and B" bash -c 'grep -q "M) Mail privately" <<<"$1" && grep -q "B) Add to book" <<<"$1"' _ "$out"
out=$(printf 'q' | run pa general "$L" 2>&1)
check "local post: no M/B" bash -c '! grep -q "Mail privately\|Add to book" <<<"$1"' _ "$out"

printf 'bStar Collision sysop\n' | run pa fsx_gen "$P" >>"$log" 2>&1
check "B saves name, address, comment" eq "$(cut -f1-3 "$B")" $'Zip\t21:1/202\tStar Collision sysop'
check "date column" grep -qP '\t\d{4}-\d\d-\d\d$' "$B"
check "mode 0600" eq "$(stat -c %a "$B")" 600
out=$(printf 'b\n' | run pa fsx_gen "$P" 2>&1)
check "B again shows old comment" grep -q 'Star Collision sysop' <<<"$out"
check "no duplicate, Enter keeps comment" eq "$(cut -f1-3 "$B")" $'Zip\t21:1/202\tStar Collision sysop'

run book_add Tab$'\t'x 1:2/3 $'a\tb\033[31mc' >>"$log" 2>&1
check "tab and ESC stripped" eq "$(sed -n 2p "$B" | cut -f1-3)" $'Tabx\t1:2/3\tab[31mc'
check "every line has 4 fields" bash -c '! awk -F"\t" "NF!=4" "$1" | grep -q .' _ "$B"
run book_add Long 1:2/4 "$(printf 'x%.0s' {1..100})" >>"$log" 2>&1
check "comment cut to 60" eq "$(sed -n 3p "$B" | cut -f3 | tr -d '\n' | wc -c)" 60
for i in $(seq 4 100); do run book_add "N$i" 1:1/$i "" >>"$log" 2>&1; done
check "100 entries" eq "$(wc -l < "$B")" 100
run book_add Extra 9:9/9 "" >>"$log" 2>&1; rc=$?
check "101st refused" eq "$(wc -l < "$B")" 100
printf 'Msgid: m3\nAuthor: Full@fsx\nNode: 21:9/9\nSubject: s\n\nt\n' > "$root/boards/fsx_gen/1700000003-c.msg"
out=$(printf 'bx\n' | run pa fsx_gen "$root/boards/fsx_gen/1700000003-c.msg" 2>&1)
check "full book: clear message" grep -q 'full' <<<"$out"
check "full book: still 100" eq "$(wc -l < "$B")" 100

rm -f "$B"; run book_add Zip 21:1/202 "" >>"$log" 2>&1
# Write: B at To picks contact 1 -> netmail to Zip
rm -f "$root"/queue/incoming/*.net
printf 'b\n1Hej\nText\n.\ny\n\n' | run mail_write >>"$log" 2>&1
N=$(ls "$root"/queue/incoming/*.net 2>/dev/null | head -n 1)
check "picker fills the address (To-Addr)" grep -qx 'To-Addr: 21:1/202' "$N"
check "picker fills the name (To-Name)" grep -qx 'To-Name: Zip' "$N"

# M on an fsx post prefills the address and subject
run() { ( export BBS_ROOT="$root" HOME="$root/home" USER=bbs-alice BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb BASHBBS_COLOR=0
          source "$here/lib/menu.sh"; set +e +u 2>/dev/null; pause() { :; }
          mail_write() { echo "WRITE $1|$2|$3"; }; "$@" ); }
out=$(printf 'm' | run pa fsx_gen "$P" 2>&1)
check "M prefills address, subject, msgid" grep -q 'WRITE Zip@21:1/202|Re: Hello|21:1/202 abc' <<<"$out"
sed -i 's/^Subject: .*/Subject: Re: Hello/' "$P"
out=$(printf 'm' | run pa fsx_gen "$P" 2>&1)
check "Re: not doubled" grep -q 'Re: Hello|' <<<"$out"

# Card: D then y deletes, then n keeps
run book_card Zip 21:1/202 c >>"$log" 2>&1 </dev/null
printf 'dn' | run book_card Zip 21:1/202 c >>"$log" 2>&1
check "D then n keeps" eq "$(grep -c '^Zip' "$B")" 1
printf 'dy' | run book_card Zip 21:1/202 c >>"$log" 2>&1
check "D then y deletes" eq "$(grep -c '^Zip' "$B")" 0
rm -f "$B"
out=$(printf 'q' | run book_menu 2>&1)
check "empty book explains B" grep -q 'Press B on an fsxNet post' <<<"$out"

echo "pass $pass fail $fail" | tee -a "$log"
[[ $fail -eq 0 ]]
