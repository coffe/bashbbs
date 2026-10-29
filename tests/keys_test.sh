#!/bin/bash
# Tests for SSH key management (etapp 1): sbin/bbs-keycheck (validator),
# sbin/bbs-keys-apply (queue handler), sbin/bbs-keys (sysop CLI) and the shared
# lib/keys-common.sh. Spec: thoughts/kristofer/plan-ssh-keys.md section 3 and
# keys-contract.md. Every scenario has its own BBS_ROOT under one run directory in
# the scratchpad; throwaway keys come from ssh-keygen. Never touches /srv or real keys.
#
# Test hooks (BASHBBS_TEST=1): BBS_TEST_OWNER=bbs-<name> stands in for the owner of
# files owned by the running user; BBS_KEYS_JOURNAL_CMD replaces journalctl.
# "Other uid" cases cannot be built without root, so they use owner names the
# handler must refuse (bbs-news, no bbs-shell uid, invalid names).
#
# Usage: tests/keys_test.sh [logfile]   (full log in the file; the screen shows
# only failures and the summary). The run directory is left in place.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/b81958b1-d888-4669-a367-89842baf6a52/scratchpad}
[[ -d $scratch ]] || scratch=${TMPDIR:-/tmp}
log=${1:-$scratch/keys_test.log}
: > "$log"
pass=0; fail=0
top=$(mktemp -d "$scratch/keys.XXXXXX")
APPLY=$here/sbin/bbs-keys-apply
CLI=$here/sbin/bbs-keys
KEYCHECK=$here/sbin/bbs-keycheck
export LC_ALL=C.UTF-8
unset BBS_KEYS_JOURNAL_CMD BBS_TEST_OWNER BBS_ROOT

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }
ne() { [[ $1 != "$2" ]]; }
has() { grep -qE -- "$2" <<< "$1"; }
hasf() { grep -qF -- "$2" <<< "$1"; }          # has <text> <regex>
lacks() { ! grep -qE -- "$2" <<< "$1"; }
rc_is() { local want=$1; shift; "$@"; [[ $? -eq $want ]]; }
rc_not0() { "$@"; [[ $? -ne 0 ]]; }

# ---------------------------------------------------------------- keys
K=$top/k; mkdir -p "$K"
for n in a1 a2 a3 a4 a5 a6 a7 a8 a9 b1 b2 b3 b4 c1 c2 ca; do
    ssh-keygen -q -t ed25519 -N '' -C "comment-$n" -f "$K/$n" >/dev/null 2>&1
done
ssh-keygen -q -t rsa -b 2048 -N '' -f "$K/r2048" >/dev/null 2>&1
ssh-keygen -q -t rsa -b 1536 -N '' -f "$K/r1536a" >/dev/null 2>&1
ssh-keygen -q -t rsa -b 1536 -N '' -f "$K/r1536b" >/dev/null 2>&1
ssh-keygen -q -t rsa -b 1536 -N '' -f "$K/r1536c" >/dev/null 2>&1
ssh-keygen -q -t rsa -b 1024 -N '' -f "$K/r1024" >/dev/null 2>&1
openssl genrsa -out "$K/r2047.pem" 2047 >/dev/null 2>&1
ssh-keygen -y -f "$K/r2047.pem" > "$K/r2047.pub" 2>/dev/null
for b in 256 384 521; do ssh-keygen -q -t ecdsa -b $b -N '' -f "$K/e$b" >/dev/null 2>&1; done
python3 - "$K" <<'PY'
import base64, struct, sys
k = sys.argv[1]
s = lambda b: struct.pack(">I", len(b)) + b
blob = s(b"sk-ssh-ed25519@openssh.com") + s(bytes(range(32))) + s(b"ssh:")
open(k + "/sk1.pub", "w").write("sk-ssh-ed25519@openssh.com " + base64.b64encode(blob).decode() + " sk\n")
body = open(k + "/a1.pub").read().split()[1]
raw = base64.b64decode(body)
open(k + "/trunc.pub", "w").write("ssh-ed25519 " + base64.b64encode(raw[:20]).decode() + "\n")
open(k + "/junk.pub", "w").write("ssh-ed25519 " + base64.b64encode(b"hello world, this is not a key").decode() + "\n")
PY
cp "$K/c1.pub" "$K/u.pub"; ssh-keygen -q -s "$K/ca" -I id -n x "$K/u.pub" >/dev/null 2>&1   # -> u-cert.pub

kl()   { cut -d' ' -f1,2 "$K/$1.pub"; }                                # "type body"
kfull() { cut -d' ' -f1,2 "$K/$1.pub" | tr -d '\n'; printf ' comment text\n'; }
kbody() { cut -d' ' -f2 "$K/$1.pub"; }
ktype() { cut -d' ' -f1 "$K/$1.pub"; }
fpof() { ssh-keygen -l -E sha256 -f "$K/$1.pub" | cut -d' ' -f2; }
ALLNAMES="a1 a2 a3 a4 a5 a6 a7 a8 a9 b1 b2 b3 b4 c1 c2 r2048 r1536a r1536b r1536c r1024 r2047 e256 e384 e521 sk1"
[[ -s $K/u-cert.pub && -s $K/r2047.pub && -s $K/sk1.pub ]] || { echo "FAIL fixtures (u-cert/r2047/sk1) missing" | tee -a "$log"; fail=$((fail + 1)); }

# ---------------------------------------------------------------- tree helpers
roots=()
newroot() {
    root=$(mktemp -d "$top/root.XXXXXX"); roots+=("$root")
    mkdir -p "$root"/{keys,users/alice,users/bob,queue/keys,state,drop,etc,t}
    chmod 1733 "$root/queue/keys"
    kl a1 > "$root/keys/bbs-alice"; kl b1 > "$root/keys/bbs-bob"
    chmod 0644 "$root"/keys/bbs-*
    echo "created=2026-10-01T00:00:00Z" > "$root/users/alice/profile"
    echo "created=2026-10-02T00:00:00Z" > "$root/users/bob/profile"
    REQN=0; JCMD=; : > "$root/run.out"
}
req() { # req <printf %b text> -> queue/keys/<id>.keys (id in LASTID)
    REQN=$((REQN + 1)); LASTID=$(printf '%08d-r%d' "$REQN" "$REQN")
    printf '%b' "$1" > "$root/queue/keys/$LASTID.keys"
}
reqid() { printf '%b' "$2" > "$root/queue/keys/$1.keys"; }                # reqid <id> <text>
addreq() { req "Action: add\nKey: $(kl "$1")\n"; }                         # addreq <keyname>
addreq_l() { req "Action: add\nLabel: $2\nKey: $(kl "$1")\n"; }           # addreq_l <keyname> <label>
rmreq() { req "Action: remove\nFingerprint: $(fpof "$1")\nConfirm: yes\n"; }

# apply_as <full owner|""> : one handler run. APPLY_BIN overrides the script.
apply_as() {
    ( unset BBS_KEYS_JOURNAL_CMD BBS_TEST_OWNER
      export BBS_ROOT=$root BASHBBS_TEST=1 BBS_LOCK_WAIT=${LOCKW:-5}
      [[ -n $1 ]] && export BBS_TEST_OWNER=$1
      [[ -n ${JCMD:-} ]] && export BBS_KEYS_JOURNAL_CMD=$JCMD
      nice -n 19 "${APPLY_BIN:-$APPLY}" ) >>"$root/run.out" 2>&1
}
apply() { apply_as "bbs-$1"; }

# jset <name:keyname>...  journal lines for the accepted-publickey records
jset() {
    local pair; : > "$root/journal.txt"
    for pair in "$@"; do
        printf '2026-10-29T12:00:00+0000 zero sshd[123]: Accepted publickey for bbs-%s from 192.168.1.5 port 5555 ssh2: ED25519 %s\n' \
            "${pair%%:*}" "$(fpof "${pair#*:}")" >> "$root/journal.txt"
    done
    JCMD="cat $root/journal.txt"
}

cli() { ( unset BBS_ROOT BASHBBS_TEST; export BBS_ROOT=$root BASHBBS_TEST=1 BBS_LOCK_WAIT=${LOCKW:-5}; nice -n 19 "$CLI" "$@" ) >>"$root/run.out" 2>&1; }
cli_o() { ( export BBS_ROOT=$root BASHBBS_TEST=1 BBS_LOCK_WAIT=${LOCKW:-5}; nice -n 19 "$CLI" "$@" ) 2>&1; }

kf()   { cat "$root/keys/bbs-$1"; }
nkf()  { grep -c . "$root/keys/bbs-$1"; }
sumk() { sha256sum "$root/keys/bbs-$1" | cut -d' ' -f1; }
res_last() { tail -n 1 "$root/state/keys-results/$1" 2>/dev/null; }
res_status() { res_last "$1" | cut -f5; }
res_reason() { res_last "$1" | cut -f6; }
res_n() { grep -c . "$root/state/keys-results/$1" 2>/dev/null || echo 0; }
rejected_n() { find "$root/drop/rejected" -type f -o -type l 2>/dev/null | grep -c .; }
queue_n() { find "$root/queue/keys" -mindepth 1 -not -name '.*' | grep -c .; }   # dotfiles are never picked up
rejected_all() { ls -A "$root/drop/rejected" 2>/dev/null | wc -l; }
meta_field() { # meta_field <name> <keyname> <col>
    awk -F'\t' -v fp="$(fpof "$2")" -v c="$3" '$1 == fp { print $c }' "$root/users/$1/keys.meta"
}

# Every key file holds only "type body" lines (no options, no labels, no comments).
kf_clean() {
    local f bad=0 line
    for f in "$root"/keys/bbs-*; do
        [[ -s $f ]] || { echo "empty or missing $f"; return 1; }
        while IFS= read -r line; do
            [[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)\ [A-Za-z0-9+/]+={0,2}$ ]] \
                || { echo "dirty line in $f: ${line:0:40}"; bad=1; }
        done < "$f"
    done
    ls "$root"/keys/.bbs-*.new >/dev/null 2>&1 && { echo "leftover .new"; bad=1; }
    return $bad
}
# keys.meta rows: 6 fields, same count as the key file
meta_ok() {
    local n=$1 rows
    rows=$(awk -F'\t' 'NF == 6 && $1 ~ /^SHA256:/' "$root/users/$n/keys.meta" | wc -l)
    [[ $rows == "$(nkf "$n")" ]]
}

# ---------------------------------------------------------------- 1. bbs-keycheck
kc() { printf '%s' "$1" | "$KEYCHECK" "${@:2}" 2>/dev/null; }
kc_is() { # kc_is <desc> <"OK"|"ERR code"> <raw input> [flags]
    local d=$1 want=$2 in=$3 out got; shift 3
    out=$(printf '%s' "$in" | "$KEYCHECK" "$@" 2>>"$log")
    got=$(head -n 1 <<< "$out" | cut -f1,2 | tr '\t' ' ')
    [[ $got == OK* ]] && got=OK
    check "keycheck: $d" eq "$got" "$want"
    has "$out" 'SECRETMARK' && { echo "FAIL keycheck: $d echoes input" | tee -a "$log"; fail=$((fail + 1)); }
}
K_ED=$(kl a1); BODY=$(kbody a1)
kc_is "ed25519 ok" OK "$K_ED"
kc_is "ed25519 with comment and newline" OK "$K_ED comment here"$'\n'
kc_is "CRLF line ending tolerated" OK "$K_ED"$'\r\n'
kc_is "ecdsa 256" OK "$(kl e256)"
kc_is "ecdsa 384" OK "$(kl e384)"
kc_is "ecdsa 521" OK "$(kl e521)"
kc_is "sk-ssh-ed25519" OK "$(kl sk1)"
kc_is "rsa 2048" OK "$(kl r2048)"
out=$(kc "$(kfull a1)" ); check "keycheck: output is canonical, comment dropped" eq "$out" "$(printf 'OK\tssh-ed25519\t%s\t%s\t256' "$BODY" "$(fpof a1)")"
out=$(kc "$K_ED command=\"SECRETMARK\" from=\"1.2.3.4\"")
check "keycheck: options after the body are dropped (comment)" eq "$(cut -f1,2 <<< "$out" | tr '\t' ' ')" "OK ssh-ed25519"
kc_is "empty" "ERR empty" ""
kc_is "only newline" "ERR empty" $'\n'
kc_is "only spaces" "ERR empty" "   "
kc_is "two lines" "ERR multiline" "$K_ED"$'\n'"$(kl a2)"$'\n'
kc_is "second line is junk" "ERR multiline" "$K_ED"$'\n'"SECRETMARK"$'\n'
kc_is "leading blank line then key" "ERR multiline" $'\n'"$K_ED"
kc_is "CR in the middle" "ERR multiline" "$K_ED"$'\r'"SECRETMARK"
kc_is "control char in comment" "ERR multiline" "$K_ED"$'\x01'"SECRETMARK"
printf 'ssh-ed25519 %s\0SECRETMARK\n' "$BODY" > "$top/nul.in"
out=$("$KEYCHECK" < "$top/nul.in"); check "keycheck: NUL byte" eq "$(cut -f1,2 <<< "$out" | tr '\t' ' ')" "ERR multiline"
printf '\0\0\0\0' > "$top/nul2.in"
out=$("$KEYCHECK" < "$top/nul2.in"); check "keycheck: only NULs" has "$out" '^ERR'
kc_is "4097 chars" "ERR toolong" "ssh-ed25519 $(head -c 4085 /dev/zero | tr '\0' A)"
kc_is "9000 bytes" "ERR toolong" "ssh-ed25519 $(head -c 9000 /dev/zero | tr '\0' A)"
kc_is "exactly 4096 chars passes the length rule" "ERR mismatch" "ssh-ed25519 $(head -c 4084 /dev/zero | tr '\0' A)"
kc_is "-----BEGIN private key" "ERR private-key" $'-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETMARK\n-----END OPENSSH PRIVATE KEY-----\n'
kc_is "BEGIN RSA PRIVATE KEY on one line" "ERR private-key" "-----BEGIN RSA PRIVATE KEY----- SECRETMARK"
kc_is "private key after a public line" "ERR private-key" "$K_ED"$'\n-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETMARK'
kc_is "PRIVATE KEY in the comment" "ERR private-key" "$K_ED my PRIVATE KEY"
kc_is "PuTTY .ppk header" "ERR private-key" $'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nSECRETMARK\n'
kc_is "ssh-dss" "ERR type" "ssh-dss AAAAB3NzaC1kc3MAAAA= SECRETMARK"
kc_is "random words" "ERR type" "foo bar SECRETMARK"
kc_is "ecdsa-sha2-nistp999" "ERR type" "ecdsa-sha2-nistp999 $BODY"
kc_is "command= prefix" "ERR option" "command=\"/bin/sh SECRETMARK\" $K_ED"
kc_is "from= prefix" "ERR option" "from=\"10.0.0.1\" $K_ED"
kc_is "no-pty prefix" "ERR option" "no-pty $K_ED"
kc_is "several options" "ERR option" "no-pty,no-port-forwarding,command=\"SECRETMARK\" $K_ED"
kc_is "environment= prefix" "ERR option" "environment=\"A=SECRETMARK\" $K_ED"
kc_is "permitopen= prefix" "ERR option" "permitopen=\"x:1\" $K_ED"
kc_is "option with spaces in quotes" "ERR option" "command=\"ls -l\" $K_ED"
kc_is "cert type" "ERR cert" "$(cut -d' ' -f1,2 "$K/u-cert.pub")"
kc_is "cert behind an option" "ERR option" "command=\"x\" $(cut -d' ' -f1,2 "$K/u-cert.pub")"
kc_is "ssh-rsa-cert-v01" "ERR cert" "ssh-rsa-cert-v01@openssh.com $BODY"
kc_is "body not base64 (!)" "ERR base64" "ssh-ed25519 !!!!SECRETMARK"
kc_is "body length not multiple of 4" "ERR base64" "ssh-ed25519 ${BODY:0:50}"
kc_is "body with comma-option tail" "ERR base64" "ssh-ed25519 $BODY,command=SECRETMARK"
kc_is "body only padding" "ERR base64" "ssh-ed25519 ===="
kc_is "no body" "ERR base64" "ssh-ed25519"
kc_is "valid base64 but not a key blob" "ERR mismatch" "$(cut -d' ' -f1,2 "$K/junk.pub")"
kc_is "truncated key blob" "ERR keygen" "$(cut -d' ' -f1,2 "$K/trunc.pub")"
kc_is "ed25519 type with rsa body" "ERR mismatch" "ssh-ed25519 $(kbody r2048)"
kc_is "ssh-rsa type with ed25519 body" "ERR mismatch" "ssh-rsa $BODY"
kc_is "nistp256 type with 521 body" "ERR mismatch" "ecdsa-sha2-nistp256 $(kbody e521)"
kc_is "nistp521 type with 256 body" "ERR mismatch" "ecdsa-sha2-nistp521 $(kbody e256)"
kc_is "rsa 1024 refused" "ERR rsa-short" "$(kl r1024)"
kc_is "rsa 1024 refused even with --legacy" "ERR rsa-short" "$(kl r1024)" --legacy
kc_is "rsa 2047 refused" "ERR rsa-short" "$(kl r2047)"
kc_is "rsa 2047 refused even with --legacy" "ERR rsa-short" "$(kl r2047)" --legacy
kc_is "rsa 1536 needs LEGACY" "ERR legacy-needed" "$(kl r1536a)"
kc_is "rsa 1536 with --legacy" OK "$(kl r1536a)" --legacy
printf '%s\n' "$(kl r1536a)" | "$KEYCHECK" >/dev/null 2>&1; check "keycheck: legacy-needed exits 2" eq "$?" 2
printf '%s\n' "$(kl r1024)" | "$KEYCHECK" >/dev/null 2>&1; check "keycheck: other errors exit 1" eq "$?" 1
printf '%s\n' "$K_ED" | "$KEYCHECK" >/dev/null 2>&1; check "keycheck: ok exits 0" eq "$?" 0
out=$(kc "$(kl r1536a)"); check "keycheck: legacy text mentions SyncTERM and LEGACY" has "$out" 'SyncTERM 1.9 uses 1536: type LEGACY'
# labels
kl_is() { local d=$1 want=$2 in=$3 out; out=$(printf '%s' "$in" | "$KEYCHECK" --label 2>/dev/null); check "label: $d" eq "$(head -n 1 <<< "$out" | cut -f1,2 | tr '\t' ' ' | sed 's/^OK .*/OK/')" "$want"; }
kl_is "plain" OK "Laptop 1"
kl_is "dots dashes underscores" OK "a.b_c-d"
kl_is "20 chars" OK "12345678901234567890"
kl_is "21 chars" "ERR label" "123456789012345678901"
kl_is "empty" "ERR label" ""
kl_is "traversal ../../x" "ERR label" "../../x"
kl_is "slash" "ERR label" "a/b"
kl_is "newline inside" "ERR label" $'a\nb'
kl_is "tab" "ERR label" $'a\tb'
kl_is "command substitution" "ERR label" '$(touch x)'
kl_is "backticks" "ERR label" '`id`'
kl_is "non-ascii" "ERR label" "caf"$'\xc3\xa9'
kl_is "semicolon" "ERR label" "a;b"
printf 'ab\0cd' | "$KEYCHECK" --label >"$top/lab.out" 2>/dev/null; check "label: NUL" has "$(cat "$top/lab.out")" '^ERR'
printf 'Laptop\r\n' | "$KEYCHECK" --label >"$top/lab.out" 2>/dev/null; check "label: trailing CRLF tolerated" eq "$(cat "$top/lab.out")" "$(printf 'OK\tLaptop')"
printf 'x' | "$KEYCHECK" --bogus >/dev/null 2>&1; check "keycheck: unknown flag exits 64" eq "$?" 64
sed -n 1p "$KEYCHECK" >/dev/null

# ---------------------------------------------------------------- 2. owner binding
newroot
SUM_A=$(sumk alice); SUM_B=$(sumk bob)
for hdr in "Account: bbs-bob" "User: bob" "Path: ../../keys/bbs-bob" "Name: bob" "account: bbs-bob" "Owner: bbs-bob"; do
    req "Action: add\n$hdr\nKey: $(kl a2)\n"
done
req "Action: add\nKey: $(kl a2)\nKey: $(kl a3)\n"          # two Key headers
req "Action: add\nAction: remove\nKey: $(kl a2)\n"         # two Action headers
req "Action: nuke\nKey: $(kl a2)\n"
req "Action: add\nKey: $(kl a2)\nLegacy: maybe\n"
req "Action: add\nKey: $(kl a2)\nFingerprint: $(fpof b1)\n"
req "Action: add\r\nKey: $(kl a2)\r\n"                     # CRLF request file
req "Action: add\nKey: $(kl a2)\n\0Action: remove\n"       # NUL in the request
req "Action: add\nKey: $(kl a2)\n\xc3\xa9"                 # non-ASCII
req ""                                                     # empty request
apply alice
check "forged/odd headers: every request failed" eq "$(awk -F'\t' '$5 == "failed"' "$root/state/keys-results/alice" | wc -l)" "$REQN"
check "forged headers: all reasons are 'Malformed request.'" eq "$(awk -F'\t' '$6 == "Malformed request."' "$root/state/keys-results/alice" | wc -l)" "$REQN"
check "forged headers: alice's key file unchanged" eq "$(sumk alice)" "$SUM_A"
check "forged headers: bob's key file unchanged" eq "$(sumk bob)" "$SUM_B"
check "forged headers: no result file for bob" test ! -e "$root/state/keys-results/bob"
check "forged headers: queue empty" eq "$(queue_n)" 0
check "forged headers: key file still clean" kf_clean

req "Action: remove\nFingerprint: $(fpof b1)\nConfirm: yes\n"; apply alice
check "alice cannot remove bob's key (not found)" eq "$(res_reason alice)" "Key not found."
check "not-found reply does not mention bob" lacks "$(res_last alice)" 'bob'
req "Action: rename\nFingerprint: $(fpof b1)\nLabel: stolen\n"; apply alice
check "alice cannot rename bob's key" eq "$(res_reason alice)" "Key not found."
check "bob's file still unchanged" eq "$(sumk bob)" "$SUM_B"
check "bob has no keys.meta change" test ! -s "$root/users/bob/keys.meta" -o "$(grep -c stolen "$root/users/bob/keys.meta" 2>/dev/null)" = 0

# symlink / hardlink / odd files
ln -s "$root/keys/bbs-bob" "$root/queue/keys/00009001-rlink.keys"
printf 'Action: add\nKey: %s\n' "$(kl a4)" > "$root/t/real.keys"
ln -s "$root/t/real.keys" "$root/queue/keys/00009002-rlink.keys"
printf 'Action: add\nKey: %s\n' "$(kl a5)" > "$root/t/h.keys"; ln "$root/t/h.keys" "$root/queue/keys/00009003-rhard.keys"
printf 'Action: add\nKey: %s\n' "$(kl a6)" > "$root/queue/keys/not_an_id.keys"
printf 'Action: add\nKey: %s\n' "$(kl a6)" > "$root/queue/keys/1-has space.keys"
printf 'Action: add\nKey: %s\n' "$(kl a6)" > "$root/queue/keys/.hidden.keys"
mkdir "$root/queue/keys/00009004-rdir.keys"
mkfifo "$root/queue/keys/00009005-rfifo.keys"
head -c 9000 /dev/zero | tr '\0' ' ' > "$root/queue/keys/00009006-rbig.keys"
before=$(rejected_all); n_before=$(nkf alice)
timeout 20 bash -c 'true'; ( apply alice )
check "symlink/hardlink/dir/fifo/bad name/oversize: key files unchanged" eq "$(sumk alice)$(sumk bob)" "$SUM_A$SUM_B"
check "symlink/hardlink/dir/fifo/bad name/oversize: rejected, not processed" eq "$(( $(rejected_all) - before ))" 8
check "rejected files leave the queue (dotfile is ignored, left alone)" eq "$(queue_n):$(ls -A "$root/queue/keys")" "0:.hidden.keys"
check "symlink target (bob's key file) intact after reject" eq "$(sumk bob)" "$SUM_B"
check "symlinked request target survives and was not applied" test -f "$root/t/real.keys"
check "binding failures give no result rows for others" test ! -e "$root/state/keys-results/bob"
check "binding rejection is logged" grep -q 'rejected' "$root/state/keys.log"

# other owners: refused by name or shell
for ow in bbs-news bbs-ab bbs-ALICE "bbs-../x" bbs-alice-x root "bbs-a b" bbs-abcdefghij ""; do
    addreq a7; b=$(rejected_n)
    apply_as "$ow"
    check "owner '${ow:-<uid without bbs-shell>}' refused, nothing written" eq "$(( $(rejected_n) - b )):$(sumk alice):$(sumk bob)" "1:$SUM_A:$SUM_B"
done
check "owner refusals: no results rows anywhere" eq "$(ls -A "$root/state/keys-results" | wc -l)" 1   # only alice's from above
check "owner bbs-news: news key file never created" test ! -e "$root/keys/bbs-news"

# valid name, no key file
addreq a2; apply_as bbs-carol
check "unknown account: failed, not created" eq "$(cat "$root/state/keys-results/carol" | cut -f5,6)" "$(printf 'failed\tAccount key file missing.')"
check "unknown account: no key file or user dir" eq "$(ls "$root/keys/" | tr '\n' ' ')" "bbs-alice bbs-bob "

# modification during processing (wrapper keycheck swaps the file after the copy)
mkdir -p "$top/swap/sbin" "$top/swap/lib"
cp "$APPLY" "$top/swap/sbin/bbs-keys-apply"; cp "$here/lib/keys-common.sh" "$top/swap/lib/"
cat > "$top/swap/sbin/bbs-keycheck" <<EOF
#!/bin/bash
if [[ -n \${SWAP_ACTION:-} && ! -e \$SWAP_DONE ]]; then : > "\$SWAP_DONE"; eval "\$SWAP_ACTION"; fi
exec "$KEYCHECK" "\$@"
EOF
chmod +x "$top/swap/sbin/"*
swap_run() { # swap_run <action> ; the request file is \$SWAP_FILE
    ( export SWAP_ACTION=$1 SWAP_DONE=$root/t/swapdone SWAP_FILE=$root/queue/keys/$LASTID.keys SWAP_ROOT=$root KEYSRC=$K
      rm -f "$SWAP_DONE" 2>/dev/null; rm -f "$root/t/swapdone"
      APPLY_BIN=$top/swap/sbin/bbs-keys-apply apply alice )
}
newroot; SUM_B=$(sumk bob)
addreq_l a2 Orig
swap_run 'printf "Action: add\nLabel: Evil\nKey: %s\n" "$(cut -d" " -f1,2 "$KEYSRC/a3.pub")" > "$SWAP_FILE"'
check "in-place edit during processing: the copy (original request) is applied" eq "$(kf alice | cut -d' ' -f2 | grep -cF "$(kbody a2)")" 1
check "in-place edit during processing: edited content is not applied" eq "$(kf alice | grep -cF "$(kbody a3)")" 0
check "in-place edit: result row names the original label" has "$(res_last alice)" 'Orig'
newroot; SUM_B=$(sumk bob)
addreq_l a2 Orig
swap_run 'rm -f "$SWAP_FILE"; printf "Action: add\nLabel: Swapped\nKey: %s\n" "$(cut -d" " -f1,2 "$KEYSRC/a3.pub")" > "$SWAP_FILE"'
check "replaced file during processing: original applied" eq "$(kf alice | grep -cF "$(kbody a2)")" 1
check "replaced file during processing: new file not applied in this run" eq "$(kf alice | grep -cF "$(kbody a3)")" 0
check "replaced file during processing: the new file is not deleted" test -e "$root/queue/keys/$LASTID.keys"
apply alice
check "replaced file is handled normally by the next run" eq "$(kf alice | grep -cF "$(kbody a3)")" 1
newroot; SUM_B=$(sumk bob)
addreq_l a2 Orig
swap_run 'rm -f "$SWAP_FILE"; ln -s "$SWAP_ROOT/keys/bbs-bob" "$SWAP_FILE"'
check "file swapped for a symlink: bob's key file intact" eq "$(sumk bob)" "$SUM_B"
check "file swapped for a symlink: the link itself is not followed/deleted by the handler" test -L "$root/queue/keys/$LASTID.keys"
apply alice
check "symlink left in queue is rejected next run, bob intact" eq "$(rejected_n):$(sumk bob)" "1:$SUM_B"
check "key file clean after swaps" kf_clean

# traversal in label / name, shell metacharacters in key comment
newroot; SUM_B=$(sumk bob)
for lab in '../../x' 'a/b' '/etc/passwd' '$(touch PWN)' '`touch PWN`' 'a;touch PWN' 'x y z 123456789012345678901'; do
    addreq_l a2 "$lab"; apply alice
    check "bad label '$lab' refused" eq "$(res_status alice):$(res_reason alice)" "failed:Invalid name."
done
kl_dots=1
check "label '..' is valid per contract regex but only ever a TSV field, not a path" eq "$(printf '..' | "$KEYCHECK" --label | cut -f1)" OK
check "label traversal: key file unchanged" eq "$(nkf alice)" 1
check "label traversal: nothing created outside the tree" eq "$(find "$root" "$top" -maxdepth 3 \( -name x -o -name 'PWN*' -o -name pwned \) | wc -l)" 0
req "Action: add\nLabel: Ok\nKey: $(kl a2) \$(touch $root/pwned) \`touch $root/pwned2\`\n"; apply alice
check "shell metacharacters in the comment: accepted as plain key" eq "$(res_status alice)" done
check "shell metacharacters in the comment: not executed" eq "$(ls "$root"/pwned* 2>/dev/null | wc -l)" 0
check "comment never reaches the key file" eq "$(kf alice | grep -c 'touch')" 0
check "key file clean after label/comment injection" kf_clean

# ---------------------------------------------------------------- 3. validation through the handler (one batch)
newroot; SUM_A=$(sumk alice); SUM_B=$(sumk bob)
declare -a CASES=() CDESC=()
case_add() { CDESC+=("$1"); CASES+=("$2"); }
case_add "command= option" "command=\"/bin/sh SECRETMARK\" $(kl a2)"
case_add "from= option" "from=\"1.2.3.4\" $(kl a2)"
case_add "no-pty option" "no-pty $(kl a2)"
case_add "environment= option" "environment=\"A=B\" $(kl a2)"
case_add "cert" "$(cut -d' ' -f1,2 "$K/u-cert.pub")"
case_add "ssh-dss" "ssh-dss AAAAB3NzaC1kc3M="
case_add "rsa 1024" "$(kl r1024)"
case_add "rsa 2047" "$(kl r2047)"
case_add "wrong type vs body" "ssh-rsa $(kbody a2)"
case_add "bad base64" "ssh-ed25519 !!!!"
case_add "truncated blob" "$(cut -d' ' -f1,2 "$K/trunc.pub")"
case_add "BEGIN private key" "-----BEGIN OPENSSH PRIVATE KEY-----"
case_add "PRIVATE KEY comment" "$(kl a2) PRIVATE KEY"
case_add "PuTTY key" "PuTTY-User-Key-File-3: ssh-ed25519"
case_add "4100 chars" "ssh-ed25519 $(head -c 4090 /dev/zero | tr '\0' A)"
case_add "empty key" " "
case_add "tab separated junk" $'ssh-ed25519\t!!'
for i in "${!CASES[@]}"; do req "Action: add\nKey: ${CASES[$i]}\n"; done
apply alice
for i in "${!CASES[@]}"; do
    row=$(sed -n "$((i + 1))p" "$root/state/keys-results/alice")
    check "handler refuses: ${CDESC[$i]}" has "$row" $'\tfailed\t'
done
check "handler refusals: no row echoes input" eq "$(grep -c 'SECRETMARK\|BEGIN\|PuTTY' "$root/state/keys-results/alice" "$root/state/keys.log" | awk -F: '{s+=$2} END {print s+0}')" 0
check "handler refusals: alice and bob unchanged" eq "$(sumk alice)$(sumk bob)" "$SUM_A$SUM_B"
check "handler refusals: queue empty" eq "$(queue_n)" 0
check "handler refusals: nothing in history (no write happened)" eq "$(ls "$root/state/keys-history" | wc -l)" 0
# a good key with option-looking comment and odd spacing
req "Action: add\nLabel: Good one\nKey:    x\n"; apply alice    # leading spaces/value is not a key
check "key value that is not a key: failed" eq "$(res_status alice)" failed
req "Action: add\nLabel: Good one\nKey: $(kl a2)  command=\"id\" no-pty\n"; apply alice
check "comment with options: key added without it" eq "$(res_status alice)" done
check "added key line is exactly 'type body'" eq "$(kf alice | tail -n 1)" "$(kl a2)"
check "label not in the key file" eq "$(kf alice | grep -c 'Good')" 0
check "label kept in keys.meta" eq "$(meta_field alice a2 2)" "Good one"
check "meta source is self" eq "$(meta_field alice a2 4)" self
check "registration key is labelled registration" eq "$(meta_field alice a1 2):$(meta_field alice a1 4)" "registration:registration"
check "registration key date from profile created=" eq "$(meta_field alice a1 3)" "2026-10-01T00:00:00Z"
check "new key starts untested (seen -)" eq "$(meta_field alice a2 5)" "-"
check "meta rows match key file" meta_ok alice
check "key file clean" kf_clean
for t in e256 e384 e521 sk1 r2048; do
    addreq_l $t "T $t"; apply alice
    check "type accepted: $t" eq "$(res_status alice)" done
done
check "key file clean with all key types" kf_clean
check "meta rows match key file (all types)" meta_ok alice

# ---------------------------------------------------------------- 4. RSA 1536 legacy flow
newroot
addreq_l r1536a Sync; apply alice
check "1536 without LEGACY refused" eq "$(res_status alice)" failed
check "1536 refusal tells the user to type LEGACY" has "$(res_reason alice)" 'LEGACY'
check "1536 refusal: key file unchanged" eq "$(nkf alice)" 1
req "Action: add\nLabel: Sync\nLegacy: yes\nKey: $(kl r1536a)\n"; apply alice
check "1536 with Legacy: yes accepted" eq "$(res_status alice)" done
check "legacy flag in meta" eq "$(meta_field alice r1536a 6)" 1
check "legacy acceptance logged" grep -q 'legacy-accepted' "$root/state/keys.log"
req "Action: add\nLabel: Sync2\nLegacy: yes\nKey: $(kl r1536b)\n"; apply alice
check "second 1536 key refused" eq "$(res_status alice):$(res_reason alice)" "failed:Only one legacy key per account."
req "Action: add\nLabel: L24\nLegacy: yes\nKey: $(kl r1024)\n"; apply alice
check "1024 with Legacy: still refused" eq "$(res_status alice)" failed
req "Action: add\nLabel: L47\nLegacy: yes\nKey: $(kl r2047)\n"; apply alice
check "2047 with Legacy: still refused" eq "$(res_status alice)" failed
req "Action: add\nLabel: Ed\nLegacy: yes\nKey: $(kl a2)\n"; apply alice
check "Legacy: yes on an ed25519 key: accepted, not counted legacy" eq "$(res_status alice):$(meta_field alice a2 6)" "done:0"
req "Action: add\nLabel: R2k\nLegacy: yes\nKey: $(kl r2048)\n"; apply alice
check "Legacy: yes on rsa 2048: not counted legacy" eq "$(res_status alice):$(meta_field alice r2048 6)" "done:0"
printf 'ALLOW_LEGACY_RSA_1536=no\n' > "$root/etc/keys.conf"
req "Action: add\nLabel: Sync3\nLegacy: yes\nKey: $(kl r1536c)\n"; apply bob
check "keys.conf ALLOW_LEGACY_RSA_1536=no: new legacy key refused" eq "$(cut -f5,6 "$root/state/keys-results/bob" | tail -n 1)" "$(printf 'failed\tLegacy RSA keys are turned off.')"
check "keys.conf no: existing legacy key stays" eq "$(grep -cF "$(kbody r1536a)" "$root/keys/bbs-alice")" 1
check "keys.conf no: existing legacy key stays marked" eq "$(meta_field alice r1536a 6)" 1
printf '# comment\nALLOW_LEGACY_RSA_1536=yes\n$(touch %s/pwned)\n`touch %s/pwned2`\nALLOW_LEGACY_RSA_1536=no ; touch %s/pwned3\n' "$root" "$root" "$root" > "$root/etc/keys.conf"
req "Action: add\nLabel: Sync3\nLegacy: yes\nKey: $(kl r1536c)\n"; apply bob
check "keys.conf parsed, never sourced (no command ran)" eq "$(ls "$root"/pwned* 2>/dev/null | wc -l)" 0
check "keys.conf yes with junk lines: legacy allowed" eq "$(res_status bob)" done
check "key file clean after legacy flow" kf_clean

# ---------------------------------------------------------------- 5. duplicates and the 8-key limit
newroot; SUM_B=$(sumk bob)
addreq a1; apply alice
check "own duplicate refused" eq "$(res_status alice):$(res_reason alice)" "failed:Key already added."
req "Action: add\nKey: $(kl a1) a-different-comment\n"; apply alice
check "own duplicate with other comment refused" eq "$(res_status alice)" failed
addreq b1; apply alice
check "key of another account refused" eq "$(res_status alice):$(res_reason alice)" "failed:Key already in use."
check "other-account refusal does not say whose" lacks "$(res_last alice)" 'bob|bbs-'
req "Action: add\nKey: $(kl b1) bob\n"; apply alice
check "other-account duplicate via comment variant: same reply" eq "$(res_reason alice)" "Key already in use."
check "the holder is only in the root log" grep -q 'in-use-by-other:bbs-bob' "$root/state/keys.log"
check "duplicates: bob untouched" eq "$(sumk bob)" "$SUM_B"
for n in a2 a3 a4 a5 a6 a7 a8; do addreq $n; done
apply alice
check "up to 8 keys accepted" eq "$(nkf alice)" 8
addreq a9; apply alice
check "9th key refused with limit text" eq "$(res_status alice):$(res_reason alice)" "failed:Key limit reached (8). Remove one first."
check "limit: still 8 keys" eq "$(nkf alice)" 8
check "limit: key file clean" kf_clean
check "limit: meta rows match" meta_ok alice

# ---------------------------------------------------------------- 6. last-key protection (fail-closed)
newroot
addreq_l a2 Second; apply alice
A1=$(sumk alice)
rmreq a1; JCMD=; apply alice
check "journal hook missing (unreadable): remove refused" eq "$(res_status alice):$(res_reason alice)" "failed:Login history unavailable. Try later or ask the sysop."
JCMD="exit 1"; rmreq a1; apply alice
check "journal command fails: remove refused" eq "$(res_reason alice)" "Login history unavailable. Try later or ask the sysop."
JCMD="true"; rmreq a1; apply alice
check "journal readable but no 'seen': remove refused" eq "$(res_status alice):$(res_reason alice)" "failed:Log in with another key first, so it is tested."
jset alice:a1; rmreq a1; apply alice
check "seen only for the key being removed: refused" eq "$(res_status alice)" failed
jset bob:a2; rmreq a1; apply alice
check "journal line for another account with this fingerprint: not counted" eq "$(res_status alice)" failed
printf '2026-10-29T12:00:00+0000 zero sshd[1]: Failed publickey for bbs-alice from 1.2.3.4 port 5 ssh2: ED25519 %s\n2026-10-29T12:00:00+0000 zero sshd[1]: Accepted password for bbs-alice from 1.2.3.4 port 5 ssh2: ED25519 %s\ngarbage Accepted publickey for bbs-alice x\n' "$(fpof a2)" "$(fpof a2)" > "$root/journal.txt"
JCMD="cat $root/journal.txt"; rmreq a1; apply alice
check "failed/other journal records do not count as seen" eq "$(res_status alice)" failed
check "refusals leave the key file as it was" eq "$(sumk alice)" "$A1"
jset alice:a2
req "Action: remove\nFingerprint: $(fpof a1)\n"; apply alice
check "journal ok but Confirm missing: refused" eq "$(res_status alice):$(res_reason alice)" "failed:Removal was not confirmed."
check "seen is stored in meta from the journal" eq "$(meta_field alice a2 5)" "2026-10-29T12:00:00Z"
check "unconfirmed: key file unchanged" eq "$(sumk alice)" "$A1"
req "Action: remove\nFingerprint: $(fpof b1)\nConfirm: yes\n"; apply alice
check "remove a key that is not alice's: not found" eq "$(res_reason alice)" "Key not found."
req "Action: remove\nFingerprint: SHA256:short\nConfirm: yes\n"; apply alice
check "remove with malformed fingerprint: not found" eq "$(res_reason alice)" "Key not found."
req "Action: remove\nFingerprint: $(fpof a1)\nConfirm: no\n"; apply alice
check "Confirm: no is a malformed request" eq "$(res_reason alice)" "Malformed request."
rmreq a1; apply alice
check "success path (seen on remaining key, confirmed): removed" eq "$(res_status alice):$(nkf alice)" "done:1"
check "success path: remaining key is a2" eq "$(kf alice)" "$(kl a2)"
check "success path: history copy made (0600)" eq "$(stat -c %a "$root"/state/keys-history/alice-* | sort -u | tr '\n' ' ')" "600 "
check "success path: newest history file holds both old keys" eq "$(cat "$(ls -t "$root"/state/keys-history/alice-* | head -n 1)" | wc -l)" 2
rmreq a2; apply alice
check "the last key can never be removed (even tested)" eq "$(res_status alice):$(res_reason alice)" "failed:This is your last key. It cannot be removed."
check "last key still present" eq "$(kf alice)" "$(kl a2)"
check "key file clean" kf_clean

# ---------------------------------------------------------------- 7. results, rename, retention, modes
newroot
addreq_l a2 One; apply alice
row=$(res_last alice)
check "result row has 6 tab fields" eq "$(awk -F'\t' '{print NF}' <<< "$row")" 6
check "result row id matches the request id" eq "$(cut -f1 <<< "$row")" "$LASTID"
check "result row time is ISO UTC" has "$(cut -f2 <<< "$row")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
check "result row action/label/status" eq "$(cut -f3-5 <<< "$row")" "$(printf 'add\tOne\tdone')"
check "results dir 755, file 644" eq "$(stat -c %a "$root/state/keys-results"):$(stat -c %a "$root/state/keys-results/alice")" "755:644"
check "key file, meta 644" eq "$(stat -c %a "$root/keys/bbs-alice"):$(stat -c %a "$root/users/alice/keys.meta")" "644:644"
check "keys.log 600, history dir 700" eq "$(stat -c %a "$root/state/keys.log"):$(stat -c %a "$root/state/keys-history")" "600:700"
req "Action: rename\nFingerprint: $(fpof a2)\nLabel: Work PC\n"; S=$(sumk alice); apply alice
check "rename done" eq "$(res_status alice)" done
check "rename changes meta only" eq "$(meta_field alice a2 2):$(sumk alice)" "Work PC:$S"
req "Action: rename\nFingerprint: $(fpof a2)\nLabel: ../x\n"; apply alice
check "rename to a bad label refused" eq "$(res_status alice):$(meta_field alice a2 2)" "failed:Work PC"
req "Action: rename\nFingerprint: $(fpof a2)\nKey: $(kl a3)\nLabel: x\n"; apply alice
check "rename with a Key header is malformed" eq "$(res_reason alice)" "Malformed request."
check "all result rows match the contract format" eq "$(awk -F'\t' 'NF == 6 && $1 ~ /^[0-9]+-[A-Za-z0-9]+$/ && ($5 == "done" || $5 == "failed")' "$root/state/keys-results/alice" | wc -l)" "$(res_n alice)"
for i in $(seq 1 55); do req "Action: bogus\n"; done
apply alice
check "results keep at most 50 rows" eq "$(res_n alice)" 50
check "newest row is the last request" eq "$(res_last alice | cut -f1)" "$LASTID"
check "pending request is detectable (file stays queued while locked)" true
check "labels never appear in the key file" eq "$(grep -c 'Work\|One' "$root/keys/bbs-alice")" 0

# ---------------------------------------------------------------- 8. concurrency
# Two handler runs at once (same account, 8 requests): each request exactly once.
newroot
for n in a2 a3 a4 a5 a6 a7; do addreq $n; done
( apply alice & apply alice & wait )
check "two simultaneous handler runs: 6 rows, 7 keys" eq "$(res_n alice):$(nkf alice)" "6:7"
check "two simultaneous runs: no duplicate lines" eq "$(kf alice | sort | uniq -d | wc -l)" 0
check "two simultaneous runs: queue empty, files clean, meta matches" eq "$(queue_n)$(kf_clean >/dev/null 2>&1; echo $?)$(meta_ok alice; echo $?)" "000"
# lock held elsewhere: the handler waits LOCKW then leaves the queue alone
newroot
touch "$root/state/keys.lock"; addreq a2
( flock 9; sleep 4 ) 9>>"$root/state/keys.lock" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$root/state/keys.lock" true 2>/dev/null || break; sleep 0.2; done
LOCKW=1 apply alice
check "lock busy: handler gives up, request stays queued, key file unchanged" eq "$(queue_n):$(nkf alice)" "1:1"
check "lock busy: sysop CLI fails too" rc_not0 env LOCKW=1 bash -c "export BBS_ROOT='$root' BASHBBS_TEST=1 BBS_LOCK_WAIT=1; '$CLI' add alice '$K/a3.pub'"
check "lock busy: CLI add changed nothing" eq "$(nkf alice)" 1
wait "$holder"
apply alice
check "after the lock is free the request is handled" eq "$(res_status alice):$(nkf alice)" "done:2"
# Two accounts at once: a patched copy takes the account from the request id (the test
# hook can only map one owner per run); the rest of the handler is the unchanged script.
mkdir -p "$top/pat/sbin" "$top/pat/lib"; cp "$KEYCHECK" "$top/pat/sbin/"; cp "$here/lib/keys-common.sh" "$top/pat/lib/"
python3 - "$APPLY" "$top/pat/sbin/bbs-keys-apply" <<'PY'
import sys
s = open(sys.argv[1]).read()
fn = 'acct_by_id() { local x=${1#*-}; x=${x#r}; printf "%s\\n" "${x%%[0-9]*}"; }\n'
s = s.replace("handle_file() {", fn + "handle_file() {", 1)
s = s.replace('name=$(account_of_uid "$uid")', 'name=$(acct_by_id "$id")', 1)
open(sys.argv[2], "w").write(s)
PY
chmod +x "$top/pat/sbin/bbs-keys-apply"
check "patched copy carries the id-based owner" grep -q 'acct_by_id "\$id"' "$top/pat/sbin/bbs-keys-apply"
for round in 1 2 3; do
    newroot
    i=0
    for n in a2 a3 a4; do i=$((i + 1)); reqid "$(printf '%08d-ralice%d' $i $i)" "Action: add\nLabel: A$i\nKey: $(kl $n)\n"; done
    for n in b2 b3 b4; do i=$((i + 1)); reqid "$(printf '%08d-rbob%d' $i $i)" "Action: add\nLabel: B$i\nKey: $(kl $n)\n"; done
    reqid "00000009-ralice9" "Action: add\nKey: $(kl b2)\n"        # alice asks for bob's new key (race for ownership)
    ( APPLY_BIN=$top/pat/sbin/bbs-keys-apply apply alice & APPLY_BIN=$top/pat/sbin/bbs-keys-apply apply bob & wait )
    check "two accounts at once (round $round): 4+4 keys" eq "$(nkf alice):$(nkf bob)" "4:4"
    check "two accounts at once (round $round): each key only in its own file" eq "$(grep -cF "$(kbody b2)" "$root/keys/bbs-alice")$(grep -cF "$(kbody a2)" "$root/keys/bbs-bob")" "00"
    check "two accounts at once (round $round): results complete" eq "$(res_n alice)/$(res_n bob)" "4/3"
    check "two accounts at once (round $round): clean, meta matches, queue empty" eq "$(kf_clean >/dev/null 2>&1; echo $?)$(meta_ok alice; echo $?)$(meta_ok bob; echo $?)$(queue_n)" "0000"
    check "two accounts at once (round $round): alice's grab of bob's key refused" eq "$(grep -c "00000009-ralice9.*failed" "$root/state/keys-results/alice")" 1
done

# ---------------------------------------------------------------- 9. sysop CLI
newroot
SUMB=$(sumk bob)
out=$(cli_o list alice); check "list: shows alice's fingerprint" hasf "$out" "$(fpof a1)"
check "list: shows the registration label" has "$out" 'registration'
check "list: never prints key bodies" lacks "$out" "$(kbody a1)"
check "list: single account only" lacks "$out" 'bbs-bob'
out=$(cli_o list); check "list (all): both accounts" eq "$(grep -c '^bbs-' <<< "$out")" 2
check "list: invalid name refused" rc_not0 cli list '../x'
check "list: news refused" rc_not0 cli list news
check "list: unknown account fails" rc_not0 cli list nobody
check "CLI refuses /srv/bashbbs in test mode" rc_not0 env BBS_ROOT=/srv/bashbbs BASHBBS_TEST=1 "$CLI" list
check "CLI needs root outside test mode" rc_not0 env -u BASHBBS_TEST BBS_ROOT="$root" "$CLI" list
check "handler needs root outside test mode" rc_not0 env -u BASHBBS_TEST BBS_ROOT="$root" "$APPLY"
check "handler refuses /srv/bashbbs in test mode" rc_not0 env BBS_ROOT=/srv/bashbbs BASHBBS_TEST=1 "$APPLY"
check "no usage: exit 64" rc_is 64 cli
check "unknown command: exit 64" rc_is 64 cli frobnicate
# add
check "add: ok with label" rc_is 0 cli add alice "$K/a2.pub" --label Laptop
check "add: key file got exactly type+body" eq "$(kf alice | tail -n 1)" "$(kl a2)"
check "add: meta label, source sysop, untested" eq "$(meta_field alice a2 2):$(meta_field alice a2 4):$(meta_field alice a2 5)" "Laptop:sysop:-"
check "add: logged without the key body" eq "$(grep -cF "$(kbody a2)" "$root/state/keys.log")" 0
check "add: log row says done sysop" has "$(tail -n 1 "$root/state/keys.log")" $'\tadd\t.*\tdone\tsysop'
check "add: history copy made" eq "$(ls "$root/state/keys-history" | wc -l)" 1
check "add: duplicate on same account refused" rc_not0 cli add alice "$K/a2.pub"
check "add: key of another account refused" rc_not0 cli add alice "$K/b1.pub"
check "add: bob unchanged" eq "$(sumk bob)" "$SUMB"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETMARK\n-----END OPENSSH PRIVATE KEY-----\n' > "$root/t/priv"
check "add: private key refused" rc_not0 cli add alice "$root/t/priv"
printf 'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n' > "$root/t/ppk"
check "add: PuTTY file refused" rc_not0 cli add alice "$root/t/ppk"
{ kl a3; kl a4; } > "$root/t/two"; check "add: two keys in the file refused" rc_not0 cli add alice "$root/t/two"
{ printf 'command="id" '; kl a3; } > "$root/t/opt"; check "add: option prefix refused" rc_not0 cli add alice "$root/t/opt"
cut -d' ' -f1,2 "$K/u-cert.pub" > "$root/t/cert"; check "add: certificate refused" rc_not0 cli add alice "$root/t/cert"
kl r1024 > "$root/t/r1024"; check "add: rsa 1024 refused, also with --legacy" rc_not0 cli add alice "$root/t/r1024" --legacy
kl r2047 > "$root/t/r2047"; check "add: rsa 2047 refused, also with --legacy" rc_not0 cli add alice "$root/t/r2047" --legacy
check "add: label traversal refused" rc_not0 cli add alice "$K/a3.pub" --label '../x'
check "add: label 21 chars refused" rc_not0 cli add alice "$K/a3.pub" --label 123456789012345678901
check "add: unknown option refused" rc_not0 cli add alice "$K/a3.pub" --bogus
check "add: missing file refused" rc_not0 cli add alice "$root/t/none"
ln -s "$K/a3.pub" "$root/t/lnk"; check "add: symlink file refused" rc_not0 cli add alice "$root/t/lnk"
for nm in news nobody '../bob' 'bbs-alice' ALICE ab; do check "add: bad/unknown account '$nm' refused" rc_not0 cli add "$nm" "$K/a3.pub"; done
check "add: rejected adds left the key file as is" eq "$(nkf alice)" 2
check "add: 1536 without --legacy refused" rc_not0 cli add alice "$K/r1536a.pub"
check "add: 1536 with --legacy ok" rc_is 0 cli add alice "$K/r1536a.pub" --legacy --label Sync
check "add: legacy flag in meta" eq "$(meta_field alice r1536a 6)" 1
check "add: second legacy key refused" rc_not0 cli add alice "$K/r1536b.pub" --legacy
printf 'ALLOW_LEGACY_RSA_1536=no\n' > "$root/etc/keys.conf"
check "add: keys.conf no blocks --legacy" rc_not0 cli add bob "$K/r1536c.pub" --legacy
rm_conf=1; : > "$root/etc/keys.conf"
for n in a3 a4 a5 a6 a7; do cli add alice "$K/$n.pub" >/dev/null; done
check "add: up to 8 keys" eq "$(nkf alice)" 8
check "add: 9th key refused" rc_not0 cli add alice "$K/a8.pub"
check "add: key file clean" kf_clean
check "add: meta rows match" meta_ok alice
# remove
check "remove: invalid fingerprint refused (even --force)" rc_not0 cli remove alice 'SHA256:short' --force
check "remove: unknown fingerprint refused (even --force)" rc_not0 cli remove alice "SHA256:$(head -c 43 /dev/zero | tr '\0' A)" --force
check "remove: other account's fingerprint refused" rc_not0 cli remove alice "$(fpof b1)" --force
check "remove: unknown option refused" rc_not0 cli remove alice "$(fpof a3)" --bogus
check "remove without seen on any key refused" rc_not0 cli remove alice "$(fpof a3)"
check "remove refusal: still 8 keys" eq "$(nkf alice)" 8
jset alice:a2; apply alice            # no queue entries: only the journal pass sets `seen`
check "journal pass sets seen" eq "$(meta_field alice a2 5)" "2026-10-29T12:00:00Z"
check "remove with a tested key left: ok" rc_is 0 cli remove alice "$(fpof a3)"
check "remove: gone from the file" eq "$(grep -cF "$(kbody a3)" "$root/keys/bbs-alice")" 0
check "remove: removing a2 leaves untested keys only -> refused without --force" rc_not0 cli remove alice "$(fpof a2)"
out=$(cli_o remove alice "$(fpof a2)" --force); check "remove --force works" has "$out" 'forced'
check "--force is logged as such" has "$(tail -n 1 "$root/state/keys.log")" $'remove\t.*\tdone\tsysop-force'
check "remove: key file clean" kf_clean
# --force never removes the last key
newroot
check "--force on the last key refused" rc_not0 cli remove alice "$(fpof a1)" --force
check "last key still there" eq "$(kf alice)" "$(kl a1)"
check "the refusal is logged" has "$(tail -n 1 "$root/state/keys.log")" 'failed'

# ---------------------------------------------------------------- 10. history rollback
newroot
A0=$(sumk alice)
addreq_l a2 Two; addreq_l a3 Three; apply alice
check "rollback setup: 3 keys" eq "$(nkf alice)" 3
H=$(ls "$root"/state/keys-history/alice-* | head -n 1)
check "history file is the pre-change file" eq "$(sha256sum < "$H")" "$(echo "$A0" | sed 's/.*//' >/dev/null; printf '%s\n' "$(kl a1)" | sha256sum)"
check "history file mode 600" eq "$(stat -c %a "$H")" 600
check "restore: refuses a file outside keys-history" rc_not0 cli restore alice "$root/keys/bbs-alice"
check "restore: refuses traversal out of keys-history" rc_not0 cli restore alice "../keys/bbs-bob"
check "restore: refuses another account's history file" rc_not0 cli restore alice "bob-20260101T000000Z"
cp "$H" "$root/state/keys-history/bob-20261231T000000Z"; check "restore: refuses bob's history file for alice" rc_not0 cli restore alice "$root/state/keys-history/bob-20261231T000000Z"
ln -s "$H" "$root/state/keys-history/alice-linkhist"; check "restore: refuses a symlink history file" rc_not0 cli restore alice "alice-linkhist"
{ printf 'command="id" '; kl a5; } > "$root/state/keys-history/alice-evil1"; check "restore: refuses a history file with an option line" rc_not0 cli restore alice alice-evil1
printf '%s\n%s\n' "$(kl a5) with comment" "$(kl a6)" > "$root/state/keys-history/alice-evil2"; check "restore: refuses lines that are not exactly type+body" rc_not0 cli restore alice alice-evil2
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n' > "$root/state/keys-history/alice-evil3"; check "restore: refuses private key material" rc_not0 cli restore alice alice-evil3
: > "$root/state/keys-history/alice-empty"; check "restore: refuses an empty history file" rc_not0 cli restore alice alice-empty
kl b1 > "$root/state/keys-history/alice-stolen"; check "restore: refuses a key that belongs to another account" rc_not0 cli restore alice alice-stolen
for n in a1 a2 a3 a4 a5 a6 a7 a8 a9; do kl $n; done > "$root/state/keys-history/alice-nine"; check "restore: refuses more than 8 keys" rc_not0 cli restore alice alice-nine
check "restore refusals left the file as it was" eq "$(nkf alice)" 3
check "restore refusals: bob untouched" eq "$(kf bob)" "$(kl b1)"
nh=$(ls "$root/state/keys-history" | wc -l)
check "restore: ok from the real history file" rc_is 0 cli restore alice "$(basename "$H")"
check "restore: key file is back to the old content" eq "$(kf alice)" "$(kl a1)"
check "restore: previous file saved to history first" eq "$(( $(ls "$root/state/keys-history" | wc -l) - nh ))" 1
check "restore: meta matches, key file clean" eq "$(meta_ok alice; echo $?)$(kf_clean >/dev/null 2>&1; echo $?)" "00"
check "restore: the registration label survives" eq "$(meta_field alice a1 2)" registration
check "restore: logged" grep -q 'restore.*done.*sysop-from-' "$root/state/keys.log"
H2=$(ls -t "$root"/state/keys-history/alice-2* | head -n 1)
check "restore: roll forward again from the newest history file" rc_is 0 cli restore alice "$(basename "$H2")"
check "roll forward: 3 keys again" eq "$(nkf alice)" 3
check "roll forward: labels of dropped keys are gone (meta follows the file), meta consistent" eq "$(meta_field alice a2 2):$(meta_ok alice; echo $?)" "key:0"

# ---------------------------------------------------------------- 11. nothing leaks, parity
leak=0
for r in "${roots[@]}"; do
    for n in $ALLNAMES; do
        b=$(kbody $n)
        for f in "$r"/state/keys.log "$r"/state/keys-results/* "$r"/users/*/keys.meta "$r/run.out"; do
            [[ -f $f ]] && grep -qF -- "$b" "$f" && { echo "LEAK key body of $n in $f"; leak=1; }
        done
    done
done
check "no key body in logs, results, meta or tool output (all scenarios)" eq "$leak" 0
check "no scenario touched /srv/bashbbs" test ! -e /srv/bashbbs/state/keys.log -o -n "$(find /srv/bashbbs/state/keys.log -newer "$K/a1" 2>/dev/null; echo)"

parity() {
python3 - "$here" <<'PY'
import re, sys
h = sys.argv[1]
cgi = open(h + "/web/apply.cgi").read()
prov = open(h + "/sbin/bbs-provision").read()
kc = open(h + "/sbin/bbs-keycheck").read()
ok = True
def say(m):
    global ok; ok = False; print("PARITY:", m)
t_cgi = set(re.findall(r'"([a-z0-9@.-]+)"', re.search(r"KEY_TYPES = \{(.*?)\}", cgi, re.S).group(1)))
m = re.search(r'case \$keytype in\s*\n\s*([^)]*)\)', prov)
t_prov = set(m.group(1).split("|"))
t_kc = set(re.search(r'KEY_TYPES="([^"]*)"', kc).group(1).split())
if not (t_cgi == t_prov == t_kc and len(t_cgi) == 6):
    say("type lists differ: cgi=%s prov=%s keycheck=%s" % (sorted(t_cgi), sorted(t_prov), sorted(t_kc)))
# base64 alphabet: same character set in all three (padding rules may differ in strictness)
alpha = "A-Za-z0-9+/"
if alpha not in re.search(r"KEY_BODY_RE = re.compile\(r\"(.*?)\"\)", cgi).group(1): say("apply.cgi base64 alphabet")
if alpha not in re.search(r'\$keyb64 =~ (\S+)', prov).group(1): say("bbs-provision base64 alphabet")
if alpha not in re.search(r'\$body =~ (\S+)', kc).group(1): say("bbs-keycheck base64 alphabet")
cgi_ok = re.compile(re.search(r"KEY_BODY_RE = re.compile\(r\"(.*?)\"\)", cgi).group(1))
kc_re = re.compile(re.search(r'\$body =~ (\S+)', kc).group(1).replace("[[", "["))
for ch in map(chr, range(32, 127)):
    a = bool(cgi_ok.match("QUJD" + ch)); b = bool(re.match(r"^[A-Za-z0-9+/]+={0,2}$", "QUJD" + ch))
    if a != b and ch != "=":
        say("base64 alphabet differs on %r" % ch)
# size limit 4096
l_cgi = int(re.search(r"MAX_BODY = (\d+)", cgi).group(1))
l_prov = int(re.search(r'stat -c %s "\$keyfile"\) -lt (\d+)', prov).group(1))
l_kc = int(re.search(r"MAX_LINE=(\d+)", kc).group(1))
if not (l_cgi == l_prov == l_kc == 4096): say("limits differ: %s %s %s" % (l_cgi, l_prov, l_kc))
print("parity ok" if ok else "parity FAILED")
sys.exit(0 if ok else 1)
PY
}
check "parity: type list, base64 alphabet and 4096 limit identical in apply.cgi, bbs-provision, bbs-keycheck" parity
# behavioural parity: every listed type passes the type gate, nothing else does
tp=ok
for t in ssh-ed25519 ssh-rsa ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 sk-ssh-ed25519@openssh.com; do
    out=$(printf '%s AAAA\n' "$t" | "$KEYCHECK" 2>/dev/null | cut -f2)
    [[ $out == type || $out == option || $out == cert ]] && tp="$t rejected as $out"
done
check "keycheck passes the type gate for every listed type" eq "$tp" ok
for t in ssh-dss ecdsa-sha2-nistp224 ssh-ed448 sk-ecdsa-sha2-nistp256@openssh.com; do
    out=$(printf '%s AAAA\n' "$t" | "$KEYCHECK" 2>/dev/null | cut -f2)
    check "keycheck rejects type $t" eq "$out" type
done

echo
echo "keys_test: $pass passed, $fail failed (log: $log, trees: $top)" | tee -a "$log"
[[ $fail -eq 0 ]]
