#!/bin/bash
# Tests for file uploads: the scp sink branch of bin/bbs-shell and sbin/bbs-upload.
# Downloads (scp -f) are in tests/download_test.sh.
# Every run uses its own BBS_ROOT under the scratchpad; scp is a fake on PATH.
# Usage: tests/upload_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/0076a324-510e-43ae-9c07-4167c790da85/scratchpad}
mkdir -p "$scratch"
log=${1:-$scratch/upload_test.log}
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }
not_grep() { ! grep -q -- "$1" "$2"; }

root=$(mktemp -d "$scratch/upload.XXXXXX")
mkdir -p "$root/incoming/alice" "$root/fakebin"
# Fake scp: records its arguments and the file-size ulimit.
cat > "$root/fakebin/scp" <<EOF
#!/bin/bash
echo "\$*" > "$root/scp.args"
ulimit -f > "$root/scp.ulimit"
target=\${*: -1}
[[ -e $root/scp.send ]] && printf 'data' > "\$target/sent.dat"
[[ -e $root/scp.xfsz ]] && kill -XFSZ \$\$
exit \$(cat "$root/scp.rc" 2>/dev/null || echo 0)
EOF
chmod +x "$root/fakebin/scp"

# shell_run <original command>: run bbs-shell as alice; sets out and rc.
shell_run() {
    out=$(env -i PATH="$root/fakebin:$PATH" BASHBBS_TEST=1 BBS_ROOT="$root" BASHBBS_TEST_ID=alice USER=ali \
        SSH_ORIGINAL_COMMAND="$1" bash "$here/bin/bbs-shell" 2>&1); rc=$?
}

rm -f "$root/scp.args"
shell_run "scp -t /etc/evil"
check "sink request accepted" eq "$rc" 0
check "client path ignored, staging in the inbox of the account, not the login name" bash -c '[[ $1 == "-t $2/incoming/alice/.staging-"* ]]' _ "$(cat "$root/scp.args")" "$root"
check "staging directory gone after a finished transfer" eq "$(ls -A "$root/incoming/alice" | wc -l)" 0
check "ulimit -f one block above 10 MB" eq "$(cat "$root/scp.ulimit")" 10241
rm -f "$root/scp.args"
shell_run "scp -p -v -t -- ../../x"
check "-p -v -t -- accepted" bash -c '[[ $1 == "-t $2/incoming/alice/.staging-"* ]]' _ "$(cat "$root/scp.args")" "$root"

for c in "scp -r -t /x" "scp -t -r ." "ls -l" "scp" "cat /etc/passwd; scp -t ." "sh -c id"; do
    rm -f "$root/scp.args"
    shell_run "$c"
    check "rejected: $c" bash -c '[[ $1 -ne 0 && ! -e $2 && $3 == *"scp -O"* ]]' _ "$rc" "$root/scp.args" "$out"
done
check "rejected command: exactly one line" eq "$(printf '%s\n' "$out" | wc -l)" 1

# --- bbs-upload ---
up() { env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 UPLOAD_IDLE_SECS=60 "$@" bash "$here/sbin/bbs-upload" >>"$log" 2>&1; }
old() { touch -d '10 minutes ago' "$1"; }
inbox=$root/incoming/alice

printf 'hello\n' > "$inbox/good.txt"; old "$inbox/good.txt"
up
meta=$(ls "$root"/published/*.meta 2>/dev/null | head -n 1)
check "ok file moved to published" test -n "$meta" -a ! -e "$inbox/good.txt"
check "meta user"   grep -qx 'user=alice' "$meta"
check "meta name"   grep -qx 'name=good.txt' "$meta"
check "meta size"   grep -qx 'size=6' "$meta"
check "meta sha256" grep -qx "sha256=$(printf 'hello\n' | sha256sum | cut -d' ' -f1)" "$meta"
check "published mode 0644" eq "$(stat -c %a "${meta%.meta}")" 644

: > "$inbox/zero.txt"; old "$inbox/zero.txt"
printf x > "$inbox/.hidden"; old "$inbox/.hidden"
head -c 2000 /dev/zero | tr '\0' a > "$inbox/big.bin"; old "$inbox/big.bin"
printf x > "$inbox/$(printf 'ctl\001name')"; old "$inbox/$(printf 'ctl\001name')"
longname=$(printf 'n%.0s' $(seq 1 101)); printf x > "$inbox/$longname"; old "$inbox/$longname"
up UPLOAD_MAX_BYTES=1000
check "inbox empty after rejects" eq "$(ls -A "$inbox" | wc -l)" 0
check "5 files rejected" eq "$(ls "$root/incoming/rejected" | wc -l)" 5
check "only good one published" eq "$(ls "$root"/published/*.meta | wc -l)" 1

# Quota: per user (already 6 bytes used).
printf 'abcdefghij' > "$inbox/q.txt"; old "$inbox/q.txt"
up UPLOAD_USER_QUOTA=10
check "user quota -> rejected" test ! -e "$inbox/q.txt" -a "$(ls "$root/incoming/rejected" | wc -l)" -eq 6
# Global quota
printf 'abcdefghij' > "$inbox/g.txt"; old "$inbox/g.txt"
up UPLOAD_GLOBAL_QUOTA=10
check "global quota -> rejected" test ! -e "$inbox/g.txt" -a "$(ls "$root/incoming/rejected" | wc -l)" -eq 7
check "still one published" eq "$(ls "$root"/published/*.meta | wc -l)" 1

# A file in the inbox is complete, so it is published however new it is.
printf 'fresh' > "$inbox/fresh.txt"
up
check "new file in the inbox is published" test ! -e "$inbox/fresh.txt"
check "two published" eq "$(ls "$root"/published/*.meta | wc -l)" 2

# Staging, through bbs-shell with a scp that really leaves a file.
touch "$root/scp.send"
shell_run "scp -t ."
check "finished transfer: exit 0" eq "$rc" 0
check "finished transfer: file in the inbox" test -f "$inbox/sent.dat"
check "finished transfer: no staging directory left" eq "$(find "$inbox" -name '.staging-*' | wc -l)" 0
up
check "finished transfer: published" test ! -e "$inbox/sent.dat"
check "three published" eq "$(ls "$root"/published/*.meta | wc -l)" 3

rej=$(ls "$root/incoming/rejected" | wc -l)
echo 1 > "$root/scp.rc"
shell_run "scp -t ."
rm -f "$root/scp.rc"
stage=$(find "$inbox" -mindepth 1 -maxdepth 1 -name '.staging-*')
check "cut-off transfer: exit code passed on" eq "$rc" 1
check "cut-off transfer: user is told" bash -c '[[ $1 == *"Nothing was saved"* ]]' _ "$out"
check "cut-off transfer: file not in the inbox" test ! -e "$inbox/sent.dat"
check "cut-off transfer: file stays in staging" test -f "$stage/sent.dat"
up
check "abandoned staging: left alone while recent" test -f "$stage/sent.dat"
touch -d '10 minutes ago' "$stage"
( exec 8<"$stage"; flock -n 8; touch "$root/held"; sleep 5 ) &
holder=$!
until [[ -e $root/held ]]; do sleep 0.1; done
up
check "locked staging: left alone however old" test -f "$stage/sent.dat"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
up
check "abandoned staging: file rejected" eq "$(ls "$root/incoming/rejected" | wc -l)" "$((rej + 1))"
check "abandoned staging: directory gone" test ! -e "$stage"
check "abandoned staging: reason in the log" grep -q "rejected 'sent.dat' from alice: upload did not finish (4 bytes)" "$log"
check "abandoned staging: not published" eq "$(ls "$root"/published/*.meta | wc -l)" 3

# Over the file size limit: the kernel kills scp, and bash reports it unless told not to.
touch "$root/scp.xfsz"
shell_run "scp -t ."
rm -f "$root/scp.xfsz"
check "over-size transfer: exit code passed on" eq "$rc" 153
check "over-size transfer: user is told the limit" bash -c '[[ $1 == *"Files can be up to 10 MB"* ]]' _ "$out"
check "over-size transfer: no script path in the message" bash -c '[[ $1 != *bbs-shell* && $1 != *"size limit exceeded"* ]]' _ "$out"
stage=$(find "$inbox" -mindepth 1 -maxdepth 1 -name '.staging-*')
touch -d '10 minutes ago' "$stage"
up
check "over-size transfer: staging cleared" test ! -e "$stage"

rej=$(ls "$root/incoming/rejected" | wc -l)
printf x > "$inbox/.staging-file"
up
check "regular file with a staging name: rejected as a dot name" eq "$(ls "$root/incoming/rejected" | wc -l)" "$((rej + 1))"

# --- FILE_ID.DIZ, read without unpacking anything ---
mkzip() { # mkzip <file> <entry name> <text, printf style>; no entry name: an empty zip
    python3 -I - "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("readme.txt", "hello " + sys.argv[1])
    if sys.argv[2]:
        z.writestr(sys.argv[2], sys.argv[3].encode("utf-8").decode("unicode_escape").encode("latin-1"))
EOF
}
meta_of() { grep -lx "name=$1" "$root"/published/*.meta | head -n 1; }
mkzip "$inbox/diz.zip" file_id.DIZ 'First line\r\n\x1b[31mRed\x1b[0m line\r\nsize=999\r\n'
up
m=$(meta_of diz.zip)
check "diz: zip accepted" test -n "$m"
check "diz: first line" grep -qx 'desc=First line' "$m"
check "diz: ANSI gone" grep -qx 'desc=Red line' "$m"
check "diz: cannot pass for a size line" grep -qx 'desc=size=999' "$m"
check "diz: the real size stays first" bash -c '[[ $(sed -n "s/^size=//p" "$1" | head -n 1) != 999 && $(grep -c "^size=" "$1") == 1 ]]' _ "$m"
mkzip "$inbox/nodiz.zip" ""
up
m=$(meta_of nodiz.zip)
check "diz: zip without one is accepted" test -n "$m"
check "diz: zip without one has no description" not_grep '^desc=' "$m"
mkzip "$inbox/deep.zip" sub/FILE_ID.DIZ 'not in the root'
up
check "diz: not from a sub directory" not_grep '^desc=' "$(meta_of deep.zip)"
python3 -I - "$inbox/long.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("FILE_ID.DIZ", "\n".join("line %d" % i for i in range(5000)))
EOF
up
m=$(meta_of long.zip)
check "diz: at most 10 lines" eq "$(grep -c '^desc=' "$m")" 10
python3 -I - "$inbox/wide.zip" <<'EOT'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("FILE_ID.DIZ", "x" * 900)
EOT
up
check "diz: at most 60 wide" eq "$(sed -n 's/^desc=//p' "$(meta_of wide.zip)" | awk '{ print length }' | sort -n | tail -n 1)" 60
printf 'this is no archive' > "$inbox/junk.zip"
up
check "diz: broken zip rejected" test -z "$(meta_of junk.zip)"
check "diz: broken zip, reason in the journal" grep -q "rejected 'junk.zip' from alice: archive cannot be read" "$log"
printf 'plain text' > "$inbox/plain.txt"
up
check "diz: other files are not looked into" test -n "$(meta_of plain.txt)"
if command -v lha >/dev/null; then
    printf 'this is no lha' > "$inbox/junk.lha"
    up
    check "diz: broken lha rejected" test -z "$(meta_of junk.lha)"
else
    # Without the tool nothing is known about the file, and it is not held against it.
    printf 'this is no lha' > "$inbox/nolha.LHA"
    up
    check "diz: no lha tool, the file still goes up" test -n "$(meta_of nolha.LHA)"
    check "diz: no lha tool, the journal says so" grep -q "could not look inside 'nolha.LHA'" "$log"
fi

# The result line tells the session whether the archive opened.
T=ABCDEFGHIJKLMNOPQRSTUV
mkdir -p "$root/queue/xfer" "$root/webup/$T"
: > "$root/queue/xfer/$T"
mkzip "$root/webup/$T/up1.zip" FILE_ID.DIZ 'From the link'
mkzip "$root/webup/$T/up2.zip" ""
printf 'just text' > "$root/webup/$T/up3.txt"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
r=$root/state/xfer-results/$T
check "result: zip with a description" grep -qP '^ok\tup1\.zip\t[0-9]+-[0-9a-f]{8}\tarchive\+diz$' "$r"
check "result: zip without one" grep -qP '^ok\tup2\.zip\t[0-9]+-[0-9a-f]{8}\tarchive$' "$r"
check "result: no note on other files" grep -qP '^ok\tup3\.txt\t[0-9]+-[0-9a-f]{8}$' "$r"

# The last file lands while the sorter works on the one before: done waits for it.
L=ABCDEFGHIJKLMNOPQRSTUW
mkdir -p "$root/webup/$L" "$root/.stub"
: > "$root/queue/xfer/$L"
printf 'first\n' > "$root/webup/$L/early.txt"
cat > "$root/.stub/sha256sum" <<EOF
#!/bin/bash
if [[ ! -e "$root/.stub/fired" ]]; then
    : > "$root/.stub/fired"
    printf 'last\n' > "$root/webup/$L/late.txt"
    : > "$root/webup/$L/.done"
fi
exec /usr/bin/sha256sum "\$@"
EOF
chmod +x "$root/.stub/sha256sum"
r=$root/state/xfer-results/$L
up BBS_UPLOAD_TEST_OWNER=bbs-alice PATH="$root/.stub:$PATH"
check "late file: no done before its result" not_grep '^done$' "$r"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "late file: gets its result" grep -qP '^ok\tlate\.txt\t' "$r"
check "late file: done comes last" eq "$(tail -n 1 "$r")" done
check "late file: done once" eq "$(grep -c '^done$' "$r")" 1

# --- description requests ---
mkdir -p "$root/queue/filedesc"
D=1500000900-dddddddd
printf 'data' > "$root/published/$D"
printf 'user=bbs-alice\nname=d.lha\nsize=4\nsha256=0\ndate=2026-11-04T09:00:00Z\nip=-\ndesc=old\n' > "$root/published/$D.meta"
dm=$root/published/$D.meta
req=$root/queue/filedesc/$D.desc
printf 'New text\nsize=7\nline three\nline four\n' > "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "desc: uploader may change it" grep -qx 'desc=New text' "$dm"
check "desc: the old one is gone" not_grep '^desc=old$' "$dm"
check "desc: at most 3 lines" eq "$(grep -c '^desc=' "$dm")" 3
check "desc: no new size line" eq "$(grep -c '^size=' "$dm")" 1
check "desc: request gone" test ! -e "$req"
check "desc: meta mode" eq "$(stat -c %a "$dm")" 644
printf 'Sneaky' > "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-mallory
check "desc: someone else may not" not_grep '^desc=Sneaky$' "$dm"
check "desc: refused request gone" test ! -e "$req"
printf 'mallory\n' > "$root/sysops"
printf 'From sysop' > "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-mallory
check "desc: a sysop may" grep -qx 'desc=From sysop' "$dm"
mv "$root/sysops" "$root/sysops.off"
printf 'top secret\n' > "$root/secret"
ln -s "$root/secret" "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "desc: a link is not followed" not_grep 'top secret' "$dm"
check "desc: link gone" test ! -L "$req"
mkfifo "$req"
timeout 20 env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_UPLOAD_TEST_OWNER=bbs-alice bash "$here/sbin/bbs-upload" >>"$log" 2>&1; rc=$?
check "desc: a pipe does not hold up the sorter" eq "$rc" 0
check "desc: pipe gone" test ! -e "$req"
printf 'bad' > "$root/queue/filedesc/..evil.desc"
printf 'bad' > "$root/queue/filedesc/1500000901-00000000.desc"
printf 'being written' > "$root/queue/filedesc/.tmp.fresh"
printf 'left behind' > "$root/queue/filedesc/.tmp.stale"
touch -d '2 hours ago' "$root/queue/filedesc/.tmp.stale"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "desc: odd name dropped" test ! -e "$root/queue/filedesc/..evil.desc"
check "desc: missing file dropped" test ! -e "$root/queue/filedesc/1500000901-00000000.desc"
check "desc: a file being written is left alone" test -e "$root/queue/filedesc/.tmp.fresh"
check "desc: a file left behind goes" test ! -e "$root/queue/filedesc/.tmp.stale"
rm -f "$root/queue/filedesc/.tmp.fresh"
printf '\033[31mColour\033[0m \xe2\x80\xaeflipped\xc2\x85\n' > "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "desc: ANSI and hidden characters cleaned" grep -qx 'desc=Colour flipped' "$dm"
: > "$req"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "desc: empty text removes it" not_grep '^desc=' "$dm"
check "desc: the rest of the meta stays" grep -qx 'name=d.lha' "$dm"

# --- file areas ---
area_of() { sed -n 's/^area=//p' "$1"; }
printf 'no area file' > "$inbox/noareas.txt"
up
check "area: no list, the one area" eq "$(area_of "$(meta_of noareas.txt)")" general
mkdir -p "$root/etc" "$root/queue/filearea"
printf '# comment\nmisc|Misc|Default\ndemos|Demos|Demo text\nmusic|Music|Tunes\n' > "$root/etc/file-areas"
printf 'plain upload' > "$inbox/scp.txt"
up
check "area: scp goes to the first area" eq "$(area_of "$(meta_of scp.txt)")" misc
check "area: only one line" eq "$(grep -c '^area=' "$(meta_of scp.txt)")" 1
webup_area() { # webup_area <ticket body> <file name>: one file through a link
    mkdir -p "$root/webup/$T"
    printf '%b' "$1" > "$root/queue/xfer/$T"
    printf 'from the link: %s' "$2" > "$root/webup/$T/$2"
    up BBS_UPLOAD_TEST_OWNER=bbs-alice
}
webup_area 'dir=up\narea=demos\n' w1.txt
check "area: the ticket's area" eq "$(area_of "$(meta_of w1.txt)")" demos
webup_area 'dir=up\n' w2.txt
check "area: ticket without one" eq "$(area_of "$(meta_of w2.txt)")" misc
webup_area 'dir=up\narea=nosuch\n' w3.txt
check "area: unknown in the ticket" eq "$(area_of "$(meta_of w3.txt)")" misc
webup_area 'dir=up\narea=demos\\nsize=9\n' w4.txt
check "area: odd text in the ticket" eq "$(area_of "$(meta_of w4.txt)")" misc
check "area: no extra size line" eq "$(grep -c '^size=' "$(meta_of w4.txt)")" 1
webup_area 'dir=up\narea=../../etc\n' w5.txt
check "area: a path in the ticket" eq "$(area_of "$(meta_of w5.txt)")" misc
printf 'after a link' > "$inbox/after.txt"
up
check "area: the ticket's area is not kept for the next file" eq "$(area_of "$(meta_of after.txt)")" misc

A=$(basename "$(meta_of w1.txt)" .meta)
am=$root/published/$A.meta
areq=$root/queue/filearea/$A.area
printf 'music' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "move: the uploader may" eq "$(area_of "$am")" music
check "move: one line" eq "$(grep -c '^area=' "$am")" 1
check "move: request gone" test ! -e "$areq"
check "move: the rest stays" grep -qx 'name=w1.txt' "$am"
check "move: meta mode" eq "$(stat -c %a "$am")" 644
check "move: said in the journal" grep -q "bbs-alice moved $A to the area music" "$log"
printf 'demos' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-mallory
check "move: someone else may not" eq "$(area_of "$am")" music
check "move: refused request gone" test ! -e "$areq"
printf 'mallory\n' > "$root/sysops"
printf 'demos\n' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-mallory
check "move: a sysop may" eq "$(area_of "$am")" demos
rm -f "$root/sysops"
printf 'nosuch' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "move: unknown area, stays" eq "$(area_of "$am")" demos
check "move: unknown request gone" test ! -e "$areq"
printf 'music\nsize=999\ndesc=sneaky\n' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "move: only the first line counts" eq "$(area_of "$am")" music
check "move: no injected size" eq "$(grep -c '^size=' "$am")" 1
check "move: no injected description" not_grep '^desc=sneaky' "$am"
printf 'demos\n' > "$root/secret"
ln -s "$root/secret" "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "move: a link is not followed" eq "$(area_of "$am")" music
check "move: link gone" test ! -L "$areq"
mkfifo "$areq"
timeout 20 env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_UPLOAD_TEST_OWNER=bbs-alice bash "$here/sbin/bbs-upload" >>"$log" 2>&1; rc=$?
check "move: a pipe does not hold up the sorter" eq "$rc" 0
check "move: pipe gone" test ! -e "$areq"
printf 'being written' > "$root/queue/filearea/.tmp.fresh"
printf 'bad' > "$root/queue/filearea/..evil.area"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "move: a file being written is left alone" test -e "$root/queue/filearea/.tmp.fresh"
check "move: odd name dropped" test ! -e "$root/queue/filearea/..evil.area"
rm -f "$root/queue/filearea/.tmp.fresh"
# Taking an area away changes no file, and it can come back.
printf 'misc|Misc|Default\ndemos|Demos|Demo text\n' > "$root/etc/file-areas"
before=$(cat "$am")
up
check "area removed: the .meta is not rewritten" eq "$(cat "$am")" "$before"
printf 'music' > "$areq"
up BBS_UPLOAD_TEST_OWNER=bbs-alice
check "area removed: nothing moves there" eq "$(area_of "$am")" music
check "area removed: request gone" test ! -e "$areq"

# A callers export: its snapshot and sent marker stay while fresh, go when old.
X=EXPORTabcdefghijklmnop
mkdir -p "$root/queue/xfer"
: > "$root/queue/xfer/$X"; : > "$root/queue/xfer/$X.snap"; : > "$root/queue/xfer/$X.sent"
: > "$root/queue/xfer/$X.other"
up
check "export: fresh snapshot kept" test -e "$root/queue/xfer/$X.snap"
check "export: fresh sent marker kept" test -e "$root/queue/xfer/$X.sent"
check "export: other names still removed" test ! -e "$root/queue/xfer/$X.other"
up XFER_KEEP_SECS=0
check "export: old snapshot removed" test ! -e "$root/queue/xfer/$X.snap"
check "export: old sent marker removed" test ! -e "$root/queue/xfer/$X.sent"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
