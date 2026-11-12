#!/usr/bin/env bash
# Short news links: web/n.cgi in a throwaway BBS_ROOT.
# Usage: tests/news_link_cgi_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
base=${SCRATCH:-${TMPDIR:-/tmp}}
root=$(mktemp -d "$base/news-link-cgi.XXXXXX")
log=${1:-/dev/null}
out=$root/.out
pass=0 fail=0
quar=$base/karantan-news-link-tests; mkdir -p "$quar"  # no deletes: test dirs go to quarantine
trap 'mv "$root" "$quar"/ 2>/dev/null' EXIT

check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d"; fi; }
eq() { [[ $1 == "$2" ]] || { echo "got '$1', wanted '$2'"; return 1; }; }

cgi() { # cgi <path info> [method]
    env BASHBBS_TEST=1 BBS_ROOT="$root" REQUEST_METHOD="${2:-GET}" PATH_INFO="/$1" \
        python3 "$here/web/n.cgi" > "$out" 2>>"$root/.err"
}
status() { sed -n '1s/^Status: \([0-9]*\).*/\1/p' "$out" | tr -d '\r'; }
location() { sed -n 's/^Location: //p' "$out" | tr -d '\r'; }

news=$root/boards/news/ai
mkdir -p "$news" "$root/state"
art() { # art <file> <article id> <link>
    printf 'Board: news\nSubject: T\nArticle-Id: %s\nLink: %s\n\nBody\n' "$2" "$3" > "$news/$1"
    printf '%s\tai\t1\tT\t%s\t2026-11-12\tWire\tLede\n' "$2" "$news/$1" >> "$root/state/news-index.tsv"
}
A=aaaa1111$(printf '%056d' 0) B=bbbb2222$(printf '%056d' 0)
art a.msg "$A" "https://example.org/a?x=1&y=2"
art b.msg "$B" "javascript:alert(1)"
art c1.msg cccc3333"$(printf '%056d' 1)" https://example.org/c1
art c2.msg cccc3333"$(printf '%056d' 2)" https://example.org/c2
ln -s "$news/a.msg" "$news/link.msg"
printf '%s\tai\t1\tT\t%s\t-\t-\t-\n' dddd4444"$(printf '%056d' 0)" "$news/link.msg" >> "$root/state/news-index.tsv"
printf 'Link: https://evil.example/\n\n' > "$root/elsewhere.msg"
printf '%s\tai\t1\tT\t%s\t-\t-\t-\n' eeee5555"$(printf '%056d' 0)" "$root/elsewhere.msg" >> "$root/state/news-index.tsv"
printf '%s\tai\t1\tT\t%s\t-\t-\t-\n' ffff6666"$(printf '%056d' 0)" "$news/../../../elsewhere.msg" >> "$root/state/news-index.tsv"

cgi aaaa1111
check "8-hex prefix: 302" eq "$(status)" 302
check "8-hex prefix: Location is the article link" eq "$(location)" "https://example.org/a?x=1&y=2"
cgi "$A";        check "full id: 302" eq "$(status)" 302
cgi "$A" HEAD;   check "HEAD: 302" eq "$(status)" 302
cgi aaaa111;     check "7 hex: 404" eq "$(status)" 404
cgi AAAA1111;    check "upper case: 404" eq "$(status)" 404
cgi 'aaaa1111/x'; check "extra path: 404" eq "$(status)" 404
cgi 99999999;    check "unknown id: 404" eq "$(status)" 404
cgi bbbb2222;    check "bad link scheme: 404" eq "$(status)" 404
cgi cccc3333;    check "ambiguous prefix: 404" eq "$(status)" 404
cgi cccc3333"$(printf '%056d' 2)"; check "ambiguous prefix, full id: 302" eq "$(location)" https://example.org/c2
cgi dddd4444;    check "symlinked article: 404" eq "$(status)" 404
cgi eeee5555;    check "path outside boards/news: 404" eq "$(status)" 404
cgi ffff6666;    check "path with ..: 404" eq "$(status)" 404
cgi aaaa1111 POST; check "POST: 405" eq "$(status)" 405
mv "$root/state/news-index.tsv" "$root/state/gone.tsv"
cgi aaaa1111;    check "no index: 404" eq "$(status)" 404
check "nothing on stderr" eq "$(cat "$root/.err")" ""

echo "news_link_cgi_test: $pass pass, $fail fail"
(( fail == 0 ))
