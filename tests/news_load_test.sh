#!/bin/bash
# Load test for the news index and reader in lib/news.sh, no terminal needed.
# Usage: tests/news_load_test.sh [N ...]        (default N: 200 300 500)
# Env:   BBS_TEST_TMP   parent directory for the scratch root (default: $TMPDIR or /tmp)
# Generates N articles in a scratch BBS_ROOT (7 categories, 14 days of epochs),
# then times, in ms: news_load_index; news_list page 1 of the first category and
# the last page of it (the list is fed "Q" on stdin, the last page is drawn
# directly with news_draw_list); news_read of the first and of the last article
# (fed "Q" on stdin). Also checks that no list line is wider than 76 columns.
# Run with `nice -n 19` on a shared machine. No network, nothing outside the
# scratch directory is touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${BBS_TEST_TMP:-${TMPDIR:-/tmp}}/news_load.XXXXXX") || exit 1
quar=${BBS_TEST_TMP:-${TMPDIR:-/tmp}}/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs go to quarantine
trap 'mv "$tmp" "$quar"/ 2>/dev/null' EXIT
export LC_ALL=C.UTF-8 TERM=xterm BASHBBS_TEST=1 BBS_COLS=80 BBS_ROWS=24
Ns=("$@"); (( ${#Ns[@]} )) || Ns=(200 300 500)

gen() { # gen ROOT N
python3 -I - "$1" "$2" <<'PY'
import hashlib, os, sys, time, random
root, n = sys.argv[1], int(sys.argv[2])
cats = "ai security tech-society games-anime events did-you-know other".split()
rnd = random.Random(42)
now = int(time.time())
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
para = ("Researchers at the Örebro lab say a small model can run on a phone. The team, led by Åsa Öberg, "
        "tested it against larger systems and found little difference on everyday tasks. ")
for i in range(n):
    cat = cats[i % 7]
    t = now - 3600 - rnd.randrange(14 * 86400)
    aid = hashlib.sha256(b"load%d" % i).hexdigest()
    mid = "00000000-0000-4000-8000-%012d" % i
    d = os.path.join(root, "boards", "news", cat)
    os.makedirs(d, exist_ok=True)
    hdr = ["Board: news", "Subject: Article %d about %s: a fairly long headline that needs wrapping on small screens" % (i, cat),
           "Msgid: " + mid, "Author: news", "Node: test", "Date: " + iso(t), "Category: " + cat,
           "Article-Id: " + aid, "Source: Test Wire", "Published: " + iso(t), "Link: https://example.org/a/%d" % i]
    if i % 2:
        hdr.append("Lede: " + para[:150])
    body = "\n\n".join(para * 2 for _ in range(6))
    with open(os.path.join(d, "%d-%s.msg" % (t, mid)), "w", encoding="utf-8") as fh:
        fh.write("\n".join(hdr) + "\n\n" + body + "\n")
PY
}

ms() { echo $(( ($2 - $1) / 1000000 )); }

export BBS_ROOT=$tmp/seed
# shellcheck source=../lib/menu.sh
source "$here/lib/menu.sh"
fail=0
printf '%-6s %10s %12s %9s %9s %9s %9s\n' N index-ms index-ms/1000 list1-ms listN-ms read1-ms readN-ms
for N in "${Ns[@]}"; do
    root=$tmp/root$N; BBS_ROOT=$root
    gen "$root" "$N"
    # (a) index (news_index alone, then the full load into arrays)
    # (the index file is built once, as the explicit repair step; timed separately)
    t0=$(date +%s%N); news_rebuild_index "$root"; t1=$(date +%s%N); rebuild=$(ms "$t0" "$t1")
    t0=$(date +%s%N); news_index "$root" > "$tmp/idx.out"; t1=$(date +%s%N); idx_only=$(ms "$t0" "$t1")
    t0=$(date +%s%N); news_load_index; t1=$(date +%s%N); idx=$(ms "$t0" "$t1")
    got=${#NEWS_ORDER[@]}
    (( got == N )) || { echo "FAIL: index has $got articles, expected $N"; fail=1; }
    # (b) list: first category, page 1 via news_list, last page via news_draw_list
    cat=${NEWS_CATS[0]}; ctx=()
    for id in "${NEWS_ORDER[@]}"; do [[ ${NEWS_CAT[$id]} == "$cat" ]] && ctx+=("$id"); done
    total=${#ctx[@]}; pages=$(( (total + NEWS_PAGE - 1) / NEWS_PAGE )); first=$(( (pages - 1) * NEWS_PAGE ))
    t0=$(date +%s%N); echo Q | news_list ctx "$cat" > "$tmp/list1.out"; t1=$(date +%s%N); l1=$(ms "$t0" "$t1")
    news_width
    t0=$(date +%s%N); news_draw_list ctx "$cat" "$first" "$first" "$total" "$pages" "$pages" > "$tmp/listN.out"; t1=$(date +%s%N); lN=$(ms "$t0" "$t1")
    # (c) read: first and last article of the whole index, "Q" on stdin
    all=("${NEWS_ORDER[@]}")
    t0=$(date +%s%N); echo Q | news_read all 0 > "$tmp/read1.out"; t1=$(date +%s%N); r1=$(ms "$t0" "$t1")
    t0=$(date +%s%N); echo Q | news_read all $((N - 1)) > "$tmp/readN.out"; t1=$(date +%s%N); rN=$(ms "$t0" "$t1")
    # width check on every captured screen (ESC clear sequences removed)
    wide=$(python3 -I - "$here/lib" "$tmp"/list1.out "$tmp"/listN.out "$tmp"/read1.out "$tmp"/readN.out <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import wrap as wr
bad = 0
for f in sys.argv[2:]:
    txt = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", open(f, encoding="utf-8").read())
    for ln in txt.split("\n"):
        if wr.vwidth(ln) > 76:
            bad += 1
print(bad)
PY
)
    [[ $wide == 0 ]] || { echo "FAIL: N=$N: $wide lines wider than 76 columns"; fail=1; }
    grep -q 'Page 1 of' "$tmp/list1.out" || { echo "FAIL: N=$N: list page 1 missing"; fail=1; }
    grep -q "Page $pages of $pages" "$tmp/listN.out" || { echo "FAIL: N=$N: last list page missing"; fail=1; }
    grep -q 'Article 1 of' "$tmp/read1.out" || { echo "FAIL: N=$N: reader 1 missing"; fail=1; }
    grep -q "Article $N of $N" "$tmp/readN.out" || { echo "FAIL: N=$N: reader N missing"; fail=1; }
    printf '%-6s %10s %12s %9s %9s %9s %9s\n' "$N" "$idx" "$(( idx * 1000 / N ))" "$l1" "$lN" "$r1" "$rN"
    echo "  (news_rebuild_index: ${rebuild} ms; news_index alone: ${idx_only} ms; list pages: $pages; lines over 76 cols: $wide)"
done
(( fail == 0 )) && echo "summary: OK" || echo "summary: FAILED"
exit $fail
