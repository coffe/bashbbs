#!/bin/bash
# Tests for sbin/bbs-history-expire. Each run uses its own BBS_ROOT under the
# scratchpad and a fixed clock (BBS_NOW), so the 30-day cut-off is exact.
# Checksums of boards/, drop/ and queue/ must be the same before and after.
# Usage: tests/history_expire_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/d1734d7a-ba5d-4ad7-aeee-cb0f3089f2e5/scratchpad}
log=${1:-$scratch/history_expire_test.log}
expire=$here/sbin/bbs-history-expire
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }

NOW=1800000000
DAY=86400
OLD=$(( NOW - 31 * DAY ))      # older than 30 days
NEW=$(( NOW - 29 * DAY ))      # younger than 30 days
EDGE=$(( NOW - 30 * DAY ))     # exactly 30 days: kept (not older than the cut-off)

newroot() {
    root=$(mktemp -d "$scratch/exp.XXXXXX")
    mkdir -p "$root"/{boards/general/x,drop/news,drop/rejected,queue/incoming,state/history/general/m1,state/history/general/m2,state/admin-backup,outside}
    printf 'live post\n' > "$root/boards/general/$OLD-m1.msg"
    printf 'drop\n' > "$root/drop/news/tech-a.txt"
    printf 'queued\n' > "$root/queue/incoming/$OLD-q.req"
    printf 'v1\n' > "$root/state/history/general/m1/1-$OLD.msg"
    printf 'v2\n' > "$root/state/history/general/m1/2-$NEW.msg"
    printf 'v1\n' > "$root/state/history/general/m2/1-$EDGE.msg"
    printf 'v1\n' > "$root/state/history/general/m2/2-$OLD.msg.txt"
    printf 'backup\n' > "$root/state/admin-backup/${OLD}-general-m1.msg"
    printf 'backup\n' > "$root/state/admin-backup/${NEW}-general-m2.msg"
    printf 'backup\n' > "$root/state/admin-backup/nodate-general-m3.msg"
    printf 'outside\n' > "$root/outside/secret.msg"
    ln -s "$root/outside/secret.msg" "$root/state/history/general/m2/3-$OLD.msg"
    printf 'mail\n' > "$root/state/mod.log"
}

# sums <dir>...: one checksum line per file, sorted, for before/after comparison.
sums() { ( cd "$BBS_ROOT" && find "$@" -type f -print0 | sort -z | xargs -0 sha256sum ); }
run() { BBS_ROOT="$root" BBS_NOW=$NOW "$expire" "$@"; }

# --- dry-run changes nothing -------------------------------------------------
newroot
export BBS_ROOT=$root
sums boards drop queue state > "$scratch/exp-before.sum" 2>/dev/null
run > "$scratch/exp-dry.out" 2>>"$log"; rc=$?
check "dry-run exits 0" test "$rc" -eq 0
check "dry-run lists the old history file" grep -q "expire: history/general/m1/1-$OLD.msg" "$scratch/exp-dry.out"
check "dry-run lists the old admin backup" grep -q "expire: admin-backup/${OLD}-general-m1.msg" "$scratch/exp-dry.out"
check "dry-run does not list the 29-day file" bash -c "! grep -q '$NEW' '$scratch/exp-dry.out'"
check "dry-run does not list the 30-day edge file" bash -c "! grep -q '$EDGE' '$scratch/exp-dry.out'"
check "dry-run does not follow the symlink" bash -c "! grep -q 'secret' '$scratch/exp-dry.out'"
check "dry-run summary: 2 candidates" grep -q 'mode=dry-run .* candidates=2 ' "$scratch/exp-dry.out"
check "dry-run: file names without a clock are skipped and reported" grep -q 'skip (name does not fit): state/admin-backup/nodate' "$scratch/exp-dry.out"
check "dry-run: nothing moved" test -f "$root/state/history/general/m1/1-$OLD.msg"
check "dry-run: no expired directory" test ! -e "$root/state/expired"
sums boards drop queue state > "$scratch/exp-after.sum" 2>/dev/null
check "dry-run: checksums unchanged" cmp -s "$scratch/exp-before.sum" "$scratch/exp-after.sum"
rm -rf "$root"

# --- apply moves candidates to quarantine, keeps the rest -------------------
newroot
export BBS_ROOT=$root
sums boards drop queue > "$scratch/exp-before2.sum" 2>/dev/null
run --apply > "$scratch/exp-apply.out" 2>>"$log"; rc=$?
check "apply exits 0" test "$rc" -eq 0
Q=$(ls -d "$root"/state/expired/* 2>/dev/null | head -n 1)
check "apply: quarantine directory created" test -d "$Q"
check "apply: old history file moved, not deleted" test -f "$Q/history/general/m1/1-$OLD.msg"
check "apply: old history file gone from history" test ! -e "$root/state/history/general/m1/1-$OLD.msg"
check "apply: old admin backup moved" test -f "$Q/admin-backup/${OLD}-general-m1.msg"
check "apply: 29-day history kept" test -f "$root/state/history/general/m1/2-$NEW.msg"
check "apply: 30-day edge kept" test -f "$root/state/history/general/m2/1-$EDGE.msg"
check "apply: 29-day backup kept" test -f "$root/state/admin-backup/${NEW}-general-m2.msg"
check "apply: name without clock kept" test -f "$root/state/admin-backup/nodate-general-m3.msg"
check "apply: symlink kept in place" test -L "$root/state/history/general/m2/3-$OLD.msg"
check "apply: symlink target untouched" grep -qx 'outside' "$root/outside/secret.msg"
check "apply: mod.log untouched" grep -qx 'mail' "$root/state/mod.log"
check "apply: quarantine files keep their content" grep -qx 'v1' "$Q/history/general/m1/1-$OLD.msg"
sums boards drop queue > "$scratch/exp-after2.sum" 2>/dev/null
check "apply: boards, drop and queue checksums unchanged" cmp -s "$scratch/exp-before2.sum" "$scratch/exp-after2.sum"
# A second run finds nothing left to move.
run --apply > "$scratch/exp-apply2.out" 2>>"$log"
check "apply twice: second run has 0 candidates" grep -q 'candidates=0 ' "$scratch/exp-apply2.out"
rm -rf "$root"

# --- usage ---------------------------------------------------------------------
newroot
check "unknown option exits 2" bash -c "BBS_ROOT='$root' '$expire' --delete; test \$? -eq 2"
rm -rf "$root"

echo "history_expire_test: $pass passed, $fail failed (log: $log)" | tee -a "$log"
[[ $fail -eq 0 ]]
