#!/bin/bash
# Test of the missing-index detection in lib/news.sh and of bbs-news-index.
# Never touches a real BBS: every case has its own BBS_ROOT in the scratchpad.
# Usage: tests/news_index_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/9270f812-a8e8-489e-98ef-c43ba3eb8e0a/scratchpad}
quar=$scratch/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs and files are moved here
log=${1:-$scratch/news_index_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }

newroot() {
    root=$(mktemp -d "$scratch/idx.XXXXXX")
    mkdir -p "$root"/boards/news/{ai,security} "$root/state/tmp" "$root/lib" "$root/meta"
    cp "$here/lib/news-categories.conf" "$root/lib/"
    : > "$root/meta/news.sections"
    miss=$root/state/news-index-missing.log
}
article() { # article <cat> <epoch> <id-char> <title>
    local id iso; id=$(printf '%064d' 0 | tr 0 "$3"); iso=$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)
    printf 'Board: news\nSubject: %s\nMsgid: m\nAuthor: news\nDate: %s\nCategory: %s\nArticle-Id: %s\nSource: Src\nPublished: %s\nLede: A lede.\n\nBody text.\n' \
        "$4" "$iso" "$1" "$id" "$iso" > "$root/boards/news/$1/$2-$(cat /proc/sys/kernel/random/uuid).msg"
}
# Run a reader snippet with the library loaded (menu.sh gives safe() and the news functions).
reader() { # reader <snippet>  -> stdout; stderr to the log
    nice -n 19 env BBS_ROOT="$root" BBS_COLS=60 BBS_ROWS=24 BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=xterm LC_ALL=C.UTF-8 HOME="$root" \
        bash -c 'source "$1"; '"$1" _ "$here/lib/menu.sh" 2>>"$log" < /dev/null
}
tool() { nice -n 19 env BBS_ROOT="$root" BBS_LIB="$here/lib" BBS_LOCK_WAIT=2 bash "$here/sbin/bbs-news-index" "$@"; }

# ---- 1. index missing, articles exist --------------------------------------
newroot
article ai 1793000000 a "First"
article security 1793000100 b "Second"
out=$(reader 'news_index "$BBS_ROOT"')
check "missing+articles: news_index prints no rows" eq "$out" ""
check "missing+articles: log file created" test -s "$miss"
check "missing+articles: log names the repair command" grep -q 'bbs-news-index repair' "$miss"
out=$(reader 'news_load_index; echo "n=${#NEWS_ORDER[@]} notice=$NEWS_NOTICE"')
check "missing+articles: notice set, list not shown as empty-and-fine" eq "$out" "n=0 notice=News index missing - reported to sysop"
out=$(reader 'news_board')
check "missing+articles: News menu shows the notice row" bash -c 'grep -q "News index missing - reported to sysop" <<<"$1"' _ "$out"
check "missing+articles: menu is still usable (sections listed)" bash -c 'grep -q "ai" <<<"$1"' _ "$out"
n1=$(wc -l < "$miss")
reader 'news_load_index' >/dev/null
check "missing+articles: log not repeated within five minutes" eq "$(wc -l < "$miss")" "$n1"
# Unwritable state/: still shows the notice, does not fail.
mv -f "$miss" "$quar/$(basename "$root")-log-$(date +%s%N)" 2>/dev/null; chmod 555 "$root/state"
out=$(reader 'news_load_index; echo "notice=$NEWS_NOTICE"')
chmod 755 "$root/state"
check "missing+articles, log not writable: notice still set" eq "$out" "notice=News index missing - reported to sysop"

# ---- 2. index missing, no articles -----------------------------------------
newroot
out=$(reader 'news_index "$BBS_ROOT"; news_load_index; echo "n=${#NEWS_ORDER[@]} notice=[$NEWS_NOTICE]"')
check "missing, no articles: empty list, no notice" eq "$out" "n=0 notice=[]"
check "missing, no articles: no log" test ! -e "$miss"
out=$(reader 'news_board')
check "missing, no articles: menu without the notice row" bash -c '! grep -q "index missing" <<<"$1"' _ "$out"
# Category directories with only non-article files count as no articles.
: > "$root/boards/news/ai/notes.txt"
reader 'news_load_index' >/dev/null
check "missing, only non-.msg files: no log" test ! -e "$miss"

# ---- 3. index present: used, nothing logged --------------------------------
newroot
article ai 1793000000 a "First"
tool rebuild 2>>"$log"
out=$(reader 'news_load_index; echo "n=${#NEWS_ORDER[@]} notice=[$NEWS_NOTICE]"')
check "index present: one article listed, no notice" eq "$out" "n=1 notice=[]"
check "index present: no log" test ! -e "$miss"

# ---- 4. bbs-news-index repair ------------------------------------------------
newroot
article ai 1793000000 a "First"
article ai 1793000200 c "Third"
check "repair: missing index with articles is rebuilt" tool repair
check "repair: two rows" eq "$(wc -l < "$root/state/news-index.tsv")" 2
check "repair: newest first" eq "$(cut -f4 "$root/state/news-index.tsv" | paste -sd,)" "Third,First"
check "repair: no temp file left" bash -c '! compgen -G "$1/state/.news-index.tsv.*" && ! compgen -G "$1/state/news-index.tmp.*"' _ "$root"
article security 1793000300 b "Fourth"
before=$(cat "$root/state/news-index.tsv")
check "repair: no marker and index present: nothing happens" tool repair
check "repair: index unchanged without a marker" eq "$(cat "$root/state/news-index.tsv")" "$before"
: > "$root/state/news-index.dirty"
check "repair: with marker the index is rebuilt" tool repair
check "repair: three rows after marker repair" eq "$(wc -l < "$root/state/news-index.tsv")" 3
check "repair: marker removed" test ! -e "$root/state/news-index.dirty"
: > "$root/state/news-index.dirty"
tool repair 2>>"$log"
check "repair: second repair gives no duplicates" eq "$(cut -f1 "$root/state/news-index.tsv" | sort | uniq -d | wc -l)" 0
check "repair: never touches the article files" eq "$(find "$root/boards/news" -name '*.msg' | wc -l)" 3
# Lock held by someone else: repair with a marker fails, keeps the marker.
: > "$root/state/news-index.dirty"
flock "$root/state/news.lock" sleep 5 & holder=$!
sleep 0.5
check "repair: busy lock gives non-zero exit" bash -c '! BBS_ROOT="$1" BBS_LIB="$2/lib" BBS_LOCK_WAIT=1 bash "$2/sbin/bbs-news-index" repair' _ "$root" "$here"
check "repair: busy lock keeps the marker" test -e "$root/state/news-index.dirty"
pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "repair: bad argument is refused" bash -c '! BBS_ROOT="$1" BBS_LIB="$2/lib" bash "$2/sbin/bbs-news-index" frobnicate' _ "$root" "$here"

# ---- 4. index paths are checked before the reader opens them ---------------
newroot
ida=$(printf '%064d' 0 | tr 0 a); idb=$(printf '%064d' 0 | tr 0 b)
idc=$(printf '%064d' 0 | tr 0 c); idd=$(printf '%064d' 0 | tr 0 d)
ide=$(printf '%064d' 0 | tr 0 e); idf=$(printf '%064d' 0 | tr 0 f)
idg=$(printf '%064d' 0 | tr 0 g)
good=$root/boards/news/ai/1793000000-aaaa-bbbb.msg
: > "$good"
{
    printf '%s\tai\t1793000000\tGood\t%s\t2026-10-28\tSrc\tLede\n' "$ida" "$good"
    printf '%s\tai\t1793000000\tRelative\tnews/ai/1793000000-aaaa-bbbb.msg\t2026-10-28\tSrc\tL\n' "$idb"
    printf '%s\tai\t1793000000\tTraversal\t%s/boards/news/ai/../../../../etc/passwd\t2026-10-28\tSrc\tL\n' "$idc" "$root"
    printf '%s\tai\t1793000000\tOtherDir\t%s/boards/news/security/1793000000-aaaa-bbbb.msg\t2026-10-28\tSrc\tL\n' "$ide" "$root"
    printf '%s\tevil\t1793000000\tBadCat\t%s/boards/news/evil/1793000000-aaaa-bbbb.msg\t2026-10-28\tSrc\tL\n' "$idf" "$root"
    printf '%s\tai\t1793000000\tAbsolute\t/etc/passwd\t2026-10-28\tSrc\tL\n' "$idg"
    printf '%s\tai\t1793000000\tSubdir\t%s/boards/news/ai/x/1793000000-aaaa-bbbb.msg\t2026-10-28\tSrc\tL\n' "$idd" "$root"
} > "$root/state/news-index.tsv"
out=$(reader 'news_load_index; echo "${#NEWS_ORDER[@]} ${NEWS_ORDER[*]}"')
check "paths: only the row inside boards/news/<cat>/ is loaded" eq "$out" "1 $ida"
check "paths: exactly one path is kept in NEWS_PATH" eq "$(reader 'news_load_index; echo "${#NEWS_PATH[@]}"')" 1

mv "$scratch"/idx.* "$quar"/ 2>/dev/null
echo "news_index_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
