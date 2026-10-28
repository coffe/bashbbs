#!/bin/bash
# Tests for edit-post and delete-post in sbin/bbs-publish. Every run uses its
# own BBS_ROOT under the scratchpad. Without root there are no real accounts or
# groups: the owner is passed in, or stubbed with ASOWNER for process(), and
# private membership comes from test-groups. Chgrp is stubbed too.
# Usage: tests/boards_edit_test.sh [logfile]   (full log in the file; the
# screen shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/d1734d7a-ba5d-4ad7-aeee-cb0f3089f2e5/scratchpad}
log=${1:-$scratch/boards_edit_test.log}
: > "$log"
pass=0; fail=0

check() { # check <description> <command...>
    local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi
}
eq() { [[ $1 == "$2" ]]; }

newroot() {
    root=$(mktemp -d "$scratch/bed.XXXXXX")
    mkdir -p "$root"/{boards/general,boards/news,boards/priv,meta,queue/incoming,state,drop/rejected,lib,t}
    cp "$here/lib/news-categories.conf" "$root/lib/"
    : > "$root/meta/news.readonly"
    printf 'owner=alice\n' > "$root/meta/priv.meta"
    printf 'carol\n' > "$root/sysops"
    printf 'bbs-alice bbsb-priv\nbbs-bob bbsb-priv\nbbs-dave bbsb-priv\nbbs-carol bbsb-priv\n' > "$root/test-groups"
    seq=0
}

# Run one publisher function in a subshell with the script sourced.
lib() {
    ( export BBS_ROOT="$root" BBS_LOCK_WAIT="${LOCKW:-2}"
      # shellcheck disable=SC1090
      source "$here/sbin/bbs-publish"
      in_group() { grep -qxF "$1 $2" "$root/test-groups" 2>/dev/null; }
      chgrp() { return 0; }
      stat() { if [[ ${1:-} == -c && ${2:-} == %U ]]; then echo "${ASOWNER:-}"; else command stat "$@"; fi; }
      "$@" ) >>"$log" 2>&1
}

hval() { sed '/^$/q' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
digest() { sha256sum < "$1" | cut -c1-64; }

# mkpost <board> <owner> <body>: creates a post through handle_post, sets MP to its file.
mkpost() {
    local n=$((seq + 1)) f
    seq=$n
    f=$root/t/post$n.post
    printf 'Board: %s\nSubject: Rubrik %s\n\n%s\n' "$1" "$n" "$3" > "$f"
    lib handle_post "$f" "$2" || return 1
    MP=$(grep -l "^Subject: Rubrik $n\$" "$root"/boards/"$1"/*.msg)
}

# req <name> <action> <board> <msgid> [subject] (body on stdin): sets RQ to the request file.
req() {
    RQ=$root/t/$1.req
    {
        printf 'Action: %s\nBoard: %s\nMsgid: %s\n' "$2" "$3" "$4"
        if [[ -n ${5:-} ]]; then printf 'Subject: %s\n' "$5"; fi
        printf '\n'
        cat
    } > "$RQ"
}

# ---- A. public board: edit, delete, history, admin backup, moderation -------
newroot
mkpost general bbs-alice $'första raden åäö\nandra raden'; A=$MP
id=$(hval "$A" Msgid)
posted=$(hval "$A" Date)
check "post: public file mode 0644" eq "$(stat -c %a "$A")" 644
check "post: no Edited header yet" eq "$(hval "$A" Edited)" ""

req e1 edit-post general "$id" "Ny rubrik" <<< $'ny text åäö\nandra rad'
lib handle_req "$RQ" bbs-alice; check "edit by author: accepted" eq $? 0
check "edit: same file name" test -f "$A"
check "edit: Msgid kept" eq "$(hval "$A" Msgid)" "$id"
check "edit: Author kept" eq "$(hval "$A" Author)" alice
check "edit: Date kept" eq "$(hval "$A" Date)" "$posted"
check "edit: Edited set" test -n "$(hval "$A" Edited)"
check "edit: new subject" eq "$(hval "$A" Subject)" "Ny rubrik"
check "edit: new body" grep -qxF 'ny text åäö' "$A"
check "edit: mode 0644 kept" eq "$(stat -c %a "$A")" 644
hist=$root/state/history/general/$id
check "history: state/history is 0700" eq "$(stat -c %a "$root/state/history")" 700
check "history: board dir 0700" eq "$(stat -c %a "$root/state/history/general")" 700
check "history: post dir 0700" eq "$(stat -c %a "$hist")" 700
check "history: first version saved as 1-*.msg" compgen -G "$hist/1-*.msg"
check "history: file 0600" eq "$(stat -c %a "$hist"/1-*.msg)" 600
check "history: old body kept" grep -qxF 'andra raden' "$hist"/1-*.msg
check "history: old subject kept" grep -qxF 'Subject: Rubrik 1' "$hist"/1-*.msg
check "edit: no tmp left in board" bash -c '! compgen -G "$1/.tmp.*"' _ "$root/boards/general"

req e2 edit-post general "$id" "Ny rubrik två" <<< 'tredje version'
lib handle_req "$RQ" bbs-alice; check "second edit: accepted" eq $? 0
check "history: second version saved as 2-*.msg" compgen -G "$hist/2-*.msg"
check "edit: body is latest" grep -qxF 'tredje version' "$A"

D=$(digest "$A")
req e3 edit-post general "$id" "Stulen rubrik" <<< 'bob ändrar'
lib handle_req "$RQ" bbs-bob; check "edit by other user: rejected" eq $? 1
check "edit by other user: file unchanged" eq "$(digest "$A")" "$D"

req e4 edit-post general "$id" "x" < /dev/null
lib handle_req "$RQ" bbs-alice; check "edit with empty body: rejected" eq $? 1
req e5 edit-post general "$id" "" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "edit with empty subject: rejected" eq $? 1
req e6 edit-post general "$id" "Rubrik" <<< "$(head -c 12000 /dev/zero | tr '\0' a)"
lib handle_req "$RQ" bbs-alice; check "edit with body over MAX_BODY: rejected" eq $? 1
req e7 edit-post general "$(cat /proc/sys/kernel/random/uuid)" "Rubrik" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "edit unknown Msgid: rejected" eq $? 1
req e8 edit-post general "abc" "Rubrik" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "edit malformed Msgid: rejected" eq $? 1
req e9 edit-post ../etc "$id" "Rubrik" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "edit with path in Board: rejected" eq $? 1
check "edit rejects left the post as it was" eq "$(digest "$A")" "$D"

# Two files with the same Msgid: the glob must find exactly one, so no edit.
mkpost general bbs-alice "dubbel"; DUB=$MP
dubid=$(hval "$DUB" Msgid)
cp "$DUB" "$root/boards/general/9999999999-$dubid.msg"
req e10 edit-post general "$dubid" "Rubrik" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "two files with one Msgid: rejected" eq $? 1

req d1 delete-post general "$id" < /dev/null
lib handle_req "$RQ" bbs-bob; check "delete by other user: rejected" eq $? 1
check "delete by other user: post still shown" eq "$(hval "$A" Subject)" "Ny rubrik två"

req d2 delete-post general "$id" < /dev/null
lib handle_req "$RQ" bbs-alice; check "delete by author: accepted" eq $? 0
check "delete: subject [raderat]" eq "$(hval "$A" Subject)" "[raderat]"
check "delete: Deleted set" test -n "$(hval "$A" Deleted)"
check "delete: Msgid kept" eq "$(hval "$A" Msgid)" "$id"
check "delete: Author kept" eq "$(hval "$A" Author)" alice
check "delete: Date kept" eq "$(hval "$A" Date)" "$posted"
check "delete: body is empty" eq "$(sed '1,/^$/d' "$A" | wc -c)" 0
check "delete: no mod.log for own post" test ! -e "$root/state/mod.log"
check "admin backup: state/admin-backup is 0700" eq "$(stat -c %a "$root/state/admin-backup")" 700
bk=$(compgen -G "$root/state/admin-backup/*-general-$id.msg")
check "admin backup: file exists" test -n "$bk"
check "admin backup: file 0600" eq "$(stat -c %a "$bk")" 600
check "admin backup: first line Backup-Of" grep -qxF "Backup-Of: $id" <(head -n 1 "$bk")
check "admin backup: holds the text before deletion" grep -qxF 'tredje version' "$bk"

req e11 edit-post general "$id" "Försök" <<< 'text'
lib handle_req "$RQ" bbs-alice; check "edit of a deleted stub: rejected" eq $? 1
req d3 delete-post general "$id" < /dev/null
lib handle_req "$RQ" bbs-alice; check "delete of a deleted stub: rejected" eq $? 1

# Moderation: the sysop deletes another user's post and it is logged.
mkpost general bbs-bob "bobs inlägg"; BP=$MP
bid=$(hval "$BP" Msgid)
req d4 delete-post general "$bid" < /dev/null
lib handle_req "$RQ" bbs-carol; check "sysop deletes other's post: accepted" eq $? 0
check "mod.log: mode 0600" eq "$(stat -c %a "$root/state/mod.log")" 600
check "mod.log: line with moderator, board and Msgid" grep -qF $'\tcarol\tgeneral\t'"$bid" "$root/state/mod.log"
check "moderated post: stub" eq "$(hval "$BP" Subject)" "[raderat]"

# A request with a Board header for a missing board or a board that is not a directory.
req d5 delete-post nobody "$bid" < /dev/null
lib handle_req "$RQ" bbs-carol; check "missing board: rejected" eq $? 1

# Read-only board (news): posts there cannot be changed by anyone.
mkpost news bbs-news "nyhet"; NP=$MP
nid=$(hval "$NP" Msgid)
req e12 edit-post news "$nid" "Ändrad" <<< 'text'
lib handle_req "$RQ" bbs-news; check "edit on read-only news: rejected" eq $? 1
req d6 delete-post news "$nid" < /dev/null
lib handle_req "$RQ" bbs-carol; check "delete on read-only news: rejected" eq $? 1

# Queue path: process() reads the owner from the file, quarantines rejects and
# removes accepted requests. The owner is stubbed with ASOWNER.
mkpost general bbs-alice "köläge"; QP=$MP
qid=$(hval "$QP" Msgid)
req q1 edit-post general "$qid" "Via kön" <<< 'via kön'
cp "$RQ" "$root/queue/incoming/q1.req"
ASOWNER=bbs-bob lib process "$root/queue/incoming/q1.req"
check "queue: foreign edit goes to quarantine" test -f "$root/drop/rejected/q1.req"
check "queue: foreign edit leaves the queue" test ! -e "$root/queue/incoming/q1.req"
check "queue: post unchanged after foreign edit" eq "$(hval "$QP" Subject)" "Rubrik $seq"
req q2 edit-post general "$qid" "Via kön" <<< 'via kön'
cp "$RQ" "$root/queue/incoming/q2.req"
ASOWNER=bbs-alice lib process "$root/queue/incoming/q2.req"
check "queue: author edit is applied" eq "$(hval "$QP" Subject)" "Via kön"
check "queue: accepted request removed from queue" test ! -e "$root/queue/incoming/q2.req"

# ---- B. private board: membership, owner, sysop, former member -------------
newroot
mkpost priv bbs-alice "hemligt"; PA=$MP
pid=$(hval "$PA" Msgid)
check "private post: mode 0640" eq "$(stat -c %a "$PA")" 640
req p1 edit-post priv "$pid" "Ändrad" <<< 'ändrat'
lib handle_req "$RQ" bbs-bob; check "private: non-author member cannot edit" eq $? 1
req p2 delete-post priv "$pid" < /dev/null
lib handle_req "$RQ" bbs-dave; check "private: member cannot delete owner's post" eq $? 1
req p3 edit-post priv "$pid" "Utifrån" <<< 'utifrån'
lib handle_req "$RQ" bbs-eve; check "private: non-member cannot edit" eq $? 1
req p4 edit-post priv "$pid" "Ändrad" <<< 'ändrat av ägaren'
lib handle_req "$RQ" bbs-alice; check "private: author member can edit" eq $? 0
check "private: edit kept mode 0640" eq "$(stat -c %a "$PA")" 640

mkpost priv bbs-bob "bobs hemliga"; PB=$MP
bpid=$(hval "$PB" Msgid)
req p5 delete-post priv "$bpid" < /dev/null
lib handle_req "$RQ" bbs-alice; check "private: board owner deletes member's post" eq $? 0
mkpost priv bbs-bob "bob igen"; PC=$MP
cpid=$(hval "$PC" Msgid)
req p6 delete-post priv "$cpid" < /dev/null
lib handle_req "$RQ" bbs-carol; check "private: sysop deletes member's post" eq $? 0
check "private: sysop deletion logged" grep -qF $'\tcarol\tpriv\t'"$cpid" "$root/state/mod.log"

mkpost priv bbs-bob "bob lämnar"; PD=$MP
did=$(hval "$PD" Msgid)
sed -i '/bbs-bob bbsb-priv/d' "$root/test-groups"
req p7 edit-post priv "$did" "Efter" <<< 'efter utträde'
lib handle_req "$RQ" bbs-bob; check "private: former member cannot edit own post" eq $? 1

# ---- C. lock timeout: the request stays in the queue for a retry -----------
newroot
mkpost general bbs-alice "lås"; LP=$MP
lid=$(hval "$LP" Msgid)
marker=$root/t/locked
( exec 9>>"$root/state/news.lock"; flock 9; touch "$marker"; sleep 6 ) &
lockpid=$!
while [[ ! -e $marker ]]; do sleep 0.1; done
req l1 edit-post general "$lid" "Låst" <<< 'låst text'
cp "$RQ" "$root/queue/incoming/l1.req"
LOCKW=1 lib handle_req "$RQ" bbs-alice; check "lock timeout: handle_req returns 2" eq $? 2
LOCKW=1 ASOWNER=bbs-alice lib process "$root/queue/incoming/l1.req"
check "lock timeout: process keeps the request" test -f "$root/queue/incoming/l1.req"
check "lock timeout: post unchanged" eq "$(hval "$LP" Subject)" "Rubrik $seq"
wait "$lockpid"
LOCKW=2 ASOWNER=bbs-alice lib process "$root/queue/incoming/l1.req"
check "after the lock: request applied and removed" test ! -e "$root/queue/incoming/l1.req"
check "after the lock: subject is the new one" eq "$(hval "$LP" Subject)" "Låst"

# ---- F. two edits at once: the ledger lock serialises them ------------------
newroot
mkpost general bbs-alice "samtid"; CP=$MP
cid=$(hval "$CP" Msgid)
orig=$(hval "$CP" Subject)
req c1 edit-post general "$cid" "Först" <<< 'första text'
cp "$RQ" "$root/queue/incoming/c1.req"
req c2 edit-post general "$cid" "Sist" <<< 'andra text'
cp "$RQ" "$root/queue/incoming/c2.req"
( ASOWNER=bbs-alice lib process "$root/queue/incoming/c1.req" ) &
( ASOWNER=bbs-alice lib process "$root/queue/incoming/c2.req" ) &
wait
check "concurrent: both requests removed" test ! -e "$root/queue/incoming/c1.req" -a ! -e "$root/queue/incoming/c2.req"
check "concurrent: two history versions" eq "$(ls "$root/state/history/general/$cid" | wc -l)" 2
check "concurrent: history 1 holds the original" grep -qxF "Subject: $orig" "$root/state/history/general/$cid"/1-*.msg
check "concurrent: post is one of the two edits" eq "$(hval "$CP" Subject | grep -cxE 'Först|Sist')" 1
check "concurrent: no temp files left" eq "$(ls -a "$root/boards/general" | grep -c '^\.tmp\.')" 0

# ---- D. menu (lib/menu.sh): commands under a post, width -------------------
# menuf <user> <function> [args]: runs a menu function as bbs-<user>, input on stdin.
menuf() {
    local u=$1; shift
    mkdir -p "$root/home/bbs-$u"
    ( export BBS_ROOT="$root" USER="bbs-$u" HOME="$root/home/bbs-$u" BASHBBS_TEST=1
      source "$here/lib/menu.sh"
      "$@" ) >>"$log" 2>&1
}
queued() { ls "$root/queue/incoming" | grep -c '\.req$'; }
sent() { local f; f=$(ls "$root/queue/incoming" | grep '\.req$' | head -n 1); [[ -n $f ]] && mv "$root/queue/incoming/$f" "$root/t/"; }
maxlen() { python3 -I -c 'import sys; print(max([len(l.rstrip("\n")) for l in open(sys.argv[1], encoding="utf-8")] or [0]))' "$1"; }

newroot
mkpost general bbs-alice "menyens text"; A=$MP
printf 'e\nNy rubrik\nb\n' | menuf alice post_actions general "$A"
check "menu: author edit, text kept: one request" eq "$(queued)" 1
RQ=$(ls "$root"/queue/incoming/*.req)
check "menu: request is edit-post" grep -qxF 'Action: edit-post' "$RQ"
check "menu: request has the new subject" grep -qxF 'Subject: Ny rubrik' "$RQ"
check "menu: kept text is the old body" grep -qxF 'menyens text' "$RQ"
sent
printf 'e\n\nn\nny text rad\n.\n' | menuf alice post_actions general "$A"
check "menu: author edit, new text: one request" eq "$(queued)" 1
RQ=$(ls "$root"/queue/incoming/*.req)
check "menu: Enter keeps the old subject" grep -qxF "Subject: $(hval "$A" Subject)" "$RQ"
check "menu: new text in request" grep -qxF 'ny text rad' "$RQ"
sent
printf 'e\n\nn\n.\n' | menuf alice post_actions general "$A"
check "menu: empty new text: nothing queued" eq "$(queued)" 0
printf 'e\nd\nradera\n' | menuf bob post_actions general "$A"
check "menu: other user cannot edit or delete" eq "$(queued)" 0
printf 'd\nja\n' | menuf alice post_actions general "$A"
check "menu: delete without the word radera: nothing queued" eq "$(queued)" 0
printf 'd\nradera\n' | menuf alice post_actions general "$A"
check "menu: author delete: one request" eq "$(queued)" 1
RQ=$(ls "$root"/queue/incoming/*.req)
check "menu: request is delete-post" grep -qxF 'Action: delete-post' "$RQ"
ASOWNER=bbs-alice lib process "$RQ"
check "menu: after the publisher the post is a stub" eq "$(hval "$A" Subject)" "[raderat]"
printf 'e\nx\nb\nr\nHej\n.\n' | menuf alice post_actions general "$A"
check "menu: stub has no commands: nothing queued" eq "$(queued)" 0

mkpost general bbs-bob "bobs inlägg"; BO=$MP
printf 'd\nradera\n' | menuf carol post_actions general "$BO"
check "menu: sysop can delete other's post: one request" eq "$(queued)" 1
sent
mkpost priv bbs-bob "hemligt"; PO=$MP
printf 'd\nradera\n' | menuf alice post_actions priv "$PO"
check "menu: board owner can delete member's post: one request" eq "$(queued)" 1
sent
mkpost news bbs-news "nyhet"; NO=$MP
printf 'r\nd\nradera\n' | menuf carol post_actions news "$NO"
check "menu: read-only news: no commands" eq "$(queued)" 0

mkpost general bbs-alice "$(printf 'åäö ord %.0s' {1..60})"; W=$MP
for w in 40 60 80; do
    ( export BBS_ROOT="$root" USER=bbs-alice BASHBBS_TEST=1
      source "$here/lib/menu.sh"
      show_post "$W" "$w" ) >"$root/t/view$w.txt" 2>>"$log"
    check "menu: show_post width $w: no line wider than $w" test "$(maxlen "$root/t/view$w.txt")" -le "$w"
    check "menu: show_post width $w: Swedish text shown" grep -q 'åäö' "$root/t/view$w.txt"
done

# ---- E. private messages: Maildir, delivery, reply, trash -------------------
hostn=$(hostname)
mkdir -p "$root"/users/{alice,bob}
: > "$root/users/alice/profile"
: > "$root/users/bob/profile"
# Stand-in for Postfix: keeps the arguments and each message in t/delivered.
# SENDMAIL_FAIL=1 makes it fail without keeping anything.
cat > "$root/t/sendmail" <<'SH'
#!/bin/bash
d=$(dirname "$0")/delivered
mkdir -p "$d"
[[ -z ${SENDMAIL_FAIL:-} ]] || { cat >/dev/null; exit 1; }
printf '%s\n' "$*" >> "$d/args"
cat > "$d/$(date +%s%N).msg"
SH
chmod +x "$root/t/sendmail"
export BBS_SENDMAIL="$root/t/sendmail"
lastmsg() { ls "$root"/t/delivered/*.msg | sort | tail -n 1; }
count_msgs() { ls "$root"/t/delivered/*.msg 2>/dev/null | wc -l; }
count_in() { ls "$1" 2>/dev/null | wc -l; }
# plant <user> <name> <subject> <from-user>: a message in the user's Maildir new/, prints its path.
plant() {
    local d="$root/home/bbs-$1/Maildir/new" f="$root/home/bbs-$1/Maildir/new/$(date +%s).$2.$hostn"
    mkdir -p "$d"
    printf 'Message-ID: <%s@%s>\nDate: %s\nFrom: %s@%s\nTo: %s@%s\nSubject: %s\n\nText från %s.\n' \
        "$2" "$hostn" "$(date -R)" "$4" "$hostn" "$1" "$hostn" "$3" "$4" > "$f"
    printf '%s' "$f"
}

printf 'bob\nHälsning\nHej Bob\n.\n\n' | menuf alice mail_write
DM=$(lastmsg)
check "mail: envelope goes to the local account" grep -qxF -- '-i -f bbs-alice bbs-bob' "$root/t/delivered/args"
check "mail: Message-ID is <uuid@host>" grep -qE "^Message-ID: <[0-9a-f-]{36}@$hostn>\$" "$DM"
check "mail: From is the login account" grep -qxF "From: alice@$hostn" "$DM"
check "mail: one From header only" eq "$(grep -c '^From: ' "$DM")" 1
check "mail: To is name@host" grep -qxF "To: bob@$hostn" "$DM"
check "mail: Date header present" grep -q '^Date: ' "$DM"
check "mail: Swedish subject kept" grep -qxF 'Subject: Hälsning' "$DM"
check "mail: sent copy in Sent/cur with seen flag" eq "$(count_in "$root/home/bbs-alice/Maildir/.Sent/cur")" 1
check "mail: sent copy has the seen flag" test -n "$(ls "$root/home/bbs-alice/Maildir/.Sent/cur" | grep ':2,S$')"

printf 'nobody\n\n' | menuf alice mail_write
check "mail: unknown recipient: nothing delivered" eq "$(count_msgs)" 1

printf 'bob\nMisslyckas\nHej\n.\n\n' | SENDMAIL_FAIL=1 menuf alice mail_write
check "mail: sendmail failure: no sent copy" eq "$(count_in "$root/home/bbs-alice/Maildir/.Sent/cur")" 1
check "mail: sendmail failure: message says so" grep -q 'Kunde inte skickas' "$log"

B1=$(plant bob m-hej "Hej där" alice)
printf '1\nS\n\nTack, svar här\n.\n\n' | menuf bob mail_view Inbox
DM=$(lastmsg)
check "reply: To is the sender" grep -qxF "To: alice@$hostn" "$DM"
check "reply: Subject gets Re: once" grep -qxF 'Subject: Re: Hej där' "$DM"
check "reply: In-Reply-To is the original Message-ID" grep -qxF "In-Reply-To: <m-hej@$hostn>" "$DM"
check "reply: read message moved from new to cur" test ! -e "$B1"
check "reply: read message has the seen flag" test -n "$(ls "$root/home/bbs-bob/Maildir/cur" | grep 'm-hej.*:2,S$')"

A1=$(plant alice m-del "Radera mig" bob)
printf '1\nR\n\n' | menuf alice mail_view Inbox
check "trash: own inbox copy moved to .Trash/cur" test -n "$(ls "$root/home/bbs-alice/Maildir/.Trash/cur" | grep m-del)"
check "trash: inbox no longer has it" test -z "$(ls "$root/home/bbs-alice/Maildir/new" "$root/home/bbs-alice/Maildir/cur" 2>/dev/null | grep m-del)"

BK=$(plant bob m-kopia "Kopia" alice)
SENT1=$(ls "$root/home/bbs-alice/Maildir/.Sent/cur"/* | head -n 1)
printf '\n' | menuf alice mail_delete "$SENT1"
check "delete: sender's Sent copy moved to Trash" test -n "$(ls "$root/home/bbs-alice/Maildir/.Trash/cur" | grep -F "$(basename "$SENT1")")"
check "delete: recipient's copy is not touched" test -f "$BK"

echo "boards_edit_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
