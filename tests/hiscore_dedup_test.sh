#!/bin/bash
# bbs-hiscore-dedup keeps only each player's best dopewars score, in place.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool=$here/../sbin/bbs-hiscore-dedup
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "  got:  $2"; echo "  want: $3"; fi; }

# Write a score file the way dopewars does: header, antique table, normal table.
mkfile() {  # mkfile FILE "name:date:money:dead" ... (normal table; antique stays empty)
    python3 - "$@" <<'EOF'
import sys
path, entries = sys.argv[1], sys.argv[2:]
out = bytearray(b"DOPEWARS SCORES V.1\0") + b"\0\0\0\0" * 18
for i in range(18):
    if i < len(entries):
        n, d, m, dead = entries[i].split(":")
        out += n.encode() + b"\0" + d.encode() + b"\0" + m.encode() + b"\0" + bytes([int(dead)])
    else:
        out += b"\0\0\0\0"
open(path, "wb").write(out)
EOF
}
# List the normal table as name:money lines.
names() {
    python3 - "$1" <<'EOF'
import sys
import importlib.machinery, importlib.util, os
loader = importlib.machinery.SourceFileLoader("d", os.environ["TOOL"])
spec = importlib.util.spec_from_loader("d", loader); d = importlib.util.module_from_spec(spec); loader.exec_module(d)
t = d.parse(open(sys.argv[1], "rb").read())
print(" ".join(f"{e[0].decode()}:{e[2].decode()}" for e in t[1] if e[0] or e[1]))
EOF
}
export TOOL=$tool

f=$out/a.sco
mkfile "$f" "neo:01-11-2026:900000:0" "tr1n1t4s:02-11-2026:500000:0" "neo:03-11-2026:400000:1" "Tr1n1t4s :04-11-2026:100:0" "morph:05-11-2026:-200:1"
ino=$(stat -c %i "$f")
"$tool" "$f" >/dev/null
check "keeps the best line per name, case and spaces ignored" "$(names "$f")" "neo:900000 tr1n1t4s:500000 morph:-200"
check "rewritten in place (the server keeps the file open)" "$(stat -c %i "$f")" "$ino"
mkfile "$out/ref.sco" "neo:01-11-2026:900000:0" "tr1n1t4s:02-11-2026:500000:0" "morph:05-11-2026:-200:1"
check "same bytes as a table that never had duplicates" "$(cmp -s "$f" "$out/ref.sco" && echo same)" "same"

before=$(stat -c %Y.%y "$f")
cp "$f" "$out/copy.sco"
"$tool" "$f" >/dev/null
check "a clean file is not written again" "$(cmp -s "$f" "$out/copy.sco" && echo same) $(stat -c %Y.%y "$f")" "same $before"

printf 'DOPEWARS SCORES V.1\0' > "$out/empty.sco"
"$tool" "$out/empty.sco"; check "header-only file is fine" "$?:$(stat -c %s "$out/empty.sco")" "0:20"

printf 'something else\0' > "$out/odd.sco"
"$tool" "$out/odd.sco" 2>/dev/null; check "an unknown file is left alone and reported" "$?:$(cat "$out/odd.sco" | tr -d '\0')" "1:something else"

"$tool" "$out/missing.sco"; check "a missing file is not an error" "$?" "0"

echo "$pass passed, $fail failed"
(( fail == 0 ))
