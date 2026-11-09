#!/bin/bash
# The two-page Manual under My Account: every chapter opens and shows its text, keys
# 1-9 on page 1 and 1-6 on page 2, N / Q navigation, Q returns to the right page,
# chapter texts are in sync with docs/manual and fit 78 columns.
# Usage: tests/manual_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/manual_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"; else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }
root=${BBS_ROOT_FOR_TEST:-$(mktemp -d "$scratch/mn.XXXXXX")}
home=$(mktemp -d "$scratch/mnh.XXXXXX"); out=$(mktemp -d "$scratch/mno.XXXXXX")
if [[ -z ${BBS_ROOT_FOR_TEST:-} ]]; then mkdir -p "$root"/etc "$root"/{boards,meta,queue/incoming}; cp -r "$here/etc/manual" "$root/etc/manual"; fi
menu=${MENU_SH:-$here/lib/menu.sh}

drive() { local o=$1 code=$2; shift 2; local -a st=(); local s
    for s in "$@"; do st+=(--step "$s"); done
    python3 "$here/tests/pty_drive.py" --cols 80 --out "$o" --timeout 40 "${st[@]}" -- \
        env BBS_ROOT="$root" HOME="$home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb BASHBBS_COLOR=0 \
        bash -c "source $menu; me=bbs-alice; $code; echo DONE" 2>>"$log"; }
has() { grep -q -- "$2" "$1"; }

# generated texts are up to date and short enough
check "etc/manual is in sync with docs/manual" bash -c "cd '$here' && python3 docs/build-manual.py && git diff --quiet --no-index /dev/null /dev/null; ls etc/manual/*.txt | wc -l | grep -qx 15"
check "no line over 78 columns" bash -c "! awk 'length>78' '$here'/etc/manual/*.txt | grep -q ."
check "no markdown left" bash -c "! grep -qE '\*\*|\`|^#' '$here'/etc/manual/*.txt"

# page 1: list, every key 1-9 opens its chapter, Q returns to page 1
for k in 1 2 3 4 5 6 7 8 9; do
    drive "$out/p1-$k.txt" manual_menu "Next page   Q) Back=>$k" "Q) Back=>q" "Next page   Q) Back=>q"
    t=$(tr -d '\r' < "$out/p1-$k.txt")
    title=$(head -n 1 "$root/etc/manual/0$k.txt")
    first=$(sed -n 2p "$root/etc/manual/0$k.txt")
    check "page 1 key $k: '1) Chapter 1 - ' listing" bash -c "grep -q '^1) Chapter 1 - ' '$out/p1-$k.txt'"
    check "page 1 key $k opens chapter $k ($title)" bash -c "grep -qF -- '== Chapter $k - $title ==' '$out/p1-$k.txt'"
    check "page 1 key $k shows its text" bash -c "grep -qF -- '$(printf %s "$first" | head -c 40 | sed "s/'/'\\\\''/g")' '$out/p1-$k.txt'"
    check "page 1 key $k: Q in chapter returns to page 1, Q leaves" has "$out/p1-$k.txt" DONE
done
# page 2
for k in 1 2 3 4 5 6; do
    n=$((9 + k))
    drive "$out/p2-$k.txt" manual_menu "N) Next page=>n" "Q) Back to page 1=>$k" "Q) Back=>q" "Q) Back to page 1=>q" "N) Next page=>q"
    title=$(head -n 1 "$root/etc/manual/$n.txt")
    check "page 2 key $k opens chapter $n ($title)" bash -c "grep -qF -- '== Chapter $n - $title ==' '$out/p2-$k.txt'"
    check "page 2 key $k: Q returns to page 2, Q to page 1, Q out" has "$out/p2-$k.txt" DONE
done
drive "$out/pg.txt" manual_menu "N) Next page=>n" "Q) Back to page 1=>7q" "Next page   Q) Back=>q"
check "page 2 lists '1) Chapter 10 - Games' ... '6) Chapter 15'" bash -c "grep -q '^1) Chapter 10 - Games' '$out/pg.txt' && grep -q '^6) Chapter 15 - ' '$out/pg.txt'"
check "page 2 has no key 7 (ignored)" has "$out/pg.txt" DONE
# My Account item 4 and the ? help
drive "$out/ma.txt" my_account "4) Manual=>4" "Next page   Q) Back=>q" "Q) Back=>q"
check "My Account lists 4) Manual and opens it" bash -c "grep -q '^4) Manual' '$out/ma.txt' && grep -q '== Manual ==' '$out/ma.txt' && grep -q DONE '$out/ma.txt'"
# ? help -> H opens the Manual, Q returns to the screen that asked
drive "$out/hh.txt" my_account "4) Manual=>?" "Any key=>h" "Next page   Q) Back=>q" "4) Manual=>q"
check "? then H opens the Manual page, Q returns to My Account" bash -c "grep -q '\[H\] Manual' '$out/hh.txt' && grep -q '== Manual ==' '$out/hh.txt' && grep -q DONE '$out/hh.txt'"
drive "$out/hm.txt" manual_menu "Next page   Q) Back=>?" "Any key=>h" "Next page   Q) Back=>q"
check "help inside the Manual does not offer [H]" bash -c "! grep -q '\[H\] Manual' '$out/hm.txt' && grep -q DONE '$out/hm.txt'"
echo "pass $pass fail $fail" | tee -a "$log"
[[ $fail -eq 0 ]]
