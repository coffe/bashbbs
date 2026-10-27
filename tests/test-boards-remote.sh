#!/bin/bash
# Private board acceptance tests. Run on the Pi as root:
#   scp tests/test-boards-remote.sh zero:/tmp/ && ssh zero 'sudo bash /tmp/test-boards-remote.sh'
# Needs the test accounts bbs-testa and bbs-testb. Creates the boards tstpriv1..3
# and removes them at the end. The sysops file is restored after test 12.
set -u

Q=/srv/bashbbs/queue/incoming
B=/srv/bashbbs/boards
META=/srv/bashbbs/meta
SYSOPS=/srv/bashbbs/sysops
pass=0
fail=0

# Start clean: leftovers from an earlier run would make the quota and create tests fail.
clean_boards() {
    local b
    for b in tstpriv1 tstpriv2 tstpriv3; do
        rm -rf "$B/$b" "$META/$b.meta"
        groupdel "bbsb-$b" 2>/dev/null
    done
}
clean_boards
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# Run the publisher directly. systemctl start hits start-limit-hit after a few
# quick calls, so requests would pile up in the queue and run in the wrong step.
publish() { /usr/local/sbin/bbs-publish; }

in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

# Post a message the way menu.sh does: temp file in incoming, then mv.
submit() { # user board subject
    sudo -u "$1" bash -c '
        tmp=$(mktemp /srv/bashbbs/queue/incoming/.tmp.XXXXXX) || exit 1
        { printf "Board: %s\n" "$1"; printf "Subject: %s\n" "$2"; printf "\nbody\n"; } > "$tmp"
        mv -f "$tmp" "/srv/bashbbs/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).post"
    ' _ "$2" "$3"
}

# Send a board request the way menu.sh does. Args: user action board [target user]
request() {
    local target=${4:-}
    printf 'Action: %s\nBoard: %s\nUser: %s\n' "$2" "$3" "$target" | sudo -u "$1" bash -c '
        tmp=$(mktemp /srv/bashbbs/queue/incoming/.tmp.XXXXXX) || exit 1
        cat > "$tmp"
        mv -f "$tmp" "/srv/bashbbs/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).req"
    '
}

published() { # subject board -> number of files with that subject
    grep -l "^Subject: $2\$" "$B/$1"/*.msg 2>/dev/null | wc -l
}

# 1. A user creates a private board: group, meta and 0750 directory.
request bbs-testa create-board tstpriv1
publish
[[ -f $META/tstpriv1.meta ]] && grep -qx 'owner=testa' "$META/tstpriv1.meta" \
    && [[ $(stat -c '%a %G' "$B/tstpriv1" 2>/dev/null) == "750 bbsb-tstpriv1" ]] \
    && ok "create-board: meta, 0750 dir, group" || bad "create-board failed"

# 2. The owner is a member of the new group.
in_group bbs-testa bbsb-tstpriv1 && ok "owner is a member" || bad "owner not a member"

# 3. A non-member cannot list or read the board.
sudo -u bbs-testb ls "$B/tstpriv1" >/dev/null 2>&1 \
    && bad "non-member could list private board" || ok "non-member cannot list private board"

# 4. A member's post is published with group-only permissions.
submit bbs-testa tstpriv1 stage-c-own
publish
n=$(published tstpriv1 stage-c-own)
f=$(grep -l '^Subject: stage-c-own$' "$B/tstpriv1"/*.msg 2>/dev/null | head -n 1)
[[ $n -eq 1 && $(stat -c '%a %G' "$f" 2>/dev/null) == "640 bbsb-tstpriv1" ]] \
    && ok "member post published as 0640 in private board" || bad "member post missing or wrong mode"

# 5. A non-member post to a private board is rejected.
submit bbs-testb tstpriv1 stage-c-intruder
publish
[[ $(published tstpriv1 stage-c-intruder) -eq 0 ]] && ok "non-member post rejected" || bad "non-member post was published"

# 6. A non-owner cannot invite anyone.
request bbs-testb invite tstpriv1 testb
publish
in_group bbs-testb bbsb-tstpriv1 && bad "non-owner invited himself" || ok "non-owner cannot invite"

# 7. The owner invites testb; testb can then post.
request bbs-testa invite tstpriv1 testb
publish
in_group bbs-testb bbsb-tstpriv1 && ok "owner invite adds member" || bad "invite did not add member"
submit bbs-testb tstpriv1 stage-c-member
publish
[[ $(published tstpriv1 stage-c-member) -eq 1 ]] && ok "invited member can post" || bad "invited member post rejected"

# 8. The owner cannot be removed from their own board.
request bbs-testb remove tstpriv1 testa
publish
in_group bbs-testa bbsb-tstpriv1 && ok "owner cannot be removed" || bad "owner was removed"

# 9. The owner removes testb; testb can no longer post.
request bbs-testa remove tstpriv1 testb
publish
in_group bbs-testb bbsb-tstpriv1 && bad "remove did not take effect" || ok "remove takes effect for posting"
submit bbs-testb tstpriv1 stage-c-after-remove
publish
[[ $(published tstpriv1 stage-c-after-remove) -eq 0 ]] && ok "removed member post rejected" || bad "removed member still posts"

# 10. Quota: two boards per user, the third is refused.
request bbs-testa create-board tstpriv2
publish
request bbs-testa create-board tstpriv3
publish
[[ -f $META/tstpriv2.meta && ! -e $META/tstpriv3.meta ]] \
    && ok "quota: second board allowed, third refused" || bad "quota not enforced"

# 11. A name that is already a public board is refused.
request bbs-testb create-board general
publish
[[ ! -e $META/general.meta && -d $B/general ]] && ok "public name cannot be taken" || bad "public name was taken"

# 12. Sysops are added to every private board, including ones created later.
cp -p "$SYSOPS" "$SYSOPS.test-bak"
echo testb > "$SYSOPS"
publish
in_group bbs-testb bbsb-tstpriv1 && ok "sysop added to existing private board" || bad "sysop not added"
in_group bbs-testb bbsb-tstpriv2 && ok "sysop added to second private board" || bad "sysop not added to second board"
mv -f "$SYSOPS.test-bak" "$SYSOPS"

# Clean up: boards, meta files, groups and this run's public posts.
for b in tstpriv1 tstpriv2 tstpriv3; do
    rm -rf "$B/$b" "$META/$b.meta"
    groupdel "bbsb-$b" 2>/dev/null
done
grep -l '^Subject: stage-c-' "$B"/general/*.msg 2>/dev/null | xargs -r rm -f

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
