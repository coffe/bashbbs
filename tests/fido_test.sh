#!/bin/bash
# sbin/bbs-fido: toss (inbound packets/bundles -> board files) and scan (board files -> packet
# + .flo), two BBS roots playing both ends. Usage: tests/fido_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/fido_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }
fido="$here/sbin/bbs-fido"

top=$(mktemp -d "$scratch/fido.XXXXXX")
# Packet builder: mk.py pkt OUT ORIGADDR PASS AREA|from|subj|msgid|reply|body ...   (\n in body = CR)
cat > "$top/mk.py" <<'PY'
import struct, sys, zipfile
def addr(s):
    z, r = s.split(":"); n, f = r.split("/"); return int(z), int(n), int(f)
def pkt(orig, pw, msgs, dest="21:9/999"):
    z, n, f = addr(orig); dz, dn, df = addr(dest)
    h = struct.pack("<8H", f, df, 2026, 10, 18, 7, 5, 9) + struct.pack("<HHHH", 0, 2, n, dn) + b"\xfe\x01"
    h += pw.encode().ljust(8, b"\0") + struct.pack("<HHH", z, dz, 0) + b"\0\1\0\0\1\0" + struct.pack("<HHHH", z, dz, 0, 0) + b"\0" * 4
    for area, frm, subj, mid, rep, body, chrs in msgs:
        t = ("AREA:%s\r" % area) if area else ""
        if mid: t += "\x01MSGID: %s\r" % mid
        if rep: t += "\x01REPLY: %s\r" % rep
        t += "\x01CHRS: %s\r\x01TZUTC: 0100\r" % chrs + body.replace("\n", "\r") + "\r--- t\r * Origin: Far (21:4/5)\rSEEN-BY: 1/100\r\x01PATH: 1/100\r"
        enc = {"UTF-8 4": "utf-8", "CP437 2": "cp437"}[chrs]
        h += struct.pack("<7H", 2, f, df, n, dn, 0, 0) + b"18 Nov 26  08:05:09\0All\0" + frm.encode(enc) + b"\0" + subj.encode(enc) + b"\0" + t.encode(enc) + b"\0"
    return h + b"\0\0"
def parse(a):
    msgs = []
    for s in a:
        p = s.split("|"); msgs.append((p[0], p[1], p[2], p[3], p[4], p[5].replace("\\n", "\n"), p[6] if len(p) > 6 else "UTF-8 4"))
    return msgs
if sys.argv[1] == "pkt":
    open(sys.argv[2], "wb").write(pkt(sys.argv[3], sys.argv[4], parse(sys.argv[5:])))
elif sys.argv[1] == "zip":  # zip OUT NAME=FILE ...
    with zipfile.ZipFile(sys.argv[2], "w") as z:
        for a in sys.argv[3:]:
            n, f = a.split("=", 1); z.writestr(n, open(f, "rb").read())
elif sys.argv[1] == "date":  # first message date field of a packet
    d = open(sys.argv[2], "rb").read(); print(d[72:91].decode())
PY
mk() { python3 -I "$top/mk.py" "$@"; }

# setup <name> <address> <hub> <host>: a BBS root with boards fsx_gen (fido), plain (no .fido), priv
setup() {
    local r=$top/$1; mkdir -p "$r"/{boards/fsx_gen,boards/plain,meta,in,out}
    printf 'fido=on\n' > "$r/features"; : > "$r/meta/fsx_gen.fido"
    printf 'address %s\nhub %s\npassword secret\nbbsname Tést BBS\ninbound %s/in\noutbound %s/out\narea FSX_GEN fsx_gen\narea FSX_PLAIN plain\narea FSX_NONE nosuch\n' \
        "$2" "$3" "$r" "$r" > "$r/fido.conf"
    echo "$4" > "$r/host"
}
run() { # run <root-name> toss|scan
    local r=$top/$1
    BBS_ROOT=$r BBS_FIDO_HOST=$(cat "$r/host") python3 -I "$fido" "$2"
}
old() { touch -d '2 minutes ago' "$@"; }
post() { # post <root> <board> <uuid> <Author> <Node> <Date> <Subject> <body> [extra header lines]
    local f=$top/$1/boards/$2/1700000000-$3.msg
    printf 'Msgid: %s\nAuthor: %s\nNode: %s\nDate: %s\nSubject: %s\n%b\n%s\n' "$3" "$4" "$5" "$6" "$7" "${9:-}" "$8" > "$f"
    chmod 0644 "$f"
}
msgs() { ls "$top/$1/boards/$2/" 2>/dev/null | grep -c '\.msg$'; }
hdr() { grep -h "^$3: " "$top/$1/boards/$2/"*.msg | head -1; }
bads() { ls "$top/$1/state/fido/bad" | wc -l; }

setup A 21:9/999 21:1/100 hosta
setup B 21:1/100 21:9/999 hostb
ua=11111111-1111-4111-8111-111111111111
post A fsx_gen $ua alice hosta 2026-11-18T07:05:09Z "Hello från Alice" $'Första raden åäö\nandra raden'

# --- scan on A, toss on B
run A scan
pk=$(ls "$top"/A/state/fido/out/*.pkt)
check "scan wrote one packet" test -n "$pk" -a "$(echo "$pk" | wc -l)" = 1
check "flo has the packet line" grep -qx "\\^$pk" "$top/A/out/00010064.flo"
check "bsy removed" test ! -e "$top/A/out/00010064.bsy"
check "post marked with Fido-Msgid" has "$(hdr A fsx_gen Fido-Msgid)" "21:9/999 11111111"
check "outgoing date format exact" test "$(mk date "$pk")" = "18 Nov 26  07:05:09"
check "packet ends with 0000" bash -c "tail -c2 '$pk' | od -An -tx1 | grep -q '00 00'"
run A scan
check "second scan: no new packet" test "$(ls "$top"/A/state/fido/out/*.pkt | wc -l)" = 1
cp "$pk" "$top/B/in/a.pkt"; old "$top/B/in/a.pkt"
run B toss
check "B got the post" test "$(msgs B fsx_gen)" = 1
check "subject kept" has "$(hdr B fsx_gen Subject)" "Hello från Alice"
check "author gets @fsx" has "$(hdr B fsx_gen Author)" "alice@fsx"
check "node from origin" has "$(hdr B fsx_gen Node)" "21:9/999"
check "date kept" has "$(hdr B fsx_gen Date)" "2026-11-18T07:05:09Z"
check "text kept (cp437 round trip)" grep -q 'Första raden åäö' "$top"/B/boards/fsx_gen/*.msg
check "second line kept" grep -qx 'andra raden' "$top"/B/boards/fsx_gen/*.msg
check "packet moved to done" test -e "$(ls "$top"/B/state/fido/done/* | head -1)" -a ! -e "$top/B/in/a.pkt"
check "public board file mode" test "$(stat -c %a "$top"/B/boards/fsx_gen/*.msg)" = 644

# --- reply on B, scan, toss on A: Parent = A's local Msgid
bf=$(ls "$top"/B/boards/fsx_gen/*.msg); bu=$(grep -h '^Msgid: ' "$bf" | cut -c8-)
ub=22222222-2222-4222-8222-222222222222
post B fsx_gen $ub bob hostb 2026-11-18T08:00:00Z "Re: Hello" "svar" "Parent: $bu\n"
run B scan
check "B does not re-export tossed post" test "$(grep -c . "$top/B/out/000903e7.flo")" = 1
cp "$(ls "$top"/B/state/fido/out/*.pkt)" "$top/A/in/b.pkt"; old "$top/A/in/b.pkt"
run A toss
check "A got the reply" test "$(msgs A fsx_gen)" = 2
check "reply Parent maps to our local Msgid" bash -c "grep -l '^Author: bob@fsx' '$top'/A/boards/fsx_gen/*.msg | xargs grep -q '^Parent: $ua'"
check "thread kept on the way out (REPLY set)" bash -c "grep -aq 'REPLY: 21:9/999 11111111' '$top'/B/state/fido/out/*.pkt"

# --- duplicates
check "dup toss: still two" bash -c "cp '$top/B/state/fido/out/'*.pkt '$top/A/in/b2.pkt'; touch -d '2 minutes ago' '$top/A/in/b2.pkt'; true"
run A toss
check "duplicate packet gives no second post" test "$(msgs A fsx_gen)" = 2

# --- rejects
mk pkt "$top/bad1.pkt" 21:7/7 secret "FSX_GEN|x|s|21:7/7 1|||UTF-8 4" "FSX_GEN|x|s|21:7/7 1|||UTF-8 4"
cp "$top/bad1.pkt" "$top/A/in/wronghub.pkt"
mk pkt "$top/bad2.pkt" 21:1/100 wrong "FSX_GEN|x|s|21:1/100 2|||UTF-8 4"
cp "$top/bad2.pkt" "$top/A/in/wrongpw.pkt"
printf 'x' > "$top/evil.pkt"; mk zip "$top/evil.zip" "../x.pkt=$top/evil.pkt"; cp "$top/evil.zip" "$top/A/in/evil.zip"
mk zip "$top/dir.zip" "sub/x.pkt=$top/evil.pkt"; cp "$top/dir.zip" "$top/A/in/dir.zip"
head -c 11000000 /dev/zero > "$top/A/in/big.zip"; printf 'PK\003\004' | dd of="$top/A/in/big.zip" conv=notrunc 2>/dev/null
head -c 4200000 /dev/zero > "$top/A/in/big.pkt"
echo junk > "$top/A/in/readme.txt"
mk pkt "$top/new.pkt" 21:1/100 secret "FSX_GEN|x|s|21:1/100 3|||UTF-8 4"; cp "$top/new.pkt" "$top/A/in/fresh.pkt"
for f in wronghub.pkt wrongpw.pkt evil.zip dir.zip big.zip big.pkt readme.txt; do old "$top/A/in/$f"; done
run A toss
check "wrong hub address -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c wronghub)" = 1
check "wrong password -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c wrongpw)" = 1
check "zip with ../ member -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c evil.zip)" = 1
check "zip with dir member -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c dir.zip)" = 1
check "oversize bundle -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c big.zip)" = 1
check "oversize packet -> bad" test "$(ls "$top"/A/state/fido/bad | grep -c big.pkt)" = 1
check "other file left alone" test -e "$top/A/in/readme.txt"
check "fresh file (mtime < 10 s) left alone" test -e "$top/A/in/fresh.pkt"
check "nothing written by rejected packets" test "$(msgs A fsx_gen)" = 2

# --- unknown area, board without .fido, good zip bundle
mk pkt "$top/mix.pkt" 21:1/100 secret "NOPE|x|s|21:1/100 4|||UTF-8 4" "FSX_PLAIN|x|s|21:1/100 5|||UTF-8 4" \
    "fsx_gen|Zoë|Låda|21:1/100 6||rad ett\nrad två|UTF-8 4"
cp "$top/mix.pkt" "$top/in.pkt"; mk zip "$top/good.zip" "0000ABCD.pkt=$top/in.pkt"; cp "$top/good.zip" "$top/A/in/good.zip"; old "$top/A/in/good.zip"
run A toss
check "unknown area skipped" has "$(cat "$top/A/state/fido/fido.log")" "unknown area NOPE"
check "board without .fido skipped" test "$(msgs A plain)" = 0
check "zip member tossed, area case-insensitive" test "$(msgs A fsx_gen)" = 3
check "latin author from utf-8" bash -c "grep -q '^Author: Zoë@fsx' '$top'/A/boards/fsx_gen/*.msg"
check "no .tmp files left" test -z "$(find "$top/A/boards" -name '.tmp*')"

# --- scan skips marked, deleted, @fsx, foreign-node posts
setup C 21:9/999 21:1/100 hostc
post C fsx_gen 33333333-3333-4333-8333-333333333333 x hostc 2026-11-18T07:00:00Z "marked" t "Fido-Msgid: 21:9/999 33333333\n"
post C fsx_gen 44444444-4444-4444-8444-444444444444 x hostc 2026-11-18T07:00:00Z "deleted" t "Deleted: yes\n"
post C fsx_gen 55555555-5555-4555-8555-555555555555 x@fsx hostc 2026-11-18T07:00:00Z "remote" t
post C fsx_gen 66666666-6666-4666-8666-666666666666 x otherhost 2026-11-18T07:00:00Z "foreign" t
run C scan
check "scan exports nothing and makes no files" test -z "$(find "$top"/C/state/fido/out "$top"/C/out -type f)"

# --- cp437 round trip of å/ö bytes on the wire
post C fsx_gen 77777777-7777-4777-8777-777777777777 x hostc 2026-11-18T07:00:00Z "Åke ö" "blåbär"
run C scan
check "cp437 bytes on the wire (å=0x86)" bash -c "LC_ALL=C grep -aqP 'bl\\x86b\\x84r' '$top'/C/state/fido/out/*.pkt"

# --- feature off
setup D 21:9/999 21:1/100 hostd
post D fsx_gen 88888888-8888-4888-8888-888888888888 x hostd 2026-11-18T07:00:00Z "off" t
cp "$top/new.pkt" "$top/D/in/n.pkt"; old "$top/D/in/n.pkt"
printf 'fido=off\n' > "$top/D/features"
run D toss; run D scan
check "fido=off: no post, no packet, packet stays" test "$(msgs D fsx_gen)" = 1 -a -z "$(find "$top"/D/out "$top"/D/state/fido/out -type f)" -a -e "$top/D/in/n.pkt"
check "fido=off logged" has "$(cat "$top/D/state/fido/fido.log")" "fido=off"
printf 'fido = on\n' > "$top/D/features"; rm -f "$top/D/features"
run D toss
check "no features file = off" test -e "$top/D/in/n.pkt"

# --- poll: scan, binkd (a fake that records its arguments and delivers a packet), toss of fresh files
setup E 21:9/999 21:1/100 hoste
printf 'hubhost net1.example:24554\nsysop Kris "K"\n' >> "$top/E/fido.conf"
post E fsx_gen 77777777-7777-4777-8777-777777777777 Sysop hoste 2026-11-18T07:00:00Z "Ut" hej
printf '#!/bin/sh\necho "$@" > %s/E/args\ncp %s/new.pkt %s/E/in/got.pkt\n' "$top" "$top" "$top" > "$top/fakebinkd"; chmod +x "$top/fakebinkd"
BBS_ROOT=$top/E BBS_FIDO_HOST=hoste BBS_FIDO_BINKD=$top/fakebinkd python3 -I "$fido" poll
cfg=$top/E/state/fido/binkd.cfg
check "poll: binkd -p -P hub with the generated config" test "$(cat "$top/E/args")" = "-p -P 21:1/100@fsxnet $cfg"
check "poll: binkd.cfg is 0600" test "$(stat -c %a "$cfg")" = 600
check "poll: node line from fido.conf, CRAM-MD5 required" has "$(cat "$cfg")" "node 21:1/100@fsxnet -md net1.example:24554 secret"
check "poll: domain zone 21 on the outbound" has "$(cat "$cfg")" "domain fsxnet $top/E/out 21"
check "poll: quote in sysop cannot break the config" has "$(cat "$cfg")" "sysop \"Kris 'K'\""
check "poll: scanned before binkd" test -n "$(find "$top/E/out" -name '*.flo')"
check "poll: fresh packet tossed at once" test ! -e "$top/E/in/got.pkt" -a "$(msgs E fsx_gen)" = 2
# --- hub limit: every connect counted (timer and manual share it), 65 min backoff after M_BSY
st=$top/E/state/fido
poll() { rm -f "$top/E/args"; BBS_ROOT=$top/E BBS_FIDO_HOST=hoste BBS_FIDO_BINKD=$top/fakebinkd python3 -I "$fido" poll >/dev/null; }
called() { test -e "$top/E/args"; }
now=$(date +%s)
check "limit: the poll's connect was recorded" test "$(grep -c . "$st/poll-calls")" = 1
printf '#!/bin/sh\necho "$@" > %s/E/args\necho "? 18 Nov 22:15:44 [1] got M_BSY: Polling too frequently" >> %s/binkd.log\n' "$top" "$st" > "$top/fakebinkd"
poll
check "limit: M_BSY sets a 65 min backoff" bash -c "b=\$(cat '$st/poll-backoff'); (( b >= $now + 3900 && b <= $now + 3960 ))"
check "limit: M_BSY logs the next allowed time" grep -q 'M_BSY.*next allowed 20' "$st/fido.log"
printf '#!/bin/sh\necho "$@" > %s/E/args\n' "$top" > "$top/fakebinkd"
poll
check "limit: no retry during backoff" not called
check "limit: skip logs the next allowed time" grep -q 'hub limit, no call now; next allowed 20' "$st/fido.log"
check "limit: skip records no connect" test "$(grep -c . "$st/poll-calls")" = 2
echo $((now - 10)) > "$st/poll-backoff"
printf '%s\n' $((now - 4000)) $((now - 900)) $((now - 600)) $((now - 300)) > "$st/poll-calls"
poll
check "limit: backoff over, old connect aged out -> call" called
poll
check "limit: 4 connects in 65 min -> no 5th call" not called
check "limit: next allowed = 4th newest + 65 min" grep -q "next allowed $(date -u -d @$((now - 900 + 3900)) +%Y-%m-%dT%H:%M)" "$st/fido.log"
check "limit: aged-out connects pruned from the file" test "$(grep -c . "$st/poll-calls")" = 4
sed -i '/^hubhost/d' "$top/E/fido.conf"; echo 'hubhost bad host;rm' >> "$top/E/fido.conf"
rc=0; BBS_ROOT=$top/E BBS_FIDO_HOST=hoste BBS_FIDO_BINKD=$top/fakebinkd python3 -I "$fido" poll 2>/dev/null || rc=$?
check "poll: bad hubhost refused" test "$rc" -ne 0

echo "pass=$pass fail=$fail"
rm -rf "$top"
[[ $fail -eq 0 ]]
