#!/bin/bash
# bbs-ctl reports: JSON shape, deleted posts skipped, newest first, escaping, no writes.
# Everything runs in a temporary BBS_ROOT with a stub for bbs-health.
# Usage: tests/ctl_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/ctl_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }
json_ok() { python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$1"; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 needed to check JSON." >&2; exit 2; }

root=$(mktemp -d "$scratch/ctl.XXXXXX")
mkdir -p "$root/boards/general" "$root/boards/whatsup" "$root/applications/incoming"

# post <board> <epoch> <id> <author> <subject> [deleted]
post() {
    {
        printf 'Msgid: %s\nAuthor: %s\nDate: 2026-11-04T10:00:00+00:00\nSubject: %s\n' "$3" "$4" "$5"
        [[ -n ${6:-} ]] && printf 'Deleted: 2026-11-04T11:00:00+00:00\n'
        printf '\nBody text %s, never shown\n' "$3"
    } > "$root/boards/$1/$2-$3.msg"
}
post general 1500000100 old bbs-bob "Old post"
post general 1500000300 new bbs-kitty 'Say "hi" \ there'
post general 1500000400 gone bbs-bob "Removed post" deleted
post whatsup 1500000200 mid bbs-alice "Middle"
printf 'name=alice\nemail=x\n' > "$root/applications/incoming/1500000050-alice.app"

# Stub health script: prints key=value lines like bbs-health does.
stub=$root/health-stub
printf '#!/bin/bash\necho "sshd=active"\necho "inlaggningar=okant"\necho "ansokare=alice"\n' > "$stub"
chmod +x "$stub"

ctl() { env BBS_ROOT="$root" BBS_HEALTH="$stub" "$here/bin/bbs-ctl" "$@"; }

snapshot() { find "$root" -type f -exec md5sum {} + | sort; }

before=$(snapshot)

out=$(ctl status); check "status: valid JSON" json_ok "$out"
check "status: stub facts appear as keys" has "$out" '"sshd":"active"'
check "status: applicant list passes through" has "$out" '"ansokare":"alice"'

out=$(ctl posts 10); check "posts: valid JSON" json_ok "$out"
check "posts: deleted post skipped" not has "$out" '"msgid":"gone"'
check "posts: body text never printed" not has "$out" "never shown"
check "posts: quotes and backslash escaped" has "$out" 'Say \"hi\" \\ there'
check "posts: newest first" bash -c '[[ $1 == *"\"msgid\":\"new\""*"\"msgid\":\"mid\""*"\"msgid\":\"old\""* ]]' _ "$out"
check "posts: board name included" has "$out" '"board":"whatsup"'

out=$(ctl posts 1); check "posts: N limits the count" bash -c '[[ $(grep -o msgid <<< "$1" | wc -l) -eq 1 ]]' _ "$out"
check "posts: N out of range is refused" has "$(ctl posts 0)" '"error"'

out=$(ctl apps); check "apps: valid JSON" json_ok "$out"
check "apps: lists the applicant" has "$out" '"name":"alice"'

out=$(ctl users); check "users: valid JSON" json_ok "$out"
check "users: unknown prefix is fine (empty or bbs- only)" bash -c 'grep -q "\"users\"" <<< "$1"' _ "$out"

out=$(ctl bogus 2>/dev/null); check "unknown subcommand prints usage to stderr, no JSON" not has "$out" '"users"'

after=$(snapshot)
check "no files written or changed" bash -c '[[ $1 == "$2" ]]' _ "$before" "$after"

echo "bbs_ctl_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
