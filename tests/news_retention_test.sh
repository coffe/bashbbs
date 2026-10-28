#!/bin/bash
# Local test of the 14-day retention in sbin/bbs-drop (expire_news and the
# drop/rejected clean-up), plus the category allowlist for drop files.
# Usage: tests/news_retention_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/9270f812-a8e8-489e-98ef-c43ba3eb8e0a/scratchpad}
quar=$scratch/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs and files are moved here
log=${1:-$scratch/news_retention_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }

root=$(mktemp -d "$scratch/ret.XXXXXX")
mkdir -p "$root"/boards/news/{ai,security} "$root/boards/general" "$root/lib" "$root/drop/news" "$root/drop/rejected" "$root/queue/incoming"
cp "$here/lib/news-categories.conf" "$root/lib/"
now=$(date +%s)
old=$((now - 15 * 86400)); young=$((now - 13 * 86400))
eq_str() { [[ $1 == "$2" ]]; }
mk() { printf 'Msgid: x\n\nbody\n' > "$1"; }

mk "$root/boards/news/ai/$old-aaaa.msg"
mk "$root/boards/news/ai/$young-bbbb.msg"
mk "$root/boards/news/security/$old-cccc.msg"
mk "$root/boards/news/security/$now-dddd.msg"
mk "$root/boards/news/$old-legacy-old.msg"        # legacy flat layout
mk "$root/boards/news/$young-legacy-young.msg"
mk "$root/boards/news/notanepoch-x.msg"           # no epoch prefix: kept
mk "$root/boards/general/$old-eeee.msg"           # other boards are not touched
printf 'x\n' > "$root/drop/rejected/old.post";   touch -d '15 days ago' "$root/drop/rejected/old.post"
printf 'x\n' > "$root/drop/rejected/young.post"; touch -d '13 days ago' "$root/drop/rejected/young.post"
printf 'x\n' > "$root/drop/rejected/old.txt";    touch -d '30 days ago' "$root/drop/rejected/old.txt"
printf 't\n\nbody\n' > "$root/drop/news/tech-nope.txt"       # not in allowlist
printf 't\n\nbody\n' > "$root/drop/news/notacat.txt"

# Index with one row per section article (path is field 5). The rows of the old
# articles must go, the others stay, in order.
mkdir -p "$root/state/tmp"
n="$root/boards/news"
{
    printf 'id4\tsecurity\t%s\tfour\t%s\t2026-10-28\tS\tl\n' "$now" "$n/security/$now-dddd.msg"
    printf 'id2\tai\t%s\ttwo\t%s\t2026-10-15\tS\tl\n' "$young" "$n/ai/$young-bbbb.msg"
    printf 'id3\tsecurity\t%s\tthree\t%s\t2026-10-01\tS\tl\n' "$old" "$n/security/$old-cccc.msg"
    printf 'id1\tai\t%s\tone\t%s\t2026-10-01\tS\tl\n' "$old" "$n/ai/$old-aaaa.msg"
} > "$root/state/news-index.tsv"
chmod 644 "$root/state/news-index.tsv"
nice -n 19 env BBS_ROOT="$root" bash "$here/sbin/bbs-drop" >>"$log" 2>&1

n="$root/boards/news"
check "sections: old article removed (ai)"        test ! -e "$n/ai/$old-aaaa.msg"
check "sections: 13-day article kept (ai)"        test -e "$n/ai/$young-bbbb.msg"
check "sections: old article removed (security)"  test ! -e "$n/security/$old-cccc.msg"
check "sections: new article kept (security)"     test -e "$n/security/$now-dddd.msg"
check "legacy: old article removed"               test ! -e "$n/$old-legacy-old.msg"
check "legacy: 13-day article kept"               test -e "$n/$young-legacy-young.msg"
check "file without epoch prefix is kept"         test -e "$n/notanepoch-x.msg"
check "other boards untouched"                    test -e "$root/boards/general/$old-eeee.msg"
check "category directories are kept"             test -d "$n/ai"
check "rejected: 15-day file removed"             test ! -e "$root/drop/rejected/old.post"
check "rejected: 30-day file removed"             test ! -e "$root/drop/rejected/old.txt"
check "rejected: 13-day file kept"                test -e "$root/drop/rejected/young.post"
check "drop: category not in allowlist is rejected" test -e "$root/drop/rejected/tech-nope.txt"
check "drop: file without category is rejected"   test -e "$root/drop/rejected/notacat.txt"
check "drop: rejected files left drop/news"       bash -c '! compgen -G "$1/drop/news/*.txt"' _ "$root"
check "drop: nothing queued for a rejected file"  bash -c '! compgen -G "$1/queue/incoming/*"' _ "$root"

check "index: old rows removed"                   bash -c '! grep -q "^id1	\|^id3	" "$1"' _ "$root/state/news-index.tsv"
check "index: young rows kept in order"           bash -c '[[ $(cut -f1 "$1" | paste -sd,) == id4,id2 ]]' _ "$root/state/news-index.tsv"
check "index: no temp file left"                  bash -c '! compgen -G "$1/state/news-index.tmp.*" && ! compgen -G "$1/state/tmp/prune.*"' _ "$root"
check "index: still readable by others"           bash -c '[[ $(stat -c %a "$1") == 644 ]]' _ "$root/state/news-index.tsv"

# Nothing to expire: the index is not rewritten (same inode, same mtime).
ino=$(stat -c '%i %Y' "$root/state/news-index.tsv"); sleep 1.1
nice -n 19 env BBS_ROOT="$root" bash "$here/sbin/bbs-drop" >>"$log" 2>&1
check "index: untouched when nothing is expired"  eq_str "$(stat -c '%i %Y' "$root/state/news-index.tsv")" "$ino"
# Atomic: the rewrite is a rename of a temp file (new inode), never in place.
mk "$n/ai/$old-ffff.msg"
printf 'id5\tai\t%s\tfive\t%s\t2026-10-01\tS\tl\n' "$old" "$n/ai/$old-ffff.msg" >> "$root/state/news-index.tsv"
ino=$(stat -c %i "$root/state/news-index.tsv")
nice -n 19 env BBS_ROOT="$root" bash "$here/sbin/bbs-drop" >>"$log" 2>&1
check "index: rewrite is an atomic rename (new inode)" bash -c '[[ $(stat -c %i "$1") != "$2" ]] && ! grep -q "^id5	" "$1"' _ "$root/state/news-index.tsv" "$ino"
# Held lock: the index is left alone, the file is gone, a later run or repair fixes it.
mk "$n/ai/$old-gggg.msg"
printf 'id6\tai\t%s\tsix\t%s\t2026-10-01\tS\tl\n' "$old" "$n/ai/$old-gggg.msg" >> "$root/state/news-index.tsv"
flock "$root/state/news.lock" sleep 6 & holder=$!
sleep 0.5
nice -n 19 env BBS_ROOT="$root" BBS_LOCK_WAIT=1 bash "$here/sbin/bbs-drop" >>"$log" 2>&1
check "index: lock busy leaves the index unchanged" grep -q '^id6	' "$root/state/news-index.tsv"
pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# No index at all: no index is created.
mv -f "$root/state/news-index.tsv" "$quar/$(basename "$root")-index-$(date +%s%N).tsv" 2>/dev/null
mk "$n/ai/$old-hhhh.msg"
nice -n 19 env BBS_ROOT="$root" bash "$here/sbin/bbs-drop" >>"$log" 2>&1
check "index: none is created when there was none" test ! -e "$root/state/news-index.tsv"

mv "$scratch"/ret.* "$quar"/ 2>/dev/null
echo "news_retention_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
