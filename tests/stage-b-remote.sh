#!/bin/bash
# Stage B acceptance tests. Run on the Pi as root:
#   scp tests/stage-b-remote.sh zero:/tmp/ && ssh zero 'sudo bash /tmp/stage-b-remote.sh'
# Needs the test accounts bbs-testa and bbs-testb. Posts it creates have
# "stage-b-" in the subject and are removed at the end.
set -u

Q=/srv/bashbbs/queue/incoming
GEN=/srv/bashbbs/boards/general
pass=0
fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# Submit a post the same way menu.sh does: temp file in incoming, then mv.
# The subject must not contain shell metacharacters; the test passes it as an argument.
submit() { # user board subject [parent]
    sudo -u "$1" bash -c '
        tmp=$(mktemp /srv/bashbbs/queue/incoming/.tmp.XXXXXX) || exit 1
        { printf "Board: %s\n" "$1"; printf "Subject: %s\n" "$2"
          [ -n "$3" ] && printf "Parent: %s\n" "$3"
          printf "\nbody of %s\n" "$2"; } > "$tmp"
        mv -f "$tmp" "/srv/bashbbs/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).post"
    ' _ "$2" "$3" "${4:-}"
}

publish() { systemctl start bbs-publish.service; }

published() { # subject -> number of board files with that subject
    grep -l "^Subject: $1\$" /srv/bashbbs/boards/*/*.msg 2>/dev/null | wc -l
}

# 1. Parallel writes: 20 posts from two users at once, all must arrive intact.
for i in $(seq 1 10); do submit bbs-testa general "stage-b-par-$i" & done
for i in $(seq 11 20); do submit bbs-testb general "stage-b-par-$i" & done
wait
publish
n=$(grep -l '^Subject: stage-b-par-' "$GEN"/*.msg 2>/dev/null | wc -l)
[[ $n -eq 20 ]] && ok "parallel: 20 of 20 posts published" || bad "parallel: $n of 20 published"
dups=$(grep -h '^Msgid:' "$GEN"/*.msg | sort | uniq -d | wc -l)
[[ $dups -eq 0 ]] && ok "parallel: no duplicate Msgid" || bad "parallel: $dups duplicate Msgid"
empty=$(find "$GEN" -name '*.msg' -size -1c | wc -l)
[[ $empty -eq 0 ]] && ok "parallel: no empty files" || bad "parallel: $empty empty files"
left=$(ls "$Q" | grep -c '\.post$')
[[ $left -eq 0 ]] && ok "queue empty after publish" || bad "queue has $left posts left"

# 2. Bad Board names are rejected and nothing is written.
submit bbs-testa nope "stage-b-badboard"
submit bbs-testa '../../etc' "stage-b-trav"
submit bbs-testa 'general/../..' "stage-b-trav2"
publish
[[ $(published 'stage-b-badboard') -eq 0 && $(published 'stage-b-trav') -eq 0 && $(published 'stage-b-trav2') -eq 0 ]] \
    && ok "bad board names rejected" || bad "bad board name was published"
boards=$(ls /srv/bashbbs/boards | tr '\n' ' ')
[[ $boards == "general " ]] && ok "board list unchanged" || bad "board list changed: $boards"

# 3. Parent must be a UUID. A traversal string is rejected, a real UUID is kept.
submit bbs-testa general "stage-b-badparent" "../../x"
parent=$(cat /proc/sys/kernel/random/uuid)
submit bbs-testa general "stage-b-goodparent" "$parent"
publish
[[ $(published 'stage-b-badparent') -eq 0 ]] && ok "bad Parent rejected" || bad "bad Parent was published"
f=$(grep -l '^Subject: stage-b-goodparent$' "$GEN"/*.msg 2>/dev/null | head -n 1)
grep -q "^Parent: $parent\$" "$f" 2>/dev/null && ok "good Parent kept" || bad "good Parent missing"

# 4. Oversized post (over 16384 bytes) is dropped.
sudo -u bbs-testa bash -c 'tmp=$(mktemp /srv/bashbbs/queue/incoming/.tmp.XXXXXX); { printf "Board: general\nSubject: stage-b-big\n\n"; head -c 20000 /dev/zero | tr "\0" a; } > "$tmp"; mv -f "$tmp" "/srv/bashbbs/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).post"'
publish
[[ $(published 'stage-b-big') -eq 0 ]] && ok "oversized post rejected" || bad "oversized post was published"

# 5. Symlink in incoming is never followed or published.
ln -sf /etc/shadow "$Q/evil.post"
publish
leak=$(grep -l 'root:' "$GEN"/*.msg 2>/dev/null | wc -l)
[[ $leak -eq 0 ]] && ok "symlink to /etc/shadow not published" || bad "symlink content leaked"
rm -f "$Q/evil.post"

# 6. Users cannot list the queue or write into boards directly.
sudo -u bbs-testa ls "$Q" >/dev/null 2>&1 && bad "queue listable by user" || ok "queue not listable by user"
sudo -u bbs-testa sh -c "echo x > $GEN/stage-b-direct.msg" 2>/dev/null \
    && bad "user wrote into boards/ directly" || ok "user cannot write into boards/"

# 7. Hard links to files owned by someone else are refused (protected_hardlinks).
sudo -u bbs-testb sh -c "printf 'Board: general\nSubject: stage-b-hard\n\nx\n' > $Q/testb-src.tmp"
sudo -u bbs-testa ln "$Q/testb-src.tmp" "$Q/testa-link.post" 2>/dev/null \
    && bad "hard link to another user's file was created" || ok "hard link to another user's file refused"
rm -f "$Q/testb-src.tmp" "$Q/testa-link.post"

# Clean up posts from this run.
removed=$(grep -l '^Subject: stage-b-' "$GEN"/*.msg 2>/dev/null | wc -l)
grep -l '^Subject: stage-b-' "$GEN"/*.msg 2>/dev/null | xargs -r rm -f
echo "cleanup: removed $removed test posts"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
