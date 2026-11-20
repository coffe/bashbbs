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
elif sys.argv[1] == "raw":  # raw OUT PKTORIG PASS to|from|subj|morig|mdest|text   (\n = CR, ^A = kludge)
    out = pkt(sys.argv[3], sys.argv[4], [])[:-2]
    for s in sys.argv[5:]:
        to, frm, subj, mo, md, t = s.split("|", 5)
        (_, n, f), (_, dn, df) = addr(mo), addr(md)
        t = t.replace("\\n", "\r").replace("^A", "\x01")
        out += struct.pack("<7H", 2, f, df, n, dn, 0, 0) + b"18 Nov 26  08:05:09\0" + b"\0".join(x.encode() for x in (to, frm, subj, t)) + b"\0"
    open(sys.argv[2], "wb").write(out + b"\0\0")
elif sys.argv[1] == "zip":  # zip OUT NAME=FILE ...
    with zipfile.ZipFile(sys.argv[2], "w") as z:
        for a in sys.argv[3:]:
            n, f = a.split("=", 1); z.writestr(n, open(f, "rb").read())
elif sys.argv[1] == "dump":  # dump PKT: "MSG attr= orig= dest= to= from= subj=" per message, then its text (^A = kludge)
    d = open(sys.argv[2], "rb").read(); pos = 58
    while d[pos:pos + 2] == b"\2\0":
        _, on, dn, onet, dnet, attr, _ = struct.unpack_from("<7H", d, pos); pos += 14; f = []
        for _ in range(5):
            e = d.index(b"\0", pos); f.append(d[pos:e].decode("cp437")); pos = e + 1
        print("MSG attr=%d orig=%d/%d dest=%d/%d to=%s from=%s subj=%s" % (attr, onet, on, dnet, dn, f[1], f[2], f[3]))
        print(f[4].replace("\1", "^A").replace("\r", "\n"))
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
# a busy or failed call says so in fido.log (binkd still exits 0)
rm -f "$st/poll-calls" "$st/poll-backoff"
printf '#!/bin/sh\necho "$@" > %s/E/args\necho "? 20 Nov 18:16:06 [1] got M_BSY: RETRY 0600: Down for maintenance, back soon..." >> %s/binkd.log\necho "+ 20 Nov 18:16:06 [1] done (to 21:3/100@fsxnet, failed, S/R: 0/0 (0/0 bytes))" >> %s/binkd.log\n' "$top" "$st" "$st" > "$top/fakebinkd"
poll
check "poll: maintenance M_BSY logged as hub busy" grep -q 'poll: hub busy (RETRY 0600: Down for maintenance, back soon...), nothing sent; binkd exit 0' "$st/fido.log"
check "poll: maintenance M_BSY sets no backoff" test ! -e "$st/poll-backoff"
printf '#!/bin/sh\necho "+ 20 Nov 18:30:00 [2] done (to 21:3/100@fsxnet, failed, S/R: 0/0 (0/0 bytes))" >> %s/binkd.log\n' "$st" > "$top/fakebinkd"
poll
check "poll: failed call logged" test "$(tail -n 1 "$st/fido.log" | grep -c 'poll: call failed, nothing sent; binkd exit 0')" = 1
sed -i '/^hubhost/d' "$top/E/fido.conf"; echo 'hubhost bad host;rm' >> "$top/E/fido.conf"
rc=0; BBS_ROOT=$top/E BBS_FIDO_HOST=hoste BBS_FIDO_BINKD=$top/fakebinkd python3 -I "$fido" poll 2>/dev/null || rc=$?
check "poll: bad hubhost refused" test "$rc" -ne 0

# --- an ANSI ad (cp437, colours, a line continued with ESC[A ESC[nC) arrives as the text it draws
mk pkt "$top/ad.pkt" 21:1/100 secret "FSX_GEN|Ads|Färgad annons|21:1/100 7||"$'\e[2J\e[H\e[1;36m═══ \e[1;35mPiEW\e[0m\n\e[A\e[8CPiEW\nslut'"|CP437 2"
cp "$top/ad.pkt" "$top/A/in/ad.pkt"; old "$top/A/in/ad.pkt"
run A toss
adf=$(grep -l '^Subject: Färgad annons' "$top"/A/boards/fsx_gen/*.msg)
check "ansi ad tossed" test -n "$adf"
check "ansi ad: drawn text, line put back together" grep -qx '═══ PiEWPiEW' "$adf"
check "ansi ad: no colour code left" bash -c "! grep -q '\[1;3' '$adf'"
check "ansi ad: no ads area, no file kept" bash -c "! grep -q '^Ansi:' '$adf' && ! test -d '$top/A/published'"

# --- with an ads file area the original is kept there as cp437 bytes, once per identical ad
mkdir -p "$top/A/etc"; printf 'general|General|x\nads|Ads|ANSI ads\n' > "$top/A/etc/file-areas"
adbody=$'\e[1;36m═══ PiEW\e[0m\n--- Mystic\n * Origin: Somewhere (21:1/100)'
toss_ad() { # toss_ad <msgid number> <subject> <body>
    mk pkt "$top/ad$1.pkt" 21:1/100 secret "FSX_GEN|Ad Man|$2|21:1/100 $1||$3|CP437 2"
    cp "$top/ad$1.pkt" "$top/A/in/ad$1.pkt"; old "$top/A/in/ad$1.pkt"; run A toss
}
toss_ad 8 "Färgad igen" "$adbody"
adf=$(grep -l '^Subject: Färgad igen' "$top"/A/boards/fsx_gen/*.msg)
aid=$(sed -n 's/^Ansi: //p' "$adf")
check "ads: message points at the kept file" test -f "$top/A/published/$aid"
check "ads: meta in area ads" grep -qx 'area=ads' "$top/A/published/$aid.meta"
check "ads: named date-sender-subject" grep -qx "name=$(date +%Y%m%d)-ad-man-fargad-igen.ans" "$top/A/published/$aid.meta"
check "ads: original cp437 bytes with ESC, no origin" bash -c "printf '\e[1;36m\xcd\xcd\xcd PiEW\e[0m\r\n' | cmp -s - '$top/A/published/$aid'"
toss_ad 9 "Samma igen" "$adbody"
check "ads: same ad again keeps one file" test "$(sed -n 's/^Ansi: //p' $(grep -l '^Subject: Samma igen' "$top"/A/boards/fsx_gen/*.msg))" = "$aid"
check "ads: still one file" test "$(ls "$top/A/published" | wc -l)" -eq 2
# at the cap the oldest ad moves to state/expired, never deleted
for i in $(seq 1 99); do
    printf 'x' > "$top/A/published/$i-0000000a"; printf 'size=1\narea=ads\nsha256=%s\n' "$i" > "$top/A/published/$i-0000000a.meta"
done
toss_ad 10 "Ny annons" $'\e[1mNY'
check "ads: kept at 100" test "$(ls "$top"/A/published/*.meta | wc -l)" -eq 100
check "ads: oldest moved to expired" test -f "$top/A/state/expired/1-0000000a.meta" -a -f "$top/A/state/expired/1-0000000a"

# block art is 3 UTF-8 bytes a cell: the cap counts characters, so a 4800-cell ad stays whole
toss_ad 11 "Block art" "$(for i in $(seq 60); do printf '%.0s█' $(seq 80); echo; done)"$'\nEND OF AD'
check "long block ad not cut" grep -qx 'END OF AD' "$(grep -l '^Subject: Block art' "$top"/A/boards/fsx_gen/*.msg)"

# --- netmail (no AREA) -> the recipient's Maildir/new; A is 21:9/999
mkdir -p "$top"/A/users/{kitty,coffe} "$top"/homes/{kitty,coffe}/Maildir/{tmp,new,cur}
touch "$top"/A/users/{kitty,coffe}/profile; printf 'coffe\n' > "$top/A/sysops"
net() { # net <name> <message spec>...: one packet from the hub, tossed on A
    mk raw "$top/$1.pkt" 21:1/100 secret "${@:2}"; cp "$top/$1.pkt" "$top/A/in/$1.pkt"; old "$top/A/in/$1.pkt"
    BASHBBS_TEST=1 BBS_TEST_HOMES=$top/homes run A toss
}
inbox() { ls "$top/homes/$1/Maildir/new" | wc -l; }
nm1="Kitty|Jane|Hej Kitty|21:1/100|21:9/999|^AINTL 21:9/999 21:99/1\n^AMSGID: 21:99/1 abc123\n^ACHRS: UTF-8 4\nHej där"
net nm1 "$nm1"
kf=$(ls "$top"/homes/kitty/Maildir/new/* 2>/dev/null | head -1)
check "netmail: delivered to kitty" test "$(inbox kitty)" = 1
check "netmail: From is name@address" grep -qx 'From: Jane@21:99/1' "$kf"
check "netmail: To, Subject, X-Fido-Msgid" bash -c "grep -qx 'To: kitty' '$kf' && grep -qx 'Subject: Hej Kitty' '$kf' && grep -qx 'X-Fido-Msgid: 21:99/1 abc123' '$kf'"
check "netmail: Message-ID and Date" bash -c "grep -q '^Message-ID: <.*@fido>$' '$kf' && grep -q '^Date: .*18 Nov 2026 08:05:09' '$kf' && grep -qx 'Hej där' '$kf'"
check "netmail: mode 0600" test "$(stat -c %a "$kf")" = 600
check "netmail: logged" grep -q 'netmail Jane@21:99/1 -> kitty' "$top/A/state/fido/fido.log"
net nm1b "$nm1"
check "netmail: same message twice delivered once" test "$(inbox kitty)" = 1
net nm2 "Nobody Here|Zap|Hi|21:3/7|21:9/999|^AFMPT 2\nplain text"
cf=$(ls "$top"/homes/coffe/Maildir/new/* 2>/dev/null | head -1)
check "netmail: unknown name to the sysop" test "$(inbox coffe)" = 1
check "netmail: no INTL, origin from header + FMPT" grep -qx 'From: Zap@21:3/7.2' "$cf"
check "netmail: Originally to first" bash -c "sed '1,/^\$/d' '$cf' | head -1 | grep -qx '(Originally to: Nobody Here)'"
net nm3 "Kitty|Jane|Other|21:1/100|21:9/999|^AINTL 21:5/5 21:99/1\nnot for us"
check "netmail: other node skipped" bash -c "test \"\$(find '$top'/homes/*/Maildir/new -type f | wc -l)\" = 2 && grep -q 'netmail for 21:5/5, not us' '$top/A/state/fido/fido.log'"
net nm4 "Kitty|Ev"$'\r'"X-Evil: 1|S|21:1/100|21:9/999|^AINTL 21:9/999 21:99/1\n^AMSGID: 21:99/1 e1\nx"
ef=$(grep -l 'e1$' "$top"/homes/kitty/Maildir/new/*)
check "netmail: CR in From removed" bash -c "grep -qx 'From: EvX-Evil: 1@21:99/1' '$ef' && ! grep -q '^X-Evil' '$ef'"
net eo "All|Ed|No origin|21:1/100|21:9/999|AREA:FSX_GEN\n^AMSGID: 21:4/7 77\nbody without origin"
check "echomail without Origin: Node from MSGID" grep -qx 'Node: 21:4/7' "$(grep -l '^Subject: No origin' "$top"/A/boards/fsx_gen/*.msg)"

# --- outbound netmail: bbs-publish output in netmail/out, scan on A packs it, toss on B (21:1/100) delivers
nmo=$top/A/state/fido/netmail/out; mkdir -p "$nmo"
printf 'Author: alice\nDate: 2026-11-19T10:00:00Z\nTo-Name: Bob\nTo-Addr: 21:1/100\nSubject: Hej Bob\nReply: 21:1/100 abc\n\nNetmail åäö\n---\n' > "$nmo/1700000001-n1.msg"
printf 'Author: alice\nDate: 2026-11-19T10:00:00Z\nTo-Name: Pt\nTo-Addr: 21:1/100.5\nSubject: To a point\n\nhi point\n' > "$nmo/1700000002-n2.msg"
run A scan
npk=$(ls -t "$top"/A/state/fido/out/*.pkt | head -1)
d=$(mk dump "$npk")
check "netmail out: header to the final node, Private, from the handle" has "$d" "MSG attr=1 orig=9/999 dest=1/100 to=Bob from=alice subj=Hej Bob"
check "netmail out: INTL, MSGID, REPLY, Via, tearline" bash -c 'for k in "^AINTL 21:1/100 21:9/999" "^AMSGID: 21:9/999 " "^AREPLY: 21:1/100 abc" "^ACHRS: CP437 2" "^AVia 21:9/999 @" "--- BashBBS" " ---"; do grep -qF -- "$k" <<<"$1" || exit 1; done' _ "$d"
check "netmail out: no AREA, SEEN-BY, PATH or Origin" bash -c '! grep -qE "AREA:|SEEN-BY|PATH:|Origin" <<<"$1"' _ "$d"
check "netmail out: point gets TOPT" bash -c 'grep -q "to=Pt " <<<"$1" && grep -qxF "^ATOPT 5" <<<"$1"' _ "$d"
check "netmail out: in the flo" grep -qx "\\^$npk" "$top/A/out/00010064.flo"
check "netmail out: moved to sent" bash -c "test -z \"\$(ls '$nmo')\" && test \"\$(ls '$top/A/state/fido/netmail/sent' | wc -l)\" = 2"
mkdir -p "$top/B/users/bob" "$top/homes/bob/Maildir"/{tmp,new,cur}; touch "$top/B/users/bob/profile"
cp "$npk" "$top/B/in/rt.pkt"; old "$top/B/in/rt.pkt"
BASHBBS_TEST=1 BBS_TEST_HOMES=$top/homes run B toss
bf=$(ls "$top"/homes/bob/Maildir/new/* 2>/dev/null | head -1)
check "netmail round trip: delivered to bob" test "$(inbox bob)" = 1
check "netmail round trip: From, Subject, body, X-Fido-Msgid" bash -c "grep -qx 'From: alice@21:9/999' '$bf' && grep -qx 'Subject: Hej Bob' '$bf' && grep -qx 'Netmail åäö' '$bf' && grep -qE '^X-Fido-Msgid: 21:9/999 [0-9a-f]{8}$' '$bf'"
check "netmail round trip: point mail not for B" grep -q 'netmail for 21:1/100.5, not us' "$top/B/state/fido/fido.log"

echo "pass=$pass fail=$fail"
rm -rf "$top"
[[ $fail -eq 0 ]]
