#!/bin/bash
# Parity test: wrap_text (bash fast path) against lib/wrap.py, and thread_row against the
# old python-only thread_row_py. Generated inputs (ASCII, åäöÅÄÖé, long words, runs of
# spaces, empty lines, no trailing newline, empty input), widths 1..40, 76 and 80, both
# modes. Also proves that tab, emoji, combining marks and CJK still go to python.
# Usage: tests/wrap_parity_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/wrap_parity_test.log}
: > "$log"
work=$(mktemp -d "$scratch/wrapparity.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/meta" "$work/home"
export BBS_ROOT=$work/root HOME=$work/home BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-wraptest
# shellcheck source=../lib/menu.sh
source "$here/lib/menu.sh"
set +e +u +o pipefail 2>/dev/null
py=$here/lib/wrap.py

# Count calls to python3, and still run it.
PYCALLS=$work/pycalls
python3() { echo x >> "$PYCALLS"; command python3 "$@"; }
pycount() { [[ -f $PYCALLS ]] && wc -l < "$PYCALLS" || echo 0; }

command python3 - "$work/cases" <<'PYEOF'
import os, random, sys
d = sys.argv[1]; os.makedirs(d)
r = random.Random(20261105)
fixed = [
    "", "\n", "\n\n", "x", "x\n", "hello world", "hello world\n", "  lead and trail  \n",
    "a  b   c    d\n", "one\n\ntwo\n\n\nthree", "   \n  \nx\n", "a\n \nb\n",
    "Åke går över ån för att äta ärtor och öl, é è ñ ü ß", "åäöÅÄÖé " * 20,
    "x" * 100, "x" * 100 + "\n", "åäö" * 40, "short\n" + "y" * 90 + " tail words here\n",
    "word " * 60, "word " * 60 + "\n", "a" * 25 + " " + "b" * 25 + " " + "c" * 25,
    "para one line one\npara one line two\n\npara two\n", "  " * 50 + "\n", " " * 200,
    "ends with spaces   \nnext   ", "\n\nleading blank lines", "a" * 80, "a" * 81, "a" * 76 + " b",
    "Subject: Re: åäö test", "(deleted)", "ÀÖ×÷ ÿ ý þ",
]
alpha = "abcdefghijklmnopqrstuvwxyz ABCXYZ0123456789.,;:!?()-_/'\"åäöÅÄÖé"
for i in range(70):
    n = r.choice([3, 10, 40, 120, 400, 900])
    s = "".join(r.choice(alpha) if r.random() > 0.15 else r.choice(["  ", "   ", "\n", "\n\n", " "]) for _ in range(n))
    if r.random() < .5: s += "\n"
    fixed.append(s)
for i, s in enumerate(fixed):
    open("%s/%03d" % (d, i), "w", encoding="utf-8").write(s)
# Must fall back to python.
fb = {"tab": "a\tb c\n", "emoji": "hej \U0001F600 du\n", "combining": "é café ok\n",
      "cjk": "日本語 テスト wide\n", "cr": "a\r\nb\n", "badutf8": None}
os.makedirs(d + "-fb")
for k, v in fb.items():
    open("%s-fb/%s" % (d, k), "wb").write(v.encode() if v else b"ab \xc3 cd \xff ef\n")
PYEOF

total=0; bad=0
fail() { bad=$((bad + 1)); echo "MISMATCH $*" | tee -a "$log" | head -n 1; }

widths=$(seq 1 40; echo 76; echo 80)
for f in "$work"/cases/*; do
    for w in $widths; do
        for mode in "" "--keep-lines"; do
            total=$((total + 1))
            exp=$(command python3 "$py" $mode "$w" < "$f" 2>"$work/e1"; echo "rc=$?")
            got=$(wrap_text $mode "$w" < "$f" 2>"$work/e2"; echo "rc=$?")
            if [[ $exp != "$got" ]] || ! cmp -s "$work/e1" "$work/e2"; then
                fail "wrap_text $mode $w $(basename "$f")"
                { echo "--- expected"; echo "$exp"; echo "--- got"; echo "$got"; } >> "$log"
            fi
        done
    done
done
echo "wrap_text: $total comparisons" >> "$log"

# Fast path: no python call for a plain case.
: > "$PYCALLS"
wrap_text 40 < "$work/cases/005" > /dev/null; wrap_text --keep-lines 40 < "$work/cases/005" > /dev/null
total=$((total + 1)); [[ $(pycount) == 0 ]] || fail "plain text called python ($(pycount))"

# Fallback: each odd input calls python and still matches.
for f in "$work"/cases-fb/*; do
    for mode in "" "--keep-lines"; do
        total=$((total + 1)); : > "$PYCALLS"
        exp=$(command python3 "$py" $mode 30 < "$f"; echo "rc=$?")
        got=$(wrap_text $mode 30 < "$f"; echo "rc=$?")
        [[ $exp == "$got" ]] || fail "fallback output $mode $(basename "$f")"
        [[ $(pycount) == 1 ]] || fail "fallback not taken: $mode $(basename "$f") ($(pycount) calls)"
    done
done
# A NUL byte in the input.
total=$((total + 1)); : > "$PYCALLS"
exp=$(printf 'ab cd\0ef gh\n' | command python3 "$py" 20; echo "rc=$?")
got=$(printf 'ab cd\0ef gh\n' | wrap_text 20; echo "rc=$?")
[[ $exp == "$got" && $(pycount) == 1 ]] || fail "NUL byte"
# Bad arguments reach python's own errors.
for args in "abc" "" "10 20" "--keep-lines" "+20" "010"; do
    total=$((total + 1))
    exp=$(echo "a b c" | command python3 "$py" $args 2>&1; echo "rc=$?")
    got=$(echo "a b c" | wrap_text $args 2>&1; echo "rc=$?")
    [[ $exp == "$got" ]] || fail "args '$args'"
done

# thread_row: old python version against the new one.
subjects=("Hello" "" "A rather long thread subject that has to wrap over several lines, åäö" \
    "Åsa och Örjan går över ån" "x" "$(printf 'w%.0s' {1..70})" "two  spaces   here" \
    " lead" "trail " "Re: Re: Re: nested reply subject with åäö and numbers 1234567890")
suffixes=("(1)" "(12) *" "(300) *" "(0)")
for w in $(seq 5 80); do
    for s in "${subjects[@]}"; do
        for sf in "${suffixes[@]}"; do
            total=$((total + 1))
            exp=$(thread_row_py 7 "$w" "$sf" "$s"); got=$(thread_row 7 "$w" "$sf" "$s")
            if [[ $exp != "$got" ]]; then
                fail "thread_row $w '$sf' '$s'"; { echo "--- expected"; echo "$exp"; echo "--- got"; echo "$got"; } >> "$log"
            fi
        done
    done
done
# thread_row: fast for plain, python for emoji/CJK/tab/combining.
: > "$PYCALLS"; thread_row 3 76 "(2)" "Plain åäö subject" > /dev/null
total=$((total + 1)); [[ $(pycount) == 0 ]] || fail "thread_row plain called python"
for s in $'tab\there' "emoji $(printf '\xf0\x9f\x98\x80') x" "cafe$(printf '\xcc\x81') x" "$(printf '\xe6\x97\xa5\xe6\x9c\xac') wide"; do
    total=$((total + 1)); : > "$PYCALLS"
    exp=$(thread_row_py 12 40 "(5) *" "$s"); got=$(thread_row 12 40 "(5) *" "$s")
    [[ $exp == "$got" && $(pycount) == 2 ]] || fail "thread_row fallback '$s' ($(pycount) calls)"
done

echo "wrap_parity_test: $total cases, $bad mismatches"
echo "wrap_parity_test: $total cases, $bad mismatches" >> "$log"
[[ $bad == 0 ]]
