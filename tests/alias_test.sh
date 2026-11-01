#!/bin/bash
# bbs-alias and the apply.cgi reserved-name refusal, against stubs and a temp tree.
# Usage: tests/alias_test.sh [logfile]   (screen shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$(mktemp -d)}
log=${1:-$scratch/alias_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" "$1"; }
not_has() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
rc_is() { [[ $1 == "$2" ]]; }
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/alias.XXXXXX")
calls=$root/calls.log; : > "$calls"
printf '# comment\nnews\ncoffe  # admin\nroot\n' > "$root/reserved"
# Fake passwd/group database; useradd stub appends to it like the real one.
cat > "$root/passwd" <<EOF2
root:x:0:0::/root:/bin/bash
news:x:9:9::/var/spool/news:/usr/sbin/nologin
bbs-ptrko:x:1001:1001::/srv/bashbbs/home/ptrko:/usr/local/sbin/bbs-shell
bbs-news:x:1002:1002::/srv/bashbbs/home/news:/bin/bash
bbs-coffe:x:1003:1003::/srv/bashbbs/home/coffe:/usr/local/sbin/bbs-shell
bbs-kitty:x:1004:1004::/srv/bashbbs/home/kitty:/usr/local/sbin/bbs-shell
kitty:x:1500:1500::/home/kitty:/bin/bash
bbs-zed:x:1005:1005::/srv/bashbbs/home/zed:/usr/sbin/nologin
EOF2
printf 'root:x:0:\nbbs-ptrko:x:1001:\nkitty:x:1500:\n' > "$root/group"
cat > "$root/getent" <<EOF2
#!/bin/bash
db=$root/\$1
if [[ \$# -eq 1 ]]; then cat "\$db"; exit 0; fi
grep -E "^\$2:" "\$db" || exit 2
EOF2
cat > "$root/useradd" <<EOF2
#!/bin/bash
echo "useradd \$*" >> "$calls"
n=\${@: -1}; uid=; gid=; home=; sh=
while (( \$# > 1 )); do case \$1 in -u) uid=\$2; shift;; -g) gid=\$2; shift;; -d) home=\$2; shift;; -s) sh=\$2; shift;; esac; shift; done
echo "\$n:x:\$uid:\$gid::\$home:\$sh" >> "$root/passwd"
EOF2
cat > "$root/groupadd" <<EOF2
#!/bin/bash
echo "groupadd \$*" >> "$calls"; echo "bbsalias:x:990:" >> "$root/group"
EOF2
printf '#!/bin/bash\necho "userdel $*" >> "%s"\n' "$calls" > "$root/userdel"
printf '#!/bin/bash\necho "usermod $*" >> "%s"\n' "$calls" > "$root/usermod"
chmod +x "$root"/{getent,useradd,groupadd,userdel,usermod}
# After a useradd, the group lists the member (the real useradd -G does this).
cat > "$root/useradd2" <<EOF2
#!/bin/bash
"$root/useradd" "\$@"; n=\${@: -1}
members=\$(sed -n 's/^bbsalias:x:990://p' "$root/group")
sed -i '/^bbsalias:/d' "$root/group"
echo "bbsalias:x:990:\${members:+\$members,}\$n" >> "$root/group"
EOF2
chmod +x "$root/useradd2"
cp "$root/passwd" "$root/passwd.0"; cp "$root/group" "$root/group.0"

al() { BASHBBS_TEST=1 BBS_GETENT=$root/getent BBS_USERADD=$root/useradd2 BBS_USERDEL=$root/userdel \
    BBS_USERMOD=$root/usermod BBS_GROUPADD=$root/groupadd BBS_RESERVED=$root/reserved \
    "$here/sbin/bbs-alias" "$@"; }
out=$root/out.txt
run() { al "$@" >"$out" 2>&1; rc=$?; cat "$out" >>"$log"; }

# 1. reserved / in-use checks
run check news;   check "check: blocklist name refused" rc_is "$rc" 1
run check coffe;  check "check: name with trailing comment in the list refused" rc_is "$rc" 1
run check kitty;  check "check: existing system user/group refused" rc_is "$rc" 1
run check ab;     check "check: too short refused" rc_is "$rc" 1
run check ptrko;  check "check: free name accepted" rc_is "$rc" 0
mv "$root/reserved" "$root/reserved.off"; run check ptrko; mv "$root/reserved.off" "$root/reserved"
check "check: missing blocklist fails closed" rc_is "$rc" 1

# 2. add
run add news;  check "add: bbs-news gets no alias" not_has "$calls" "useradd"
run add kitty; check "add: name taken by a system user gets no alias" not_has "$calls" "useradd"
run add ptrko
check "add: alias exits 0" rc_is "$rc" 0
check "add: uses same uid, gid and home, no home creation, group bbsalias" \
    has "$calls" "useradd -o -u 1001 -g 1001 -M -N -d /srv/bashbbs/home/ptrko -s /usr/local/sbin/bbs-shell -G bbsalias ptrko"
check "add: group bbsalias created" has "$calls" "groupadd --system bbsalias"
check "add: alias line comes after bbs-ptrko" bash -c 'awk -F: "\$1==\"bbs-ptrko\"{a=NR} \$1==\"ptrko\"{b=NR} END{exit !(a&&b&&b>a)}" "$1"' _ "$root/passwd"
: > "$calls"
run add ptrko
check "add: idempotent" not_has "$calls" "useradd"
run add ghost; check "add: unknown account refused" rc_is "$rc" 1
run add zed
check "add: alias of a disabled account keeps nologin" has "$calls" "-s /usr/sbin/nologin"

# 3. shell + remove
: > "$calls"
run shell ptrko /usr/sbin/nologin
check "shell: sets alias shell" has "$calls" "usermod -s /usr/sbin/nologin ptrko"
run shell news /usr/sbin/nologin
check "shell: no change for a non-alias" not_has "$calls" "usermod -s /usr/sbin/nologin news"
run remove news; check "remove: refuses to touch a non-alias" not_has "$calls" "userdel news"
run remove ptrko
check "remove: userdel without -r" has "$calls" "userdel ptrko"
check "remove: never -r" not_has "$calls" "userdel -r"

# 4. backfill (from the original database)
cp "$root/passwd.0" "$root/passwd"; cp "$root/group.0" "$root/group"
run backfill
check "backfill dry run lists a candidate" has "$out" "would create alias"
check "backfill dry run says kitty is skipped" has "$out" "kitty: skipped"
check "backfill dry run says news is skipped" has "$out" "news: skipped"
: > "$calls"
run backfill
check "backfill dry run changes nothing" not_has "$calls" "useradd"
run backfill --apply
check "backfill --apply creates ptrko" has "$calls" "-G bbsalias ptrko"
check "backfill --apply creates zed" has "$calls" "-G bbsalias zed"
check "backfill --apply never creates coffe" not_has "$calls" "bbsalias coffe"

# 5. apply.cgi
appdir=$root/incoming; mkdir -p "$appdir" "$root/users/taken"
cgi() { # cgi <name>: POST a form, print the status line
    local body="name=$1&key=ssh-ed25519+AAAAC3NzaC1lZDI1NTE5AAAAItest&note=x"
    printf '%s' "$body" | BASHBBS_TEST=1 REQUEST_METHOD=POST CONTENT_LENGTH=${#body} \
        BBS_APP_DIR=$appdir BBS_USERS=$root/users BBS_RESERVED=$root/reserved python3 "$here/web/apply.cgi" | head -n 1
}
r=$(cgi news);  check "apply.cgi refuses news (409)" [ "$r" = "Status: 409 Conflict" ]
r=$(cgi root);  check "apply.cgi refuses root (system user)" [ "$r" = "Status: 409 Conflict" ]
r=$(cgi daemon); check "apply.cgi refuses a system user not on the list" [ "$r" = "Status: 409 Conflict" ]
check "apply.cgi saved nothing for refused names" bash -c '[[ -z $(ls -A "$1") ]]' _ "$appdir"
r=$(cgi zzqqx); check "apply.cgi accepts a free name" [ "$r" = "Status: 200 OK" ]
check "apply.cgi wrote one application" bash -c '[[ $(ls "$1" | wc -l) -eq 1 ]]' _ "$appdir"
cgi_body() { # cgi_body <form body>: POST it, print the whole response
    printf '%s' "$1" | BASHBBS_TEST=1 REQUEST_METHOD=POST CONTENT_LENGTH=${#1} \
        BBS_APP_DIR=$appdir BBS_USERS=$root/users BBS_RESERVED=$root/reserved python3 "$here/web/apply.cgi"
}
r=$(cgi_body 'name=privk&key=-----BEGIN+OPENSSH+PRIVATE+KEY-----%0Ab3BlbnNzaC1rZXktdjEAAAAA%0A-----END+OPENSSH+PRIVATE+KEY-----')
check "apply.cgi refuses a private key (400)" [ "$(head -n 1 <<<"$r")" = "Status: 400 Bad Request" ]
check "apply.cgi names the private key in the error" bash -c '[[ $1 == *"That was your private key"* ]]' _ "$r"
check "apply.cgi saved nothing for a private key" bash -c '[[ $(ls "$1" | wc -l) -eq 1 ]]' _ "$appdir"
r=$(cgi_body 'name=%3Cb%3Ex&key=x')
check "apply.cgi response escapes input and links the stylesheet" bash -c '[[ $1 != *"<b>x"* && $1 == *"/style.css"* ]]' _ "$r"
r=$(cgi_body 'name=okname&key=ssh-ed25519+AAAAC3NzaC1lZDI1NTE5AAAAItest')
check "apply.cgi success page shows the login command" bash -c '[[ $1 == *"ssh -p 6464 okname@bbs.piewpiew.se"* ]]' _ "$r"

echo "alias_test: pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
