#!/bin/bash
# Local test of the news section path in sbin/bbs-publish. Never touches a real
# BBS: every run uses its own BBS_ROOT under the scratchpad.
# Usage: tests/news_publish_test.sh [logfile]   (full log in the file; the
# screen shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/9270f812-a8e8-489e-98ef-c43ba3eb8e0a/scratchpad}
quar=$scratch/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs and files are moved here
log=${1:-$scratch/news_publish_test.log}
: > "$log"
me=$(id -un)
pass=0; fail=0

check() { # check <description> <command...>   (command is run as argument list)
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}

newroot() { # newroot [nomarker]
    root=$(mktemp -d "$scratch/pub.XXXXXX")
    mkdir -p "$root"/{boards/news,boards/general,meta,queue/incoming,state/tmp,lib,drop}
    cp "$here/lib/news-categories.conf" "$root/lib/"
    : > "$root/meta/news.readonly"
    [[ ${1:-} == nomarker ]] || : > "$root/meta/news.sections"
    q=$root/queue/incoming
    rej=$root/drop/rejected
}
publish() { nice -n 19 env BBS_ROOT="$root" BBS_LIB="$here/lib" BBS_TEST_OWNER="$me" BBS_LOCK_WAIT=2 bash "$here/sbin/bbs-publish" >>"$log" 2>&1; }
# process() return code, with the script sourced (not run).
proc_rc() { ( export BBS_ROOT="$root" BBS_LIB="$here/lib" BBS_TEST_OWNER="$me" BBS_LOCK_WAIT=2
              # shellcheck disable=SC1090
              source "$here/sbin/bbs-publish"; process "$1" >>"$log" 2>&1; echo $? ); }

sha() { printf %s "$1" | sha256sum | cut -c1-64; }
hdr() { # hdr <id> [category]
    printf 'Board: news\nSubject: A title åäö\nCategory: %s\nArticle-Id: %s\nSource: Test Source\nPublished: 2026-10-28T07:00:00Z\n' "${2:-ai}" "$1"
}
put() { cat > "$q/$1.post"; } # content on stdin
msgs() { find "$root/boards/news" -name '*.msg' | wc -l; }
ledger_rows() { grep -c "^$1	$2	" "$root/state/news-ids.tsv" 2>/dev/null; }
has_ledger() { grep -q "^$1	$2	[0-9]*	$3\$" "$root/state/news-ids.tsv"; }
in_rejected() { compgen -G "$rej/$1.post" >/dev/null; }
eq() { [[ $1 == "$2" ]]; }

# ---- 1. a valid post is published -----------------------------------------
newroot
id=$(sha one)
{ hdr "$id"; printf 'Link: https://example.com/a?b=1\nLede: A short lede.\nOriginal-Language: sv\n\nFirst paragraph with åäö.\n'; } | put 1000-a
publish
check "valid post: one .msg in the category dir" eq "$(msgs)" 1
f=$(find "$root/boards/news/ai" -name '*.msg')
check "valid post: file name is <epoch>-<uuid>.msg" bash -c '[[ $(basename "$1") =~ ^[0-9]+-[0-9a-f-]{36}\.msg$ ]]' _ "$f"
check "valid post: headers written" bash -c 'for h in "Category: ai" "Article-Id: $2" "Source: Test Source" "Published: 2026-10-28T07:00:00Z" "Link: https://example.com/a?b=1" "Lede: A short lede." "Original-Language: sv" "Subject: A title åäö" "Author: news" "Board: news"; do grep -qxF -- "$h" "$1" || { echo "missing $h"; exit 1; }; done' _ "$f" "$id"
check "valid post: body after blank line" grep -qxF 'First paragraph with åäö.' "$f"
check "valid post: ledger row published, empty reason" has_ledger "$id" published ""
check "valid post: queue file removed" bash -c '! compgen -G "$1/*.post"' _ "$q"
check "valid post: ledger readable by others" bash -c '[[ $(stat -c %a "$1") == 644 ]]' _ "$root/state/news-ids.tsv"
check "valid post: no leftovers in state/tmp" bash -c '! compgen -G "$1/*"' _ "$root/state/tmp"

# ---- 2. duplicates ---------------------------------------------------------
{ hdr "$id"; printf '\nSecond copy.\n'; } | put 1001-b
publish
check "duplicate: still one .msg" eq "$(msgs)" 1
check "duplicate: queue file removed" bash -c '! compgen -G "$1/*.post"' _ "$q"
check "duplicate: still one published row" eq "$(ledger_rows "$id" published)" 1
# On disk but not in the ledger (migrated article): row with reason duplicate.
id2=$(sha two)
mkdir -p "$root/boards/news/security"
printf 'Msgid: x\nArticle-Id: %s\n\nold\n' "$id2" > "$root/boards/news/security/1-x.msg"
{ hdr "$id2" security; printf '\nbody\n'; } | put 1002-c
publish
check "duplicate on disk: no new .msg" eq "$(msgs)" 2
check "duplicate on disk: ledger published/duplicate" has_ledger "$id2" published duplicate

# ---- 3. permanent rejects --------------------------------------------------
reject_case() { # reject_case <name> <expected reason or -> <id or ""> ; post on stdin
    local name=$1 reason=$2 rid=$3 before; before=$(msgs)
    put "2000-$name"; publish
    check "$name: no new .msg" eq "$(msgs)" "$before"
    check "$name: moved to drop/rejected" in_rejected "2000-$name"
    check "$name: removed from queue" bash -c '[[ ! -e "$1" ]]' _ "$q/2000-$name.post"
    if [[ $reason == - ]]; then
        check "$name: no ledger row" bash -c '! grep -q "$1" "$2" 2>/dev/null' _ "${rid:-NOID}" "$root/state/news-ids.tsv"
    else
        check "$name: ledger rejected/$reason" has_ledger "$rid" rejected "$reason"
    fi
}
i=$(sha cat); reject_case badcat bad-category "$i" < <({ hdr "$i" nonsense; printf '\nb\n'; })
i=$(sha pathcat); reject_case pathcat bad-category "$i" < <({ hdr "$i" '../x'; printf '\nb\n'; })
reject_case badid - "" < <({ hdr NOTANID; printf '\nb\n'; })
reject_case longid - "" < <({ hdr "${id}00"; printf '\nb\n'; })
i=$(sha ftp); reject_case ftp bad-link "$i" < <({ hdr "$i"; printf 'Link: ftp://example.com/x\n\nb\n'; })
i=$(sha js); reject_case js bad-link "$i" < <({ hdr "$i"; printf 'Link: javascript:alert(1)\n\nb\n'; })
i=$(sha space); reject_case space bad-link "$i" < <({ hdr "$i"; printf 'Link: https://example.com/a b\n\nb\n'; })
i=$(sha long); reject_case longlink bad-link "$i" < <({ hdr "$i"; printf 'Link: https://example.com/%s\n\nb\n' "$(head -c 400 /dev/zero | tr '\0' a)"; })
i=$(sha dupsrc); reject_case dupheader bad-headers "$i" < <({ hdr "$i"; printf 'Source: Other\n\nb\n'; })
i=$(sha cr); reject_case crheader bad-headers "$i" < <({ hdr "$i"; printf 'Lede: ok\rMsgid: injected\n\nb\n'; })
i=$(sha esc); reject_case escheader bad-headers "$i" < <({ hdr "$i"; printf 'Lede: x\033[31mred\n\nb\n'; })
i=$(sha nul); reject_case nulheader bad-headers "$i" < <({ hdr "$i"; printf 'Lede: x\000y\n\nb\n'; })
i=$(sha junk); reject_case junkheader bad-headers "$i" < <({ hdr "$i"; printf 'not a header line\n\nb\n'; })
i=$(sha date); reject_case baddate bad-headers "$i" < <({ hdr "$i" | sed 's/2026-10-28T07:00:00Z/2026-13-45T07:00:00Z/'; printf '\nb\n'; })
i=$(sha src61); reject_case longsource bad-headers "$i" < <({ hdr "$i" | sed "s/Test Source/$(head -c 61 /dev/zero | tr '\0' s)/"; printf '\nb\n'; })
i=$(sha lede201); reject_case longlede bad-headers "$i" < <({ hdr "$i"; printf 'Lede: %s\n\nb\n' "$(head -c 201 /dev/zero | tr '\0' l)"; })
i=$(sha lang); reject_case badlang bad-headers "$i" < <({ hdr "$i"; printf 'Original-Language: Swedish!\n\nb\n'; })
i=$(sha bigbody); reject_case bigbody too-large "$i" < <({ hdr "$i"; printf '\n'; head -c 11500 /dev/zero | tr '\0' x; printf '\n'; })
# The 11000-byte limit itself passes (headers stay far below 16384 bytes).
i=$(sha okbody); { hdr "$i"; printf '\n'; head -c 10990 /dev/zero | tr '\0' x; printf '\n'; } | put 2100-okbody
publish
check "body just under the limit is published" has_ledger "$i" published ""
i=$(sha bigfile); reject_case bigfile too-large "$i" < <({ hdr "$i"; printf '\n'; head -c 17000 /dev/zero | tr '\0' x; })

# A body line that looks like a header cannot inject anything.
i=$(sha bodyinj); { hdr "$i"; printf '\nCategory: security\nMsgid: evil\n'; } | put 2200-bodyinj
publish
f=$(grep -l "^Article-Id: $i" "$root"/boards/news/*/*.msg)
check "body header lookalike stays in the body" bash -c 'sed "/^\$/q" "$1" | grep -qx "Category: ai" && ! sed "/^\$/q" "$1" | grep -q "evil"' _ "$f"

# Path safety: no stray directories were created by hostile categories.
check "no directory outside the allowlist" bash -c '[[ -z $(find "$1" -mindepth 1 -maxdepth 1 -type d | grep -vE "/(ai|security)$") ]]' _ "$root/boards/news"

# ---- 4. other boards are unchanged ----------------------------------------
printf 'Board: general\nSubject: Hello\n\nplain text\n' | put 3000-general
publish
g=$(find "$root/boards/general" -name '*.msg')
check "general board: post written" test -n "$g"
check "general board: classic header order (Msgid first)" bash -c 'head -n 1 "$1" | grep -q "^Msgid: "' _ "$g"
check "general board: no news headers" bash -c '! grep -q "^Category:\|^Article-Id:" "$1"' _ "$g"
printf 'Board: nosuch\nSubject: Hello\n\nx\n' | put 3001-nosuch
publish
check "unknown board: rejected as before (removed)" bash -c '[[ ! -e "$1" ]]' _ "$q/3001-nosuch.post"

# Board news with section headers but no marker: bad-board, not written flat.
newroot nomarker
i=$(sha nomarker); { hdr "$i"; printf '\nb\n'; } | put 3100-nomarker
publish
check "news without marker + section headers: nothing written" eq "$(msgs)" 0
check "news without marker + section headers: quarantined" in_rejected 3100-nomarker
# Legacy post (no section headers) still lands flat in boards/news.
printf 'Board: news\nSubject: [TECH] legacy\n\nbody\n' | put 3101-legacy
publish
check "legacy news post without marker: written flat" bash -c 'compgen -G "$1/boards/news/*.msg"' _ "$root"

# ---- 5. concurrent duplicates ---------------------------------------------
newroot
for n in 1 2 3 4 5; do
    i=$(sha "race$n")
    { hdr "$i"; printf '\nbody %s\n' "$n"; } | put "4000-$n-a"
    { hdr "$i"; printf '\nbody %s again\n' "$n"; } | put "4000-$n-b"
done
publish & p1=$!
publish & p2=$!
wait "$p1" "$p2"
check "race: five articles, five .msg" eq "$(msgs)" 5
for n in 1 2 3 4 5; do
    i=$(sha "race$n")
    check "race $n: exactly one published row" eq "$(grep -c "^$i	published	" "$root/state/news-ids.tsv")" 1
    check "race $n: exactly one .msg" eq "$(grep -l "^Article-Id: $i" "$root"/boards/news/*/*.msg | wc -l)" 1
done
check "race: queue empty" bash -c '! compgen -G "$1/*.post"' _ "$q"

# ---- 6. temporary failure: return 2, queue file stays -----------------------
newroot
i=$(sha lockheld); { hdr "$i"; printf '\nb\n'; } | put 5000-lock
: > "$root/state/news.lock"
flock "$root/state/news.lock" sleep 30 & holder=$!
sleep 0.5
check "lock timeout: process() returns 2" eq "$(proc_rc "$q/5000-lock.post")" 2
publish
check "lock timeout: queue file stays" test -e "$q/5000-lock.post"
check "lock timeout: no ledger row" bash -c '! grep -q "$1" "$2" 2>/dev/null' _ "$i" "$root/state/news-ids.tsv"
check "lock timeout: nothing in rejected" bash -c '! compgen -G "$1/*"' _ "$rej"
check "lock timeout: no .msg" eq "$(msgs)" 0
pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
publish
check "after the lock is free: published" has_ledger "$i" published ""
check "after the lock is free: queue file removed" bash -c '[[ ! -e "$1" ]]' _ "$q/5000-lock.post"

# ---- 7. stale: temporary errors for 24 hours -> rejected/stale -------------
i=$(sha stale); { hdr "$i"; printf '\nb\n'; } | put 6000-stale
chmod 555 "$root/state/tmp"       # scratch space unusable: a temporary failure
check "temporary error: process() returns 2" eq "$(proc_rc "$q/6000-stale.post")" 2
publish
check "young file with temporary error stays" test -e "$q/6000-stale.post"
touch -d '23 hours ago' "$q/6000-stale.post"
publish
check "23 hours old file still stays" test -e "$q/6000-stale.post"
touch -d '25 hours ago' "$q/6000-stale.post"
publish
chmod 755 "$root/state/tmp"
check "25 hours old file: removed from queue" bash -c '[[ ! -e "$1" ]]' _ "$q/6000-stale.post"
check "25 hours old file: moved to drop/rejected" in_rejected 6000-stale
check "25 hours old file: ledger rejected/stale" has_ledger "$i" rejected stale
check "rejected file mtime is reset (retention counts from rejection)" bash -c '[[ $(( $(date +%s) - $(stat -c %Y "$1") )) -lt 300 ]]' _ "$rej/6000-stale.post"


# ---- 8. news index: row on publish, newest first, no duplicate row ---------
INDEXF() { echo "$root/state/news-index.tsv"; }
idx_rows() { wc -l < "$(INDEXF)" 2>/dev/null || echo 0; }
newroot
ia=$(sha idxA); ib=$(sha idxB); ic=$(sha idxC)
{ hdr "$ia" ai | sed 's/2026-10-28T07:00:00Z/2026-10-20T07:00:00Z/'; printf 'Lede: Lede A.\n\nbody A\n'; } | put 7000-a
publish
check "index: one row after the first publication" eq "$(idx_rows)" 1
row=$(cat "$(INDEXF)")
f=$(find "$root/boards/news/ai" -name '*.msg')
pe=$(date -u -d 2026-10-20T07:00:00Z +%s)
check "index: eight fields" bash -c '[[ $(awk -F"\t" "{print NF}" <<<"$1") == 8 ]]' _ "$row"
check "index: id, category, epoch (Published), title" bash -c 'IFS=$'"'"'\t'"'"' read -r a b c d _ <<<"$1"; [[ $a == "$2" && $b == ai && $c == "$3" && $d == "A title åäö" ]]' _ "$row" "$ia" "$pe"
check "index: path, date, source, lede" bash -c 'IFS=$'"'"'\t'"'"' read -r _ _ _ _ e g h i <<<"$1"; [[ $e == "$2" && $g == 2026-10-20 && $h == "Test Source" && $i == "Lede A." ]]' _ "$row" "$f"
check "index: no marker after a normal publication" bash -c '[[ ! -e "$1" ]]' _ "$root/state/news-index.dirty"
check "index: no temp file left" bash -c '! compgen -G "$1/state/news-index.tmp.*"' _ "$root"
check "index: readable by others" bash -c '[[ $(stat -c %a "$1") == 644 ]]' _ "$(INDEXF)"
{ hdr "$ib" security | sed 's/2026-10-28T07:00:00Z/2026-10-27T07:00:00Z/'; printf '\nbody B\n'; } | put 7001-b
publish
check "index: two rows" eq "$(idx_rows)" 2
check "index: newest first" bash -c '[[ $(cut -f1 "$1" | head -n 1) == "$2" && $(cut -f1 "$1" | tail -n 1) == "$3" ]]' _ "$(INDEXF)" "$ib" "$ia"
{ hdr "$ib" security; printf '\nbody B again\n'; } | put 7002-b2
publish
check "index: duplicate gives no extra row" eq "$(idx_rows)" 2
check "index: duplicate gives no extra file" eq "$(msgs)" 2
# Same id as an existing index row but a lost ledger: still silent, no row.
grep -v "^$ib	" "$root/state/news-ids.tsv" > "$root/state/l.tmp"; mv "$root/state/l.tmp" "$root/state/news-ids.tsv"
{ hdr "$ib" security; printf '\nbody B third\n'; } | put 7003-b3
publish
check "index: id already in the index gives no extra row" eq "$(idx_rows)" 2

# ---- 9. interrupted publication: marker + missing row -> repair -------------
# State after a crash between mv (c) and the index write (d): article on disk,
# marker set, no index row.
printf '%s\tpublished\t1\t\n' "$ib" >> "$root/state/news-ids.tsv"
grep -v "^$ib	" "$(INDEXF)" > "$root/state/i.tmp"; mv "$root/state/i.tmp" "$(INDEXF)"
: > "$root/state/news-index.dirty"
check "crash: row is missing before the repair" eq "$(idx_rows)" 1
check "crash: bbs-news-index repair succeeds" nice -n 19 env BBS_ROOT="$root" BBS_LIB="$here/lib" BBS_LOCK_WAIT=2 bash "$here/sbin/bbs-news-index" repair
check "crash: repair restored the row" eq "$(idx_rows)" 2
check "crash: repair removed the marker" bash -c '[[ ! -e "$1" ]]' _ "$root/state/news-index.dirty"
check "crash: repair kept newest first" bash -c '[[ $(cut -f1 "$1" | head -n 1) == "$2" ]]' _ "$(INDEXF)" "$ib"
check "crash: second repair, no change" bash -c 'before=$(cat "$2"); BBS_ROOT="$1" BBS_LIB="$3/lib" bash "$3/sbin/bbs-news-index" repair && [[ $(cat "$2") == "$before" ]]' _ "$root" "$(INDEXF)" "$here"
: > "$root/state/news-index.dirty"
check "crash: repair again with a marker gives no duplicate" bash -c 'BBS_ROOT="$1" BBS_LIB="$3/lib" bash "$3/sbin/bbs-news-index" repair && [[ $(wc -l < "$2") == 2 && $(cut -f1 "$2" | sort | uniq -d | wc -l) == 0 ]]' _ "$root" "$(INDEXF)" "$here"
# bbs-publish itself repairs at the start of a run.
grep -v "^$ib	" "$(INDEXF)" > "$root/state/i.tmp"; mv "$root/state/i.tmp" "$(INDEXF)"
: > "$root/state/news-index.dirty"
publish
check "crash: bbs-publish start repairs the index" eq "$(idx_rows)" 2
check "crash: bbs-publish start removes the marker" bash -c '[[ ! -e "$1" ]]' _ "$root/state/news-index.dirty"
# Index lost while articles exist: the next publication must not leave a one-row index.
mv -f "$(INDEXF)" "$quar/$(basename "$root")-index-$(date +%s%N).tsv" 2>/dev/null
{ hdr "$ic" ai | sed 's/2026-10-28T07:00:00Z/2026-10-28T06:00:00Z/'; printf '\nbody C\n'; } | put 7004-c
publish
check "lost index: rebuilt with all three articles" eq "$(idx_rows)" 3
check "lost index: no marker left" bash -c '[[ ! -e "$1" ]]' _ "$root/state/news-index.dirty"
check "lost index: newest first" bash -c '[[ $(cut -f1 "$1" | head -n 1) == "$2" ]]' _ "$(INDEXF)" "$ic"
# Index matches a full rebuild exactly (same bytes), apart from ties.
cp "$(INDEXF)" "$root/state/inc.tsv"
check "rebuild equals incremental index" bash -c 'BBS_ROOT="$1" BBS_LIB="$3/lib" bash "$3/sbin/bbs-news-index" rebuild 2>/dev/null; cmp "$2" "$1/state/news-index.tsv"' _ "$root" "$root/state/inc.tsv" "$here"

# First article ever: index is created with one row.
newroot
i=$(sha first); { hdr "$i"; printf '\nb\n'; } | put 7100-first
publish
check "first publication creates the index" eq "$(idx_rows)" 1

mv "$scratch"/pub.* "$quar"/ 2>/dev/null
echo "news_publish_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
