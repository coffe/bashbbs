#!/bin/bash
# Tests for downloads (scp -f in bin/bbs-shell), the transfer log written by
# sbin/bbs-upload, and the quota check before an upload starts.
# Every run uses its own BBS_ROOT under the scratchpad; scp is a fake on PATH
# that copies its source to a file, so the real bytes are checked.
# Usage: tests/download_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/6dfc6c05-defd-490a-9754-7c823094c94c/scratchpad}
mkdir -p "$scratch"
log=${1:-$scratch/download_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
has() { grep -qF -- "$2" <<< "$1"; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/dl.XXXXXX")
mkdir -p "$root"/{home,fakebin,published,queue/transfers,queue/ip,state,incoming/alice}
chmod 1733 "$root/queue/transfers" "$root/queue/ip"

# Fake scp for both directions. "-f <path>" copies the file to $root/sent.bin
# and records the name it was given; a sink (-t) only records its arguments.
cat > "$root/fakebin/scp" <<EOF
#!/bin/bash
echo "\$*" > "$root/scp.args"
ulimit -f > "$root/scp.ulimit"
for a; do last=\$a; done
if [[ \$1 == -f || \$2 == -f ]]; then
    cp -L -- "\$last" "$root/sent.bin" || exit 1
    basename -- "\$last" > "$root/sent.name"
    exit \${FAKE_SCP_RC:-0}
fi
exit 0
EOF
chmod +x "$root/fakebin/scp"

# Publish one file the way bbs-upload does: data plus a .meta sidecar.
publish() { # publish <id> <name> <user> <content>
    printf '%s' "$4" > "$root/published/$1"
    printf 'user=%s\nname=%s\nsize=%s\nsha256=x\ndate=2026-11-04T10:00:00Z\nip=198.51.100.7\n' \
        "$3" "$2" "${#4}" > "$root/published/$1.meta"
    chmod 0644 "$root/published/$1" "$root/published/$1.meta"
}
publish 1500000000-aaaaaaaa notes.txt alice "first version"
publish 1500000100-bbbbbbbb notes.txt bob "newer version"
publish 1500000200-cccccccc pic.bin bob "binary data"

# shell_run <original command> [user] [ip]: run bbs-shell as that user.
shell_run() {
    local who=${2:-alice} ip=${3:-203.0.113.9}
    # env -i drops every variable, so the test knobs are passed on explicitly.
    out=$(env -i PATH="$root/fakebin:$PATH" HOME="$root/home" BASHBBS_TEST=1 BBS_ROOT="$root" \
        BASHBBS_TEST_ID="$who" USER=shortname SSH_CONNECTION="$ip 50000 192.0.2.1 22" \
        FAKE_SCP_RC="${FAKE_SCP_RC:-0}" UPLOAD_USER_QUOTA="${UPLOAD_USER_QUOTA:-}" \
        SSH_ORIGINAL_COMMAND="$1" bash "$here/bin/bbs-shell" 2>&1); rc=$?
}

# 1. Download: the newest file with that name is sent, byte for byte.
rm -f "$root/sent.bin" "$root/sent.name"
shell_run "scp -f notes.txt"
check "download: exit 0" eq "$rc" 0
check "download: newest version sent" eq "$(cat "$root/sent.bin" 2>/dev/null)" "newer version"
check "download: sent under the original name" eq "$(cat "$root/sent.name" 2>/dev/null)" "notes.txt"
check "download: no temporary link left behind" test -z "$(ls -A "$root/home")"
check "download: stored file untouched" eq "$(cat "$root/published/1500000100-bbbbbbbb")" "newer version"

# 2. Refusals: no such name, a path, -r, two modes, extra arguments.
for c in "scp -f nothere.txt" "scp -f ../published/1500000000-aaaaaaaa" "scp -f -r notes.txt" \
         "scp -t -f notes.txt" "scp -f notes.txt pic.bin" "scp -f .hidden"; do
    rm -f "$root/sent.bin"
    shell_run "$c"
    check "refused: $c" bash -c '[[ $1 -ne 0 && ! -e $2 ]]' _ "$rc" "$root/sent.bin"
done
check "refusal message is one line" eq "$(printf '%s\n' "$out" | wc -l)" 1

# 3. A failed send is not logged.
rm -f "$root/queue/transfers"/*
FAKE_SCP_RC=1 shell_run "scp -f pic.bin"
check "failed send returns the scp exit code" eq "$rc" 1
check "failed send writes no record" eq "$(ls -A "$root/queue/transfers" | wc -l)" 0

# 4. A successful send writes one record.
shell_run "scp -f pic.bin" carol 198.51.100.44
check "record written" eq "$(ls "$root/queue/transfers" | wc -l)" 1
rec=$(ls "$root/queue/transfers"/* 2>/dev/null | head -n 1)
check "record names user, id, size and address" bash -c \
    'grep -qx user=carol "$1" && grep -qx id=1500000200-cccccccc "$1" && grep -qx size=11 "$1" && grep -qx ip=198.51.100.44 "$1"' _ "$rec"

# 5. Upload start: the address is recorded and a full quota stops the transfer.
shell_run "scp -t incoming/x" alice 198.51.100.7
check "upload start records the address" eq "$(cat "$root/queue/ip/alice")" "198.51.100.7"
check "upload accepted under quota" eq "$rc" 0
shell_run "scp -t x" alice 198.51.100.7 && true
rm -f "$root/scp.args"
UPLOAD_USER_QUOTA=5 shell_run "scp -t x" alice 198.51.100.7
check "upload refused when over quota, no scp started" bash -c \
    '[[ $1 -ne 0 && ! -e $2 && $3 == *"quota"* ]]' _ "$rc" "$root/scp.args" "$out"

# 6. bbs-upload turns the record and an accepted upload into log lines.
printf 'hello\n' > "$root/incoming/alice/hi.txt"
touch -d '10 minutes ago' "$root/incoming/alice/hi.txt"
env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_UPLOAD_TEST_OWNER=carol bash "$here/sbin/bbs-upload" >>"$log" 2>&1
check "log: upload line with the address" bash -c \
    'awk -F"\t" "\$3==\"up\" && \$5==\"hi.txt\" && \$7==\"198.51.100.7\"" "$1" | grep -q .' _ "$root/state/transfers.log"
check "log: download line with the user and address" bash -c \
    'awk -F"\t" "\$2==\"carol\" && \$3==\"down\" && \$4==\"1500000200-cccccccc\" && \$7==\"198.51.100.44\"" "$1" | grep -q .' _ "$root/state/transfers.log"
check "log: download records consumed" eq "$(ls -A "$root/queue/transfers" | wc -l)" 0

# 7. A record with bad content is dropped, not logged.
printf 'user=../x\nid=1-2\nsize=abc\n' > "$root/queue/transfers/bad-record"
env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 bash "$here/sbin/bbs-upload" >>"$log" 2>&1
check "bad record: not logged" bash -c '! grep -q "\.\./x" "$1"' _ "$root/state/transfers.log"
check "bad record: removed" test ! -e "$root/queue/transfers/bad-record"

echo "download_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
