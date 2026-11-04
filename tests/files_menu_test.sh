#!/bin/bash
# Files section of the menu, the Top lists, the sysop Transfers and Quota screens, and
# removal requests through sbin/bbs-upload. Temporary BBS_ROOT, no accounts needed;
# BBS_UPLOAD_TEST_OWNER stands in for the owner of a request file.
# Usage: tests/files_menu_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/files_menu_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }
before() { [[ $1 == *"$2"*"$3"* ]]; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/filesmenu.XXXXXX")
mkdir -p "$root"/{published,state,queue/filedel,users/sys0p,users/alice,users/ghost,home,bin}
printf 'sys0p\n' > "$root/sysops"
printf 'name=Alice\n' > "$root/users/alice/profile"
printf 'name=Ghost\nhidden=yes\n' > "$root/users/ghost/profile"
printf 'name=Sysop\n' > "$root/users/sys0p/profile"

# file <epoch> <hex8> <user> <name> <size>
file() {
    printf 'x' > "$root/published/$1-$2"
    printf 'user=%s\nname=%s\nsize=%s\nsha256=00\ndate=2026-11-0%sT09:00:00Z\nip=192.0.2.9\n' \
        "$3" "$4" "$5" "${6:-1}" > "$root/published/$1-$2.meta"
}
file 1500000100 aaaaaaaa bbs-alice old.zip 2048 1
file 1500000200 bbbbbbbb bbs-alice mid.lha 3145728 2
file 1500000300 cccccccc bbs-ghost secret.txt 100 3
file 1500000400 dddddddd bbs-sys0p boss.mod 512 4
printf 'orphan' > "$root/published/1500000500-eeeeeeee"     # no .meta: incomplete

{
    printf '2026-11-04T09:00:00Z\tbbs-alice\tup\t1500000100-aaaaaaaa\told.zip\t2048\t192.0.2.1\n'
    printf '2026-11-04T09:05:00Z\tbbs-bob\tdown\t1500000200-bbbbbbbb\tmid.lha\t3145728\t192.0.2.2\n'
    printf '2026-11-04T09:06:00Z\tbbs-kit\tdown\t1500000200-bbbbbbbb\tmid.lha\t3145728\t192.0.2.3\n'
    printf '2026-11-04T09:07:00Z\tbbs-bob\tdown\t1500000100-aaaaaaaa\told.zip\t2048\t192.0.2.2\n'
    printf '2026-11-04T09:08:00Z\tbbs-bob\tdown\t1500009999-ffffffff\tgone.zip\t1\t192.0.2.2\n'
} > "$root/state/transfers.log"

run_as() { local who=$1 seen=$2; shift 2
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=$who TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100 BASHBBS_SEEN_PREV=$seen
      source "$here/lib/menu.sh"; "$@" ); }
alice() { run_as bbs-alice "" "$@"; }
bob() { run_as bbs-bob "" "$@"; }
sys() { run_as bbs-sys0p "" "$@"; }

# 1. The list.
out=$(printf 'q' | bob files_menu)
check "list: newest first" before "$out" boss.mod secret.txt
check "list: older after newer" before "$out" mid.lha old.zip
check "list: file without .meta left out" not has "$out" eeeeeeee
check "list: uploader without bbs- prefix" not has "$out" bbs-ghost
check "list: readable size" has "$out" "3.0 MB"
check "list: upload command uses scp -O, port and login" has "$out" "scp -O -P 6464 FILE bbs-bob@bbs.piewpiew.se:"
check "list: limits come from upload-common" has "$out" "10.0 MB a file, 200.0 MB per user"
check "list: no new mark without an earlier login" not has "$out" " *"
out=$(printf 'q' | run_as bbs-bob 1500000250 files_menu)
check "list: file newer than last login is marked" bash -c '[[ $(grep boss.mod <<< "$1") == *" *" ]]' _ "$out"
check "list: older file not marked" bash -c '[[ $(grep old.zip <<< "$1") != *" *" ]]' _ "$out"
out=$(printf 'q' | run_as bbs-bob 1500000250 main_menu)
check "main menu: Files has a mark when something is new" has "$out" "8) Files *"
out=$(printf 'q' | run_as bbs-bob 1500000400 main_menu)
check "main menu: no mark when nothing is new" not has "$out" "8) Files *"

# 2. Paging: only a page at a time, N goes on.
pagedir=$(mktemp -d "$scratch/filespage.XXXXXX")
mkdir -p "$pagedir/published" "$pagedir/state" "$pagedir/home"
for i in $(seq 1 12); do
    id=$((1500001000 + i))-0000000$((i % 10))
    printf 'x' > "$pagedir/published/$id"
    printf 'user=bbs-alice\nname=page%02d.zip\nsize=1\ndate=2026-11-01T00:00:00Z\n' "$i" > "$pagedir/published/$id.meta"
done
page() { ( export BBS_ROOT="$pagedir" HOME="$pagedir/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-bob TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100; source "$here/lib/menu.sh"; "$@" ); }
out=$(printf 'q' | page files_menu)
check "paging: first page holds the newest" has "$out" "page12.zip"
check "paging: file 11 waits for the next page" not has "$out" "page02.zip"
out=$(printf 'nq' | page files_menu)
check "paging: N shows the rest" has "$out" "page02.zip"

# 3. Empty.
emptydir=$(mktemp -d "$scratch/filesempty.XXXXXX"); mkdir -p "$emptydir/home"
out=$(printf 'q' | ( export BBS_ROOT="$emptydir" HOME="$emptydir/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-bob TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100; source "$here/lib/menu.sh"; files_menu ))
check "empty: says so, still shows how to upload" bash -c '[[ $1 == *"No files yet"* && $1 == *"scp -O"* ]]' _ "$out"

# 4. The detail screen.
row=$'1500000200-bbbbbbbb\tbbs-alice\t3145728\t2026-11-02T09:00:00Z\t2\tmid.lha'
out=$(printf 'q' | bob file_view "$row")
check "detail: exact download command" has "$out" "scp -O -P 6464 bbs-bob@bbs.piewpiew.se:mid.lha ."
check "detail: download count" bash -c '[[ $1 == *"Downloads:"*2* ]]' _ "$out"
check "detail: stranger is not offered Remove" not has "$out" "R) Remove"
check "detail: uploader is offered Remove" has "$(printf 'q' | alice file_view "$row")" "R) Remove"
check "detail: sysop is offered Remove" has "$(printf 'q' | sys file_view "$row")" "R) Remove"

# 5. Removal from the menu: only a request, the file stays until root acts.
del=$root/queue/filedel/1500000200-bbbbbbbb.del
printf 'rq' | bob file_view "$row" >/dev/null
check "remove: R is ignored for a stranger" not test -e "$del"
printf 'rnq' | alice file_view "$row" >/dev/null
check "remove: N at the question leaves no request" not test -e "$del"
out=$(printf 'ryq' | alice file_view "$row")
check "remove: Y leaves a request" test -e "$del"
check "remove: the file stays until the sorter runs" test -f "$root/published/1500000200-bbbbbbbb"
check "remove: the screen says it is on its way" has "$out" "Removal requested"
out=$(printf 'q' | alice file_view "$row")
check "remove: a waiting request shows, without Remove" bash -c '[[ $1 == *"Removal requested"* && $1 != *"R) Remove"* ]]' _ "$out"

# 6. Removal in bbs-upload. The owner of the request decides, never its content.
upload() { env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_LOCK_WAIT=2 BBS_UPLOAD_TEST_OWNER="$1" "$here/sbin/bbs-upload" 2>&1; }
exp=$root/state/expired
out=$(upload bbs-bob)
check "sorter: stranger is refused" test -f "$root/published/1500000200-bbbbbbbb.meta"
check "sorter: refusal goes to the journal" has "$out" "may not remove"
check "sorter: refused request is cleared" not test -e "$del"
: > "$del"
upload bbs-alice >/dev/null
check "sorter: uploader removes, data moved" test -f "$exp/1500000200-bbbbbbbb"
check "sorter: uploader removes, meta moved" test -f "$exp/1500000200-bbbbbbbb.meta"
check "sorter: gone from published" not test -e "$root/published/1500000200-bbbbbbbb"
check "sorter: request cleared" not test -e "$del"
check "sorter: removal is logged" bash -c 'tail -n 1 "$1" | grep -q "bbs-alice.del.1500000200-bbbbbbbb.mid.lha"' _ "$root/state/transfers.log"
check "sorter: removal does not count as a download" has "$(printf 'q' | bob files_menu)" "old.zip"
source "$here/lib/upload-common.sh"
BBS_ROOT=$root
check "sorter: quota is freed" test "$(ub_used bbs-alice)" = 2048
: > "$root/queue/filedel/1500000300-cccccccc.del"
upload bbs-sys0p >/dev/null
check "sorter: sysop may remove anyone's file" test -f "$exp/1500000300-cccccccc"
: > "$root/queue/filedel/1500000100-aaaaaaaa.del"
upload coffe >/dev/null
check "sorter: owner outside bbs- is refused" test -f "$root/published/1500000100-aaaaaaaa"
: > "$root/queue/filedel/..evil.del"
: > "$root/queue/filedel/1500007777-00000000.del"
ln -s "$root/published/1500000100-aaaaaaaa.meta" "$root/queue/filedel/1500000100-aaaaaaaa.del"
upload bbs-alice >/dev/null
check "sorter: odd name dropped" not test -e "$root/queue/filedel/..evil.del"
check "sorter: request for a missing file dropped" not test -e "$root/queue/filedel/1500007777-00000000.del"
check "sorter: symlink request dropped, file stays" test -f "$root/published/1500000100-aaaaaaaa.meta"
check "sorter: symlink request gone" not test -L "$root/queue/filedel/1500000100-aaaaaaaa.del"

# Back to four files for the lists below.
file 1500000200 bbbbbbbb bbs-alice mid.lha 3145728 2
file 1500000300 cccccccc bbs-ghost secret.txt 100 3

# 7. Fame.
out=$(printf 'q' | bob fame_menu)
check "fame: Top Uploaders and Top Downloads are listed last" before "$out" "4) BBS Records" "5) Top Uploaders"
check "fame: order of the Top lists" before "$out" "5) Top Uploaders" "6) Top Downloads"
out=$(printf '\n' | bob top_uploaders_view)
check "uploaders: count and name" bash -c 'grep -Eq "^ +2  alice$" <<< "$1"' _ "$out"
check "uploaders: hidden left out" not has "$out" ghost
check "uploaders: sysop left out" not has "$out" sys0p
out=$(printf '\n' | bob top_downloads_view)
check "downloads: most fetched first" before "$out" mid.lha old.zip
check "downloads: count" bash -c 'grep -Eq "^ +2  mid.lha$" <<< "$1"' _ "$out"
check "downloads: unfetched file left out" not has "$out" boss.mod
check "downloads: file no longer here left out" not has "$out" gone.zip

# 8. Sysop screens.
out=$(printf '\n' | sys sysop_transfers)
check "transfers: newest first" before "$out" "gone.zip" "old.zip"
check "transfers: IP shown" has "$out" "192.0.2.2"
check "transfers: no bbs- prefix" not has "$out" "bbs-bob"
out=$(printf '\n' | sys sysop_quota)
check "quota: per user, largest first" before "$out" alice ghost
check "quota: sum per user" bash -c 'grep -Eq "^alice +3.0 MB +2$" <<< "$1"' _ "$out"
check "quota: limit and total shown" bash -c '[[ $1 == *"200.0 MB"* && $1 == *"of 2.0 GB"* ]]' _ "$out"

echo "files_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
