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

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
