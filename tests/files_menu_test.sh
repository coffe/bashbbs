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
eq() { [[ $1 == "$2" ]]; }
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


# A description is the last column, and must not end up in the name.
d=1500000700-77777777
printf 'x' > "$root/published/$d"
printf 'user=bbs-alice\nname=told.zip\nsize=1\ndate=2026-11-03T09:00:00Z\nsha256=0\ndesc=First of it\ndesc=Second of it\n' > "$root/published/$d.meta"
printf '2026-11-03T10:00:00Z\tbbs-bob\tdown\t%s\ttold.zip\t1\t192.0.2.1\n' "$d" >> "$root/state/transfers.log"
line=$(bob files_rows | grep -F "$d")
check "rows: description is the first line" test "$(cut -f8 <<< "$line")" = "First of it"
check "rows: name stays the name" test "$(cut -f6 <<< "$line")" = "told.zip"
out=$(printf 'q' | bob top_downloads_view)
check "top downloads: the name" grep -q 'told.zip' <<< "$out"
check "top downloads: no description in it" not grep -q 'First of it' <<< "$out"
out=$(printf 'q' | bob file_view "$line")
check "view: the description, every line" grep -q 'Second of it' <<< "$out"
out=$(printf 'q' | bob files_menu)
check "list: the description, every line" has "$out" "Second of it"

# The whole FILE_ID.DIZ in the list: a file with 10 lines fills the page (24 rows, room 14),
# so the next one with 10 lines waits for N.
dizdir=$(mktemp -d "$scratch/filesdiz.XXXXXX"); mkdir -p "$dizdir/published" "$dizdir/state" "$dizdir/home"
for f in 1500002001-0000000a:older.lha:Old 1500002002-0000000b:newer.lha:New; do
    IFS=: read -r id nm tag <<< "$f"
    printf 'x' > "$dizdir/published/$id"
    { printf 'user=bbs-alice\nname=%s\nsize=1\ndate=2026-11-01T00:00:00Z\n' "$nm"
      for n in $(seq 1 10); do printf 'desc=%s diz line %02d\n' "$tag" "$n"; done; } > "$dizdir/published/$id.meta"
done
diz() { ( export BBS_ROOT="$dizdir" HOME="$dizdir/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-bob TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100; source "$here/lib/menu.sh"; "$@" ); }
out=$(printf 'q' | diz files_menu)
check "diz list: first file shows all 10 lines" has "$out" "New diz line 10"
check "diz list: the next file waits for the next page" not has "$out" "older.lha"
out=$(printf 'nq' | diz files_menu)
check "diz list: N shows the next file whole" has "$out" "Old diz line 10"

# --- File areas
areas() { fa_load; local i; for (( i = 0; i < ${#FA_SLUGS[@]}; i++ )); do printf '%s=%s=%s\n' "${FA_SLUGS[i]}" "${FA_TITLES[i]}" "${FA_TEXTS[i]}"; done; printf 'default=%s\n' "$FA_DEFAULT"; }
aof() { sed -n 's/^area=//p' "$root/published/$1.meta"; }
O=1500000100-aaaaaaaa M=1500000200-bbbbbbbb B=1500000400-dddddddd
out=$(bob areas)
check "areas: no file, one area" eq "$out" $'general=General=All files\ndefault=general'
out=$(printf 'q' | bob file_areas)
check "areas: one area, straight to the list" has 'boss.mod' "$out"
check "areas: one area, no title on the header" not grep -q 'Files: ' <<< "$out"
mkdir -p "$root/etc"
: > "$root/etc/file-areas"
check "areas: empty file, one area" eq "$(bob areas | tail -n 1)" default=general
printf '# a comment\n\nBad Slug|No|No\n../x|No|No\ndemos|Demos|Demo text\ndemos|Twice|No\nmusic| Music |  Tunes \nbare\nesc|Bad\033[31mTitle|x\033]0;own\007y\n\nlast|Last line|No newline at the end' > "$root/etc/file-areas"
out=$(bob areas)
check "areas: first usable line is the default" grep -qx 'default=demos' <<< "$out"
check "areas: junk, comments and doubles left out" eq "$(grep -c = <<< "$out")" 6
check "areas: spaces trimmed" grep -qx 'music=Music=Tunes' <<< "$out"
check "areas: no title, the slug" grep -qx 'bare=bare=' <<< "$out"
check "areas: escape codes gone" not grep -q $'\033\|\007' <<< "$out"
check "areas: last line without a newline" grep -qx 'last=Last line=No newline at the end' <<< "$out"
printf 'general|General|Other things\ndemos|Demos|Demo text\nmusic|Music|Tunes\n' > "$root/etc/file-areas"
printf 'area=music\n' >> "$root/published/$O.meta"
printf 'area=demos\n' >> "$root/published/$M.meta"
printf 'area=demos\ndesc=About boss\n' >> "$root/published/$B.meta"
check "rows: only the area" eq "$(bob files_rows demos | cut -f6 | sort | tr '\n' ' ')" "boss.mod mid.lha "
check "rows: no file in it" eq "$(bob files_rows nosuch | wc -l)" 0
check "rows: all without an area given" eq "$(bob files_rows | cut -f7 | sort -u | wc -l)" 3
check "rows: the area column" eq "$(bob files_rows music | cut -f7)" music
check "rows: an empty description stays empty" eq "$(bob files_rows music | cut -f8)" ""
check "rows: the description column" eq "$(bob files_rows demos | head -n 1 | cut -f8)" "About boss"
check "rows: no area in .meta, the default" has "$(bob files_rows general | cut -f6)" secret.txt
out=$(printf 'q' | bob file_areas)
check "area menu: names and text" grep -q 'Demo text' <<< "$out"
check "area menu: counts" grep -q 'Demos.*2 files' <<< "$out"
check "area menu: one file" grep -q 'Music.*1 file' <<< "$out"
check "area menu: no files listed yet" not grep -q 'boss.mod' <<< "$out"
out=$(printf '2q' | bob file_areas; printf 'q' >/dev/null)
check "area menu: the number opens it" has 'Files: Demos' "$out"
check "area menu: its files" has 'boss.mod' "$out"
check "area menu: not the others" not grep -q 'old.zip' <<< "$out"
out=$(printf '2qq' | bob file_areas)
check "area menu: Q in an area comes back to the areas" eq "$(grep -c 'Demo text' <<< "$out")" 2
out=$(printf 'q' | run_as bbs-bob 1500000350 file_areas)
check "area menu: new files marked" grep -q 'Demos.*2 files \*' <<< "$out"
check "area menu: no mark without" not grep -q 'Music.*1 file \*' <<< "$out"
# Taken away and put back: the files go to the default area and return.
keep=$(cat "$root/published/$O.meta")
printf 'general|General|Other things\ndemos|Demos|Demo text\n' > "$root/etc/file-areas"
check "area removed: its file shows in the default" has old.zip "$(bob files_rows general | cut -f6)"
check "area removed: the column says the default" eq "$(bob files_rows general | grep -F "$O" | cut -f7)" general
check "area removed: the .meta is untouched" eq "$(cat "$root/published/$O.meta")" "$keep"
printf 'general|General|Other things\ndemos|Demos|Demo text\nmusic|Music|Tunes\n' > "$root/etc/file-areas"
check "area back: the file is back" eq "$(bob files_rows music | cut -f6)" old.zip
out=$(printf 'q' | bob files_menu nosuch)
check "list: unknown area, the default" has 'Files: General' "$out"
out=$(printf 'q' | run_as bbs-bob "" file_view "$(bob files_rows music)")
check "view: the area" grep -q 'Area: *Music' <<< "$out"
check "view: not the uploader, no move" not grep -q 'M) Move' <<< "$out"
{ for n in $(seq 1 14); do printf 'a%s|Area %s|Text %s\n' "$n" "$n" "$n"; done; } > "$root/etc/file-areas"
out=$(printf 'q' | bob file_areas)
check "many areas: a page" has 'Area 12' "$out"
check "many areas: not the rest" not grep -q 'Area 13' <<< "$out"
check "many areas: more" has 'N) More' "$out"
out=$(printf 'nq' | bob file_areas)
check "many areas: next page" has 'Area 14' "$out"
out=$(printf '14\nq' | bob file_areas)
check "many areas: two digits" has 'Files: Area 14' "$out"
rm -f "$root/etc/file-areas"

# --- list_fit: the quick way gives the same text as the table in wrap.py ---
fit_same() { # fit_same <width> <text>
    local fast slow
    fast=$(BBS_ROOT="$root" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb bash -c \
        'source "$1/lib/menu.sh" </dev/null; list_fit "$2" "$3"; printf "\\001"; list_fit_py "$2" "$3" 2>/dev/null' _ "$here" "$1" "$2")
    slow=${fast#*$'\001'}; fast=${fast%%$'\001'*}
    [[ $fast == "$slow" ]]
}
for t in "plain name.zip" "räksmörgås på måndag" "ÅÄÖ åäö éèü ÿ À × ÷" "ab   cd   ef   gh" "          " \
    "日本語のファイル名.zip" $'éxplain' "emoji 🎉 fil.zip" $'nbsp x' $'soft­hyphen' \
    $'bad\xe5byte' $'\xc3' $'tab\tx' 'pct %s \n * ? [a]'; do
    for w in 1 3 4 8 40; do check "list_fit same at $w: $t" fit_same "$w" "$t"; done
done

echo "files_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
