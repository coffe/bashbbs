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

# Transfer log (tab-separated, as sbin/bbs-upload writes it) and two published files.
mkdir -p "$root/state" "$root/published"
printf '2026-11-04T09:00:00Z\tbbs-alice\tup\t1500000001-aaaaaaaa\tfirst.zip\t100\t192.0.2.1\n' > "$root/state/transfers.log"
printf '2026-11-04T09:05:00Z\tbbs-bob\tdown\t1500000001-aaaaaaaa\tfirst.zip\t100\t192.0.2.2\n' >> "$root/state/transfers.log"
printf '2026-11-04T09:10:00Z\tbbs-bob\tup\t1500000002-bbbbbbbb\tsecond "x".lha\t200\t-\n' >> "$root/state/transfers.log"
printf 'user=bbs-alice\nname=first.zip\nsize=100\nsha256=00\ndate=2026-11-04T09:00:00Z\nip=192.0.2.1\n' > "$root/published/1500000001-aaaaaaaa.meta"
printf 'user=bbs-bob\nname=second "x".lha\nsize=200\nsha256=11\ndate=2026-11-04T09:10:00Z\nip=-\n' > "$root/published/1500000002-bbbbbbbb.meta"
printf 'x' > "$root/published/1500000001-aaaaaaaa"
printf 'y' > "$root/published/1500000002-bbbbbbbb"

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

out=$(ctl transfers); check "transfers: valid JSON" json_ok "$out"
check "transfers: newest first" bash -c '[[ $1 == *"\"date\":\"2026-11-04T09:10:00Z\""*"\"date\":\"2026-11-04T09:00:00Z\""* ]]' _ "$out"
check "transfers: direction and user included" has "$out" '"user":"bbs-bob","dir":"down"'
check "transfers: IP included for the log" has "$out" '"ip":"192.0.2.1"'
check "transfers: quotes escaped in names" has "$out" 'second \"x\".lha'
check "transfers: N limits the count" bash -c '[[ $(grep -o "\"dir\"" <<< "$1" | wc -l) -eq 1 ]]' _ "$(ctl transfers 1)"
check "transfers: N out of range is refused" has "$(ctl transfers 501)" '"error"'

out=$(ctl files); check "files: valid JSON" json_ok "$out"
check "files: newest first" bash -c '[[ $1 == *"\"id\":\"1500000002-bbbbbbbb\""*"\"id\":\"1500000001-aaaaaaaa\""* ]]' _ "$out"
check "files: download count from the log" has "$out" '"id":"1500000001-aaaaaaaa","user":"bbs-alice","name":"first.zip","size":100,"date":"2026-11-04T09:00:00Z","downloads":1'
check "files: uploader and size included" has "$out" '"user":"bbs-bob","name":"second \"x\".lha","size":200'
check "files: data files and bodies never printed" not has "$out" "sha256"

out=$(ctl users); check "users: valid JSON" json_ok "$out"
check "users: unknown prefix is fine (empty or bbs- only)" bash -c 'grep -q "\"users\"" <<< "$1"' _ "$out"

out=$(ctl bogus 2>/dev/null); check "unknown subcommand prints usage to stderr, no JSON" not has "$out" '"users"'

after=$(snapshot)
check "no files written or changed" bash -c '[[ $1 == "$2" ]]' _ "$before" "$after"

echo "bbs_ctl_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
