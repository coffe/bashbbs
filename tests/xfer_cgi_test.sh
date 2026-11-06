#!/usr/bin/env bash
# Transfer links: web/x.cgi and the sorter's side of it, in a throwaway BBS_ROOT.
# Usage: tests/xfer_cgi_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
base=${SCRATCH:-${TMPDIR:-/tmp}}
root=$(mktemp -d "$base/xfer-cgi.XXXXXX")
log=${1:-$root/test.log}
out=$root/.out
pass=0 fail=0
holder=""
cleanup() { [[ -n $holder ]] && kill "$holder" 2>/dev/null; find "$root" -delete 2>/dev/null; }
[[ -n ${1:-} ]] || log=/dev/null
trap cleanup EXIT

check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d"; fi; }
eq() { [[ $1 == "$2" ]] || { echo "got '$1', wanted '$2'"; return 1; }; }
has() { grep -qa -- "$1" "$2"; }
hasnt() { ! grep -qa -- "$1" "$2"; }

mkdir -p "$root"/{queue/xfer,queue/kick,queue/transfers,queue/ip,published,webup,state,incoming}
T1=AAAAAAAAAAAAAAAAAAAAA1 T2=AAAAAAAAAAAAAAAAAAAAA2 TU=AAAAAAAAAAAAAAAAAAAAU1

# cgi <method> <token> <query> [body file]: runs the script, leaves the response in $out.
cgi() { local method=$1 token=$2 query=$3 body=${4:-/dev/null} length=""
    [[ -n ${4:-} ]] && length=$(stat -c %s -- "$4")
    env BASHBBS_TEST=1 BBS_ROOT="$root" BBS_UPLOAD_COMMON="${COMMON_FILE:-$here/lib/upload-common.sh}" \
        BBS_XFER_TEST_OWNER="${OWNER-bbs-alice}" UPLOAD_MIN_FREE_KB="${UPLOAD_MIN_FREE_KB:-1}" \
        REQUEST_METHOD="$method" PATH_INFO="/$token" QUERY_STRING="$query" \
        CONTENT_LENGTH="${LENGTH-$length}" REMOTE_ADDR=192.0.2.9 HTTP_X_FORWARDED_FOR=198.51.100.5 \
        python3 "$here/web/x.cgi" < "$body" > "$out" 2>>"$root/.err"
}
status() { sed -n '1s/^Status: \([0-9]*\).*/\1/p' "$out" | tr -d '\r'; }
body_of() { python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.stdout.buffer.write(d.split(b"\r\n\r\n",1)[1])' "$out"; }
sorter() { env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_UPLOAD_TEST_OWNER="${1:-bbs-alice}" UPLOAD_MIN_FREE_KB=1 \
    bash "$here/sbin/bbs-upload" >>"$root/.sorter" 2>&1; }
publish() { # publish <id> <name> <content>
    printf '%s' "$3" > "$root/published/$1"
    printf 'user=bbs-bob\nname=%s\nsize=%s\nsha256=%s\n' "$2" "${#3}" "$(printf '%s' "$3" | sha256sum | cut -d' ' -f1)" > "$root/published/$1.meta"
}
ticket() { local t=$1; shift; printf '%s\n' "$@" > "$root/queue/xfer/$t"; }
records() { find "$root/queue/transfers" -mindepth 1 -type f | wc -l; }

ID1=1500000001-aaaaaaaa ID2=1500000002-bbbbbbbb
publish "$ID1" one.txt 'first file'
publish "$ID2" two.txt 'second file'

# --- Fail closed and bad links
COMMON_FILE=$root/missing cgi GET "$T1" ""
check "no limits file: 503" eq "$(status)" 503
cgi GET "not-a-token" ""
check "malformed token: 404" eq "$(status)" 404
cgi GET "$T1/../x" ""
check "token with a path: 404" eq "$(status)" 404
cgi GET "$T1" ""
check "unknown token: 404" eq "$(status)" 404
ln -s "$root/published/$ID1.meta" "$root/queue/xfer/$T1"
cgi GET "$T1" ""
check "symlink as ticket: 404" eq "$(status)" 404
find "$root/queue/xfer/$T1" -delete
ticket "$T2" dir=down "id=$ID1"; ln "$root/queue/xfer/$T2" "$root/queue/xfer/$T1"
cgi GET "$T1" ""
check "hard link as ticket: 404" eq "$(status)" 404
find "$root/queue/xfer" -mindepth 1 -delete
mkfifo "$root/queue/xfer/$T1"
timeout 5 env BASHBBS_TEST=1 BBS_ROOT="$root" BBS_UPLOAD_COMMON="$here/lib/upload-common.sh" BBS_XFER_TEST_OWNER=bbs-alice \
    REQUEST_METHOD=GET PATH_INFO="/$T1" python3 "$here/web/x.cgi" > "$out" </dev/null
check "fifo as ticket: 404, no hang" eq "$(status)" 404
find "$root/queue/xfer/$T1" -delete
ticket "$T1" dir=down "id=$ID1"
OWNER=root cgi GET "$T1" ""
check "ticket owned by a non-BBS account: 404" eq "$(status)" 404
ticket "$T1" dir=sideways "id=$ID1"
cgi GET "$T1" ""
check "unknown direction: 404" eq "$(status)" 404
ticket "$T1" dir=down "id=../../etc/passwd"
cgi GET "$T1" ""
check "path as file id: 404" eq "$(status)" 404

# --- Download
ticket "$T1" dir=down "id=$ID1"
XFER_TTL_DOWN=0 cgi GET "$T1" ""
check "expired ticket: 410" eq "$(status)" 410
check "expired ticket: no record" eq "$(records)" 0

cgi HEAD "$T1" ""
check "HEAD: 200" eq "$(status)" 200
check "HEAD: says the size" has 'Content-Length: 10' "$out"
check "HEAD: no body" eq "$(body_of | wc -c)" 0
check "HEAD: no record" eq "$(records)" 0

cgi GET "$T1" ""
check "GET: 200" eq "$(status)" 200
check "GET: the file itself" eq "$(body_of)" "first file"
check "GET: attachment" has 'Content-Disposition: attachment; filename="one.txt"' "$out"
check "GET: octet-stream" has 'Content-Type: application/octet-stream' "$out"
check "GET: nosniff" has 'X-Content-Type-Options: nosniff' "$out"
check "GET: noindex" has 'X-Robots-Tag: noindex' "$out"
check "GET: no referrer" has 'Referrer-Policy: no-referrer' "$out"
check "GET: one record" eq "$(records)" 1
rec=$(find "$root/queue/transfers" -type f | head -n 1)
check "record: user is the ticket owner" has '^user=bbs-alice$' "$rec"
check "record: address from Caddy" has '^ip=198.51.100.5$' "$rec"
check "record: no temp file left" eq "$(find "$root/queue/transfers" -name '.tmp-*' | wc -l)" 0
check "record: kicks the sorter" test -n "$(ls -A "$root/queue/kick")"
cgi GET "$T1" ""
check "second GET: works" eq "$(body_of)" "first file"
check "second GET: no new record" eq "$(records)" 1

sorter www-data
check "sorter: logs the web download" bash -c 'awk -F"\t" "\$2==\"bbs-alice\" && \$3==\"down\" && \$4==\"$2\" && \$7==\"198.51.100.5\"" "$1" | grep -q .' _ "$root/state/transfers.log" "$ID1"
check "sorter: empties the kick queue" eq "$(ls -A "$root/queue/kick" | wc -l)" 0

printf 'user=bbs-bob\nid=%s\nname=x\nsize=1\nip=1.2.3.4\n' "$ID1" > "$root/queue/transfers/fake"
sorter bbs-alice
check "forged record: not logged" bash -c '! awk -F"\t" "\$2==\"bbs-bob\"" "$1" | grep -q .' _ "$root/state/transfers.log"
check "forged record: removed" test ! -e "$root/queue/transfers/fake"

publish 1500000003-cccccccc 'a"b; x=y.txt' 'odd name'
ticket "$T1" dir=down id=1500000003-cccccccc
cgi GET "$T1" ""
check "odd name cannot break the header" has 'filename="a_b__x_y.txt"' "$out"
find "$root/published" -name '1500000003*' -delete

ticket "$T1" dir=down "id=$ID1" "id=$ID2"
find "$root/state/xfer-done" -mindepth 1 -delete
cgi GET "$T1" ""
check "two files: a page" has 'Content-Type: text/html' "$out"
check "two files: both links" bash -c 'grep -q "?f=0" "$1" && grep -q "?f=1" "$1"' _ "$out"
check "two files: page has a CSP" has "Content-Security-Policy: default-src 'none'" "$out"
cgi GET "$T1" "f=1"
check "file 2 by number" eq "$(body_of)" "second file"
cgi GET "$T1" "f=7"
check "file number out of range: 404" eq "$(status)" 404
cgi GET "$T1" "f=%C2%B2"
check "not an ascii number: 404" eq "$(status)" 404
cgi PUT "$T1" "name=x" "$root/published/$ID1"
check "PUT on a download link: 405" eq "$(status)" 405

ticket "$T2" dir=down id=1500000009-dddddddd
cgi GET "$T2" ""
check "removed file: 404" eq "$(status)" 404
find "$root/queue/xfer/$T2" -delete

# --- Busy
python3 - "$root/state/xfer-slots" "$root/.held" <<'PY' &
import fcntl, os, sys, time
keep = []
for n in range(3):
    fd = os.open(os.path.join(sys.argv[1], str(n)), os.O_CREAT | os.O_WRONLY, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    keep.append(fd)
open(sys.argv[2], "w").close()
time.sleep(30)
PY
holder=$!
mkdir -p "$root/state/xfer-slots"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e $root/.held ]] && break; sleep 0.2; done
ticket "$T1" dir=down "id=$ID1"
cgi GET "$T1" ""
check "all slots taken: 503" eq "$(status)" 503
check "all slots taken: Retry-After" has 'Retry-After:' "$out"
cgi HEAD "$T1" ""
check "all slots taken: HEAD still answers" eq "$(status)" 200
kill "$holder"; wait "$holder" 2>/dev/null; holder=""

# --- Upload
ticket "$TU" dir=up area=demos
cgi GET "$TU" ""
check "upload page: an area line is no problem" eq "$(status)" 200
ticket "$TU" dir=up
ok=$root/.file; printf 'upload one\n' > "$ok"
cgi GET "$TU" ""
check "upload page: 200" eq "$(status)" 200
check "upload page: script carries the nonce" bash -c 'n=$(sed -n "s/.*nonce-\([^;]*\).*/\1/p" "$1" | head -n 1 | tr -d "\r"); [[ -n $n ]] && grep -q "<script nonce=.$n" "$1"' _ "$out"
# The page itself, with the browser stubbed. A link can be used twice.
if command -v node >/dev/null; then
    cp "$out" "$root/.page"
    page() { node - "$root/.page" "$1" <<'EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8').match(/<script[^>]*>([\s\S]*?)<\/script>/)[1];
const empty = process.argv[3] === 'empty';
const el = () => ({ textContent: '', append() {}, addEventListener(_, f) { this.click = f; } });
const ids = {};
const rows = [];
let polls = 0, posted = 0;
let text = 'ok\ta.zip\t1-aaaaaaaa\ndone\n';     // the round before
const document = {
  getElementById: id => ids[id] || (ids[id] = el()),
  createElement: () => { const e = el(); rows.push(e); return e; },
};
class XMLHttpRequest {
  constructor() { this.upload = {}; this.status = 200; this.responseText = 'Received.'; }
  open() {}
  send() { setImmediate(() => this.onload()); }
}
const fetch = async (url, opts) => {
  if (opts && opts.method === 'POST') { posted++; return { text: async () => 'Done.' }; }
  if (posted && ++polls === 3) text += 'rejected\ta.zip\tduplicate\ndone\n';
  return { text: async () => text };
};
const run = new Function('document', 'location', 'XMLHttpRequest', 'fetch', 'setTimeout', src);
run(document, { pathname: '/x' }, XMLHttpRequest, fetch, f => setImmediate(f));
ids.files.files = empty ? [] : [{ name: 'a.zip', size: 1 }];
ids.go.click();
setTimeout(() => {
  const note = rows.length ? rows[2].textContent : '';   // li, progress, note
  console.log([posted, ids.go.disabled ? 'off' : 'on', note, ids.state.textContent].join('|'));
}, 300);
EOF
    }
    check "page: an old done does not end a new round" \
        eq "$(page second)" "1|off|Not accepted: duplicate|All done. You can close this page."
    check "page: Send with no files does nothing" eq "$(page empty)" "0|on||"
fi
cgi PUT "$TU" "name=hello.txt" "$ok"
check "PUT: 200" eq "$(status)" 200
check "PUT: in place under its name" cmp "$ok" "$root/webup/$TU/hello.txt"
check "PUT: no part left" eq "$(find "$root/webup/$TU" -name '.part-*' | wc -l)" 0
cgi PUT "$TU" "name=hello.txt" "$ok"
check "same name still waiting: 409" eq "$(status)" 409
check "same name still waiting: no part left" eq "$(find "$root/webup/$TU" -name '.part-*' | wc -l)" 0

for bad in '..%2Fevil' '%2Fetc%2Fpasswd' '.hidden' 'a%0Ab' 'a%5Cb' "$(printf 'x%.0s' {1..101})" ''; do
    cgi PUT "$TU" "name=$bad" "$ok"
    check "bad name '${bad:0:12}': 400" eq "$(status)" 400
done
check "bad names: nothing escaped" test ! -e "$root/webup/evil"
cgi PUT "$TU" "name=r%C3%A4ka%20mig.txt" "$ok"
check "name with space and umlaut: cleaned" test -f "$root/webup/$TU/r_ka_mig.txt"
find "$root/webup/$TU/r_ka_mig.txt" -delete

LENGTH="" cgi PUT "$TU" "name=a.txt" "$ok"
check "no length: 411" eq "$(status)" 411
LENGTH=0 cgi PUT "$TU" "name=a.txt" "$ok"
check "zero length: 400" eq "$(status)" 400
LENGTH=99999999 cgi PUT "$TU" "name=a.txt" "$ok"
check "over the size limit: 413" eq "$(status)" 413
LENGTH=500 cgi PUT "$TU" "name=short.txt" "$ok"
check "short body: 400" eq "$(status)" 400
check "short body: nothing kept" eq "$(find "$root/webup/$TU" -name '*short*' | wc -l)" 0
UPLOAD_USER_QUOTA=2 cgi PUT "$TU" "name=a.txt" "$ok"
check "over quota: 413 before reading" eq "$(status)" 413
# A sysop's link has no size limit and no quota (the free-space check still holds).
TS=AAAAAAAAAAAAAAAAAAAAS1
ticket "$TS" dir=up
echo alice > "$root/sysops"
UPLOAD_MAX_BYTES=2 cgi PUT "$TS" "name=big.txt" "$ok"
check "sysop: over the size limit is taken" test -f "$root/webup/$TS/big.txt"
UPLOAD_USER_QUOTA=2 UPLOAD_GLOBAL_QUOTA=2 cgi PUT "$TS" "name=full.txt" "$ok"
check "sysop: over quota is taken" test -f "$root/webup/$TS/full.txt"
UPLOAD_MIN_FREE_KB=999999999999 cgi PUT "$TS" "name=disk.txt" "$ok"
check "sysop: a full disk still says no ($(status))" eq "$(status)" 413
find "$root/webup/$TS" -mindepth 1 -delete
mv "$root/sysops" "$root/sysops.off"

TF=AAAAAAAAAAAAAAAAAAAAF1
ticket "$TF" dir=up
for n in $(seq 1 20); do cgi PUT "$TF" "name=f$n" "$ok"; done
check "20 files on one link: all taken" eq "$(find "$root/webup/$TF" -type f | wc -l)" 20
cgi PUT "$TF" "name=f21" "$ok"
check "21st file: 409" eq "$(status)" 409
find "$root/webup/$TF" -delete; find "$root/queue/xfer/$TF" -delete

# --- The sorter
printf 'other bytes\n' > "$ok"
cgi PUT "$TU" "name=second.txt" "$ok"
printf 'first file' > "$ok"
cgi PUT "$TU" "name=dupe.txt" "$ok"
: > "$root/webup/$TU/.part-0000-idle.txt"; touch -d '10 minutes ago' "$root/webup/$TU/.part-0000-idle.txt"
printf 'x' > "$root/webup/$TU/.part-0001-busy.txt"; touch -d '10 minutes ago' "$root/webup/$TU/.part-0001-busy.txt"
python3 - "$root/webup/$TU/.part-0001-busy.txt" "$root/.held2" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(30)
PY
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e $root/.held2 ]] && break; sleep 0.2; done
cgi POST "$TU" "done=1"
check "done: 200" eq "$(status)" 200
sorter bbs-alice
res=$root/state/xfer-results/$TU
check "sorter: published for the ticket owner" bash -c 'grep -lx "name=hello.txt" "$1"/*.meta | xargs grep -qx "user=bbs-alice"' _ "$root/published"
check "results: ok line with the id" bash -c 'printf "ok\thello.txt\t" > "$2"; grep -q "^ok	hello.txt	[0-9]*-[0-9a-f]*$" "$1"' _ "$res" "$root/.x"
check "results: duplicate rejected and names the file" has "^rejected	dupe.txt	already on the BBS as one.txt$" "$res"
check "results: dead part rejected under its real name" has "^rejected	idle.txt	" "$res"
check "sorter: a locked part is left alone" test -e "$root/webup/$TU/.part-0001-busy.txt"
check "results: not done while a part is pending" hasnt '^done$' "$res"
kill "$holder"; wait "$holder" 2>/dev/null; holder=""
find "$root/webup/$TU/.part-0001-busy.txt" -delete
sorter bbs-alice
check "results: done when nothing is pending" has '^done$' "$res"
check "sorter: .done consumed" test ! -e "$root/webup/$TU/.done"
cgi GET "$TU" "results=1"
check "results reach the page" eq "$(body_of | tail -n 1)" "done"
check "results: plain text" has 'Content-Type: text/plain' "$out"

TX=AAAAAAAAAAAAAAAAAAAAX1
mkdir -p "$root/webup/$TX"; printf 'no ticket\n' > "$root/webup/$TX/orphan.txt"
sorter bbs-alice
check "no ticket: not published" bash -c '! grep -qx "name=orphan.txt" "$1"/*.meta' _ "$root/published"
check "no ticket: rejected, not lost" test -n "$(find "$root/incoming/rejected" -name '*-webup-*')"
check "no ticket: folder gone" test ! -e "$root/webup/$TX"

printf 'by scp\nsame bytes\n' > "$ok"
mkdir -p "$root/incoming/bbs-carol"; cp "$ok" "$root/incoming/bbs-carol/a.txt"
sorter bbs-carol
cp "$ok" "$root/incoming/bbs-carol/b.txt"
sorter bbs-carol
check "duplicate check also covers scp" bash -c '! grep -qx "name=b.txt" "$1"/*.meta' _ "$root/published"

# --- Cleanup
mkdir -p "$root/queue/kick/sub"; : > "$root/queue/kick/sub/x"
ticket "$T2" dir=down "id=$ID1"
: > "$root/queue/xfer/bad name"; mkdir "$root/queue/xfer/dir"; ln -s /etc/passwd "$root/queue/xfer/link"
touch -d '3 days ago' "$res"
sorter bbs-alice
check "cleanup: subdirectory in kick is gone" eq "$(ls -A "$root/queue/kick" | wc -l)" 0
check "cleanup: a live ticket stays" test -e "$root/queue/xfer/$T2"
check "cleanup: a name that cannot be a ticket goes" test ! -e "$root/queue/xfer/bad name"
check "cleanup: a directory goes" test ! -e "$root/queue/xfer/dir"
check "cleanup: a symlink goes, not its target" bash -c '[[ ! -L $1 && -e /etc/passwd ]]' _ "$root/queue/xfer/link"
check "cleanup: old results go" test ! -e "$res"
env BBS_ROOT="$root" BBS_UPLOAD_NOCHOWN=1 BBS_UPLOAD_TEST_OWNER=bbs-alice UPLOAD_MIN_FREE_KB=1 XFER_KEEP_SECS=0 \
    bash "$here/sbin/bbs-upload" >>"$root/.sorter" 2>&1
check "cleanup: an old ticket goes" test ! -e "$root/queue/xfer/$T2"
sorter bbs-alice
check "cleanup: its empty folder goes" test ! -e "$root/webup/$TU"

# lighttpd sends SIGTERM as soon as it has the whole response, which is before the
# script has written its log record. A signal in mid-stream must not lose that line.
IDT=1700000099-abcdef01 TT=AAAAAAAAAAAAAAAAAAAAT1
publish "$IDT" term.bin "$(head -c 1000000 /dev/zero | tr '\0' x)"
ticket "$TT" dir=down "id=$IDT"
find "$root/queue/transfers" -mindepth 1 -delete
mkfifo "$root/.term"
env BASHBBS_TEST=1 BBS_ROOT="$root" BBS_UPLOAD_COMMON="$here/lib/upload-common.sh" BBS_XFER_TEST_OWNER=bbs-alice \
    UPLOAD_MIN_FREE_KB=1 REQUEST_METHOD=GET PATH_INFO="/$TT" QUERY_STRING="" REMOTE_ADDR=192.0.2.9 \
    python3 "$here/web/x.cgi" </dev/null >"$root/.term" 2>>"$root/.err" &
termpid=$!
{ head -c 2000 >/dev/null; kill -TERM "$termpid"; cat >/dev/null; } <"$root/.term"
wait "$termpid"
term_records() { grep -l "^id=$IDT\$" "$root"/queue/transfers/* 2>/dev/null | wc -l; }
check "SIGTERM: the download is still logged" eq "$(term_records)" 1
find "$root/.term" -delete

# A record cut off by power loss or SIGKILL does not stay in the queue for ever.
touch -d '2 hours ago' "$root/queue/transfers/.tmp-stale"
touch "$root/queue/transfers/.tmp-fresh"
sorter
check "sorter clears an old .tmp record" test ! -e "$root/queue/transfers/.tmp-stale"
check "sorter leaves one being written" test -e "$root/queue/transfers/.tmp-fresh"

check "no python errors from x.cgi" test ! -s "$root/.err"
[[ -s $root/.err && $log != /dev/null ]] && cat "$root/.err" >> "$log"
echo "xfer_cgi_test: $pass passed, $fail failed"
(( fail == 0 ))
