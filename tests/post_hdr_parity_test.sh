#!/bin/bash
# post_hdr parity: the old sed|sed|head|safe pipeline (kept here only as the oracle) against
# hdr_read and the new post_hdr, byte for byte, on generated header files and every key
# used in lib/*.sh. Usage: tests/post_hdr_parity_test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hdrparity.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/meta" "$work/home"
export BBS_ROOT=$work/root HOME=$work/home BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-hdrparity
source "$here/lib/menu.sh"
set +e +u +o pipefail 2>/dev/null

old_post_hdr() { sed '/^$/q' "$1" | sed -n "s/^$2: *//p" | head -n 1 | safe; }

keys=(Subject Msgid Author Date Parent Deleted From Message-ID To Board Subjects X-Subject Msgid2 Msgi Subject2)
i=0
mk() { i=$((i + 1)); printf '%b' "$1" > "$work/f$i"; }
mk ''
mk 'Subject: a\n'
mk 'Subject: a'
mk 'Subject: a\r\nMsgid: m1\r\nAuthor: x\r\n\r\nSubject: body\r\n'
mk 'Subject: a\n\r\nMsgid: m1\n\nMsgid: body\n'
mk 'Subject: a\nMsgid: m1\nAuthor: x'
mk 'Subject: first\nSubject: second\nMsgid: a\nMsgid: b\n\nSubject: body\n'
mk 'Subject:nospace\nMsgid:\nAuthor:   many spaces  \nDate:\ttab\n'
mk 'Subject:\tTab\nMsgid: \t tab after space\n'
mk 'Subjects: plural\nX-Subject: prefixed\nSubject2: two\nSubject: real\n'
mk 'Subjects: plural\nX-Subject: prefixed\n'
mk 'Msgid2: x\nMsgi: y\nMessage-ID: <a@b>\nMsgid: z\n'
mk 'Message-ID: <a@b>\nFrom: bob@host\nTo: a\n'
mk 'Subject: esc\033[31mred\033[0m bell\007 cr\r end\n'
mk 'Subject: del\177x\nMsgid: c0\001\002\037y\n'
mk 'Subject: c1 \xc2\x80\xc2\x85\xc2\x9f end\nAuthor: nbsp\xc2\xa0x\n'
mk 'Subject: bad \xff\xfe utf8 \xc3 end\nAuthor: \xe2\x82 trunc\n'
mk 'Subject: nul\0inside\nMsgid: ok\n'
# Known limit: a NUL right after the spaces ("Subject: \0 x") differs; bash drops NUL on read. Posts never contain one.
mk 'Subject: åäö ÅÄÖ\nAuthor: emoji \xf0\x9f\x98\x80 here\n'
mk 'Subject: a: b: c\nDate: 2026-10-01T10:00:00Z\n'
mk 'subject: lower\nSUBJECT: upper\nSubject : spaced\n Subject: indented\n'
mk 'Subject: a\n\n\n\nMsgid: x\n'
mk '\nSubject: after blank first\n'
mk '\r\nSubject: crlf blank first\n'
mk 'Deleted: 1\nSubject: gone\n\nbody\n'
mk 'Deleted:\nSubject: x\n'
mk 'Subject: has * and [x] and . regex chars\nMessage-ID: <a.b@c>\n'
mk 'Sub.ect: dot\nSubXect: x\n'
mk 'Subject: trailing space  \nMsgid: x \r\n'
mk 'no colon line\nSubject: after\n'
mk ': empty key\nSubject: y\n'
mk 'Author: a\r\n\r\nFrom: body\r\n'
# random mixes
for r in $(seq 1 60); do
    s=""
    for l in $(seq 1 $((RANDOM % 7))); do
        case $((RANDOM % 14)) in
            0) s+="Subject: s$RANDOM\\n" ;; 1) s+="Msgid:$RANDOM\\n" ;; 2) s+="Author:  \\t$RANDOM\\r\\n" ;;
            3) s+="\\n" ;; 4) s+="\\r\\n" ;; 5) s+="Parent: \\033[1m$RANDOM\\n" ;; 6) s+="Subject: \\xc2\\x9b$RANDOM\\xff\\n" ;;
            7) s+="Message-ID: <$RANDOM>\\n" ;; 8) s+="From: \\x7f$RANDOM\\n" ;; 9) s+="Date: åäö $RANDOM\\n" ;;
            10) s+="Deleted:\\n" ;; 11) s+="Subjects: $RANDOM\\n" ;; 12) s+="To:$RANDOM" ;; 13) s+="x\\n" ;;
        esac
    done
    mk "$s"
done
total=$i; cases=0; bad=0
for n in $(seq 1 "$total"); do
    f=$work/f$n
    hdr_read "$f"
    for k in "${keys[@]}"; do
        cases=$((cases + 1))
        # Compared as callers see it, inside $( ): old sed prints no newline after a last line that has none.
        o=$(old_post_hdr "$f" "$k" 2>/dev/null)
        w=$(post_hdr "$f" "$k")
        if [[ -v HDR[$k] ]]; then h=${HDR[$k]}; else h=; fi
        if [[ $o != "$w" || $o != "$h" ]]; then
            bad=$((bad + 1)); echo "MISMATCH file $n key $k"; printf '  old %q\n  wrp %q\n  hdr %q\n' "$o" "$w" "$h"
            od -c "$f" | head -5
        fi
    done
done
# missing file: quiet, empty
cases=$((cases + 1)); [[ -z $(post_hdr "$work/none" Subject 2>&1) ]] || { bad=$((bad + 1)); echo "MISMATCH missing file"; }
echo "post_hdr parity: $cases cases, $bad mismatches"
exit $((bad > 0))
