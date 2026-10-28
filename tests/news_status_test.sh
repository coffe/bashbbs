#!/bin/bash
# Local test of bin/bbs-news-status: three columns, the 200 line limit,
# invalid ids, and that the ledger is never touched.
# Usage: tests/news_status_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/9270f812-a8e8-489e-98ef-c43ba3eb8e0a/scratchpad}
quar=$scratch/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs and files are moved here
log=${1:-$scratch/news_status_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }

root=$(mktemp -d "$scratch/st.XXXXXX")
mkdir -p "$root/state"
sha() { printf %s "$1" | sha256sum | cut -c1-64; }
ip=$(sha pub); ir=$(sha rej); iu=$(sha unk); id=$(sha dup)
legacy=legacy-0123abcd-0123-0123-0123-0123456789ab
T=$'\t'
printf '%s\tpublished\t100\t\n%s\trejected\t101\tbad-link\n%s\trejected\t102\tbad-link\n%s\tpublished\t103\tduplicate\n%s\tpublished\t104\t\n' \
    "$ip" "$ir" "$id" "$legacy" "$id" > "$root/state/news-ids.tsv"
: > "$root/state/news.lock"
chmod 444 "$root/state/news-ids.tsv"
before=$(sha256sum "$root/state/news-ids.tsv"); mt=$(stat -c %Y.%y "$root/state/news-ids.tsv")

st() { nice -n 19 env BBS_ROOT="$root" bash "$here/bin/bbs-news-status"; }
out=$(printf '%s\n%s\n%s\n%s\nbogus\n../../etc/passwd\n\n%s\n' "$ip" "$ir" "$iu" "$legacy" "$id" | st 2>>"$log")
printf '%s\n' "$out" >> "$log"
check "published: id TAB published TAB empty reason" eq "$(sed -n 1p <<<"$out")" "$ip${T}published${T}"
check "rejected: reason in third column"             eq "$(sed -n 2p <<<"$out")" "$ir${T}rejected${T}bad-link"
check "unknown id"                                   eq "$(sed -n 3p <<<"$out")" "$iu${T}unknown${T}"
check "legacy id is accepted"                        eq "$(sed -n 4p <<<"$out")" "$legacy${T}published${T}duplicate"
check "invalid id: dash, invalid, bad-id"            eq "$(sed -n 5p <<<"$out")" "-${T}invalid${T}bad-id"
check "path-like id is invalid"                      eq "$(sed -n 6p <<<"$out")" "-${T}invalid${T}bad-id"
check "empty line is invalid"                        eq "$(sed -n 7p <<<"$out")" "-${T}invalid${T}bad-id"
check "published wins over a later rejected row"     eq "$(sed -n 8p <<<"$out")" "$id${T}published${T}"
check "one output line per input line"               eq "$(wc -l <<<"$out")" 8
check "every output line has three columns"          bash -c '[[ -z $(awk -F"\t" "NF != 3" <<<"$1") ]]' _ "$out"

# More than 200 lines: only the first 200 are answered, a note goes to stderr.
big=$(for n in $(seq 1 250); do sha "n$n"; done)
cnt=$(printf '%s\n' "$big" | st 2>"$root/err" | wc -l)
check "max 200 lines answered"                       eq "$cnt" 200
check "overflow is logged on stderr"                 grep -q 'more than 200' "$root/err"
cnt=$(printf '%s\n' "$(head -n 200 <<<"$big")" | st 2>"$root/err" | wc -l)
check "exactly 200 lines are all answered"           eq "$cnt" 200
check "exactly 200 lines: no overflow note"          bash -c '! grep -q "more than" "$1"' _ "$root/err"

# Read-only: ledger content, mtime and permissions unchanged; no new files.
check "ledger content unchanged"                     eq "$(sha256sum "$root/state/news-ids.tsv")" "$before"
check "ledger mtime unchanged"                       eq "$(stat -c %Y.%y "$root/state/news-ids.tsv")" "$mt"
check "no files created in state/"                   eq "$(ls -A "$root/state" | sort | tr '\n' ' ')" "news-ids.tsv news.lock "
# No ledger at all: everything is unknown, still nothing written.
for f in "$root/state/news-ids.tsv" "$root/state/news.lock"; do mv -f "$f" "$quar/$(basename "$root")-$(basename "$f")-$(date +%s%N)" 2>/dev/null; done
check "no ledger: unknown"                           eq "$(printf '%s\n' "$ip" | st)" "$ip${T}unknown${T}"
check "no ledger: still nothing created"             eq "$(ls -A "$root/state" | wc -l)" 0
# A writer holds the exclusive lock: the reader waits and then reports "busy".
: > "$root/state/news.lock"
flock "$root/state/news.lock" sleep 30 & holder=$!
sleep 0.3
t0=$(date +%s)
printf '%s\n' "$ip" | nice -n 19 env BBS_ROOT="$root" timeout 20 bash "$here/bin/bbs-news-status" >/dev/null 2>&1; rc=$?
pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "ledger busy: exit 3 after waiting"            eq "$rc" 3

mv "$scratch"/st.* "$quar"/ 2>/dev/null
echo "news_status_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
