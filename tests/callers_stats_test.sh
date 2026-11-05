#!/bin/bash
# Who's Online (Fame & Glory 7), caller statistics and the callers.log export (sysop menu
# 8 and 9), and the export path of web/x.cgi. Temporary BBS_ROOT; a stub `who` first in
# PATH; TZ=Europe/Stockholm so the daylight saving handling is exercised.
# Usage: tests/callers_stats_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/callers_stats_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }
eq() { [[ $1 == "$2" ]]; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/callstats.XXXXXX")
mkdir -p "$root"/{state,queue/xfer,users/sys0p,users/alice,users/carolina,users/ghost,home,bin}
printf 'sys0p\n' > "$root/sysops"
for u in sys0p alice carolina ghost; do printf 'name=%s\n' "$u" > "$root/users/$u/profile"; done
printf 'hidden=yes\n' >> "$root/users/ghost/profile"
cat > "$root/state/callers.log" <<'LOG'
2026-07-01T21:30Z carolina
2026-07-01T22:30Z carolina
2026-11-02T08:30Z alice
2026-11-02T23:30Z alice
2026-11-03T12:00Z bbbob
LOG
# utmp-style output: carolina is cut to 8 characters, alice has two sessions.
cat > "$root/bin/who" <<'EOF2'
#!/bin/bash
cat <<'W'
alice    pts/0        2026-11-05 10:12 00:03       111 (192.0.2.1)
bbs-alic pts/1        2026-11-05 09:40   .         222 (192.0.2.1)
bbs-alic pts/2        2026-11-05 10:30 old         333 (192.0.2.1)
bbs-caro pts/3        2026-11-05 08:05 01:20       444 (192.0.2.2)
bbs-ghos pts/4        2026-11-05 08:06   .         555 (192.0.2.3)
bbs-sys0 pts/5        2026-11-05 11:00 00:10       666 (192.0.2.4)
W
EOF2
chmod +x "$root/bin/who"

run_as() { local who=$1; shift
    ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=$who TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=100 TZ=Europe/Stockholm PATH="$root/bin:$PATH"
      source "$here/lib/menu.sh"; "$@" ); }
alice() { run_as bbs-alice "$@"; }
sys() { run_as bbs-sys0p "$@"; }

# 1. Who's Online
out=$(printf '7q q' | alice fame_menu 2>&1)
check "fame menu lists Who's Online as 7" has "$out" "7) Who's Online"
check "online: alice shown once with count" has "$out" "alice"
check "online: alice has x2" has "$out" "x2"
check "online: alice since earliest session 09:40" bash -c '[[ $1 == *alice*09:40* ]]' _ "$out"
check "online: cut name carolina mapped back" has "$out" "carolina"
check "online: carolina idle 1h20m" has "$out" "1h20m"
check "online: hidden ghost left out" not has "$out" "ghost"
check "online: sysop shown" has "$out" "sys0p"
check "online: no non-bbs login (plain 'alice' pts/0 line is not counted)" bash -c '[[ $(grep -c "^alice" <<< "$1") == 1 ]]' _ "$out"
check "online: keys 1-6 still work" has "$(printf '2q q' | alice fame_menu 2>&1)" "Last callers"
check "online: lines fit 76 columns" bash -c '! awk "length(\$0) > 76 { bad = 1 } END { exit !bad }" <<< "$1"' _ "$out"

# 2. Stats: visible to sysops only
out=$(printf '8 q q' | sys sysop_menu 2>&1)
check "sysop menu shows Caller stats" has "$out" "8) Caller stats"
check "sysop menu shows Export callers" has "$out" "9) Export callers"
out=$(printf '8 q q q' | alice sysop_menu 2>&1)
check "non-sysop: no sysop menu" not has "$out" "Caller stats"
out=$(printf 'x' | alice sysop_callers_export 2>&1)
check "non-sysop: export function refuses" not has "$out" "x.cgi"
out=$(printf ' q' | sys sysop_callers_stats 2>&1)
check "stats: range in local time" has "$out" "2026-07-01 to 2026-11-03"
check "stats: 5 calls 3 callers" has "$out" "5 calls, 3 callers"
check "stats: top user carolina 2" bash -c '[[ $1 =~ carolina\ +2 ]]' _ "$out"
check "stats: alice 2" bash -c '[[ $1 =~ alice\ +2 ]]' _ "$out"
check "stats: Tue 2 (alice after midnight CET, bbbob)" bash -c '[[ $1 =~ Tue\ +2 ]]' _ "$out"
check "stats: Thu 1 (carolina 00:30 CEST in July)" bash -c '[[ $1 =~ Thu\ +1 ]]' _ "$out"
check "stats: Wed 1 (carolina 23:30 CEST)" bash -c '[[ $1 =~ Wed\ +1 ]]' _ "$out"
check "stats: Mon 1" bash -c '[[ $1 =~ Mon\ +1 ]]' _ "$out"
check "stats: bars drawn" has "$out" "#"
out=$(printf '  ' | sys sysop_callers_stats 2>&1)
check "stats: hour 00 has 2 (CET 00:30 and CEST 00:30)" bash -c '[[ $1 =~ 00:00\ +2 ]]' _ "$out"
check "stats: hour 09 has 1" bash -c '[[ $1 =~ 09:00\ +1 ]]' _ "$out"
check "stats: hour 23 has 1" bash -c '[[ $1 =~ 23:00\ +1 ]]' _ "$out"
check "stats: new callers week of 2026-11-02 is 2" bash -c '[[ $1 =~ 2026-11-02\ +2 ]]' _ "$out"
check "stats: new callers week of 2026-06-29 is 1" bash -c '[[ $1 =~ 2026-06-29\ +1 ]]' _ "$out"
check "stats: lines fit 76" bash -c '! awk "length(\$0) > 76 { bad = 1 } END { exit !bad }" <<< "$1"' _ "$out"

# 3. Export: the menu makes ticket and snapshot
out=$(printf 'q' | sys sysop_callers_export 2>&1)
tok=$(grep -o 'x.cgi/[A-Za-z0-9_-]\{22\}' <<< "$out" | head -n 1 | cut -d/ -f2)
check "export: link shown" bash -c '[[ -n $1 ]]' _ "$tok"
check "export: link still works after leaving (ticket + snapshot kept)" \
    bash -c '[[ -f $1/queue/xfer/$2 && -f $1/queue/xfer/$2.snap ]]' _ "$root" "$tok"
check "export: a sleeper removes them once the link has run out" \
    bash -c 'pgrep -f "sleep.*$1/queue/xfer/$2" > /dev/null' _ "$root" "$tok"
pkill -f "sleep.*$root/queue/xfer/" 2>/dev/null
rm -f "$root/queue/xfer/$tok" "$root/queue/xfer/$tok.snap"
# Make a live pair by hand for the cgi tests.
T=AAAAAAAAAAAAAAAAAAAAA1
mk() { printf 'dir=down\nexport=callers\n' > "$root/queue/xfer/$1"; cp "$root/state/callers.log" "$root/queue/xfer/$1.snap"; }
cgi() { # cgi <token> [owner]
    env BASHBBS_TEST=1 BBS_ROOT="$root" BBS_UPLOAD_COMMON="$here/lib/upload-common.sh" \
        BBS_XFER_TEST_OWNER="${2:-bbs-sys0p}" REQUEST_METHOD=GET PATH_INFO="/$1" QUERY_STRING="${3:-}" \
        python3 "$here/web/x.cgi" > "$root/.out" 2>>"$root/.err"; }
status() { sed -n '1s/^Status: \([0-9]*\).*/\1/p' "$root/.out" | tr -d '\r'; }
mk $T
cgi $T
check "cgi: sysop ticket served" eq "$(status)" 200
check "cgi: text/plain attachment" grep -qa 'Content-Type: text/plain' "$root/.out"
check "cgi: file name callers-DATE.log" grep -qaE 'filename="callers-[0-9]{8}\.log"' "$root/.out"
check "cgi: body is the snapshot" grep -qa '2026-11-03T12:00Z bbbob' "$root/.out"
check "cgi: sent marker left" test -e "$root/queue/xfer/$T.sent"
rm -f "$root/queue/xfer/$T.sent"
cgi $T bbs-alice
check "cgi: non-sysop ticket refused" eq "$(status)" 404
check "cgi: nothing of the log leaked to non-sysop" bash -c '! grep -qa bbbob "$1"' _ "$root/.out"
cgi $T bbs-sys0pp
check "cgi: owner only prefix of a sysop refused" eq "$(status)" 404
sleep 2
XFER_TTL_DOWN=1 cgi $T
check "cgi: expired ticket refused" eq "$(status)" 410
rm -f "$root/queue/xfer/$T"*
mk $T
rm -f "$root/queue/xfer/$T.snap"; ln -s "$root/sysops" "$root/queue/xfer/$T.snap"
cgi $T
check "cgi: symlink snapshot refused" eq "$(status)" 404
rm -f "$root/queue/xfer/$T.snap"
cgi $T
check "cgi: missing snapshot refused" eq "$(status)" 404
rm -f "$root/queue/xfer/$T"*
printf 'dir=down\nexport=callers\nid=1500000001-aaaaaaaa\n' > "$root/queue/xfer/$T"; cp "$root/state/callers.log" "$root/queue/xfer/$T.snap"
cgi $T
check "cgi: export plus id lines refused" eq "$(status)" 404
rm -f "$root/queue/xfer/$T"*
printf 'dir=up\nexport=callers\n' > "$root/queue/xfer/$T"; cp "$root/state/callers.log" "$root/queue/xfer/$T.snap"
cgi $T
check "cgi: upload ticket with export refused" eq "$(status)" 404
rm -f "$root/queue/xfer/$T"*
mk $T
cgi "$T/../../sysops"
check "cgi: path trick in token refused" eq "$(status)" 404
cgi "$T.snap"
check "cgi: token with .snap suffix refused" eq "$(status)" 404
cgi "../state/callers.log"
check "cgi: relative path refused" eq "$(status)" 404
printf 'dir=down\nexport=../../sysops\n' > "$root/queue/xfer/BBBBBBBBBBBBBBBBBBBBB1"
cgi BBBBBBBBBBBBBBBBBBBBB1
check "cgi: export with another value refused" eq "$(status)" 404

rm -rf "$root"
echo "callers_stats_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
