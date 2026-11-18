#!/bin/bash
# Feature switches (lib/features.sh): only an exact "on" is on, a dotted name needs its
# parent, FEAT_NEEDS adds web, feat_item hides or greys an off item, and the main menu
# leaves an off item and its key out. Usage: tests/features_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/features_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }

root=$(mktemp -d "$scratch/features.XXXXXX")
mkdir -p "$root/home"
on() { ( export BBS_ROOT="$root"; source "$here/lib/features.sh"; features_load; feature_on "$1" ); }
item() { ( export BBS_ROOT="$root"; menu_item() { printf '%s) %s\n' "$1" "$2"; }
    source "$here/lib/features.sh"; features_load; feat_item "$@" ); }

check "no file: everything off" not on wall
printf 'wall=on\nnews=On\nfame=yes\ngames=on\ngames.turf=on\ngames.dopewars=off\n files = on \nfiles.xfer.web=on\nnews.qr=on\n# manual=on\nmanual\n' > "$root/features"
check "exact on is on" on wall
check "On is off" not on news
check "yes is off" not on fame
check "spaces around name and value are fine" on files
check "child on with parent on" on games.turf
check "child off" not on games.dopewars
check "missing name is off" not on intro
check "comment line is ignored" not on manual
check "child of an off parent is off" not on news.qr
check "files.xfer.web needs web" not on files.xfer.web
printf 'web=on\n' >> "$root/features"
check "files.xfer.web with web on" on files.xfer.web
printf 'last=on' >> "$root/features"   # no newline at the end
check "last line without newline is read" on last
check "feat_item on: the row" has "$(item wall 2 Wall)" "2) Wall"
check "feat_item off, showoff missing: nothing" bash -c '[[ -z $1 ]]' _ "$(item intro 9 Intro)"
printf '\nshowoff=on\n' >> "$root/features"
check "feat_item off, showoff=on: (off)" has "$(item intro 9 Intro)" "9) Intro (off)"

# The main menu: a switched-off item is hidden and its key does nothing.
sed 's/=off$/=on/' "$here/etc/features.example" | sed 's/^wall=on/wall=off/; s/^showoff=on/showoff=off/' > "$root/features"
menu() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-bob TERM=dumb
    source "$here/lib/menu.sh"; "$@" ) 2>&1; }
out=$(printf 'q' | menu main_menu)
check "main menu: Wall hidden" not has "$out" "Wall"
check "main menu: News shown" has "$out" "3) News"
check "main menu: Fame keeps its number" has "$out" "4) Fame"
out=$(printf '2q' | menu main_menu)
check "main menu: key 2 ignored when Wall is off" not has "$out" "== Wall"
check "nav_key: W does nothing when Wall is off" not menu nav_key W
sed -i 's/^showoff=off/showoff=on/' "$root/features"
check "main menu: showoff=on shows Wall (off)" has "$(printf 'q' | menu main_menu)" "2) Wall (off)"

rm -rf "$root"
echo "features_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
