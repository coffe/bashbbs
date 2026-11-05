#!/bin/bash
# bbs-admin-apply: the root sorter for queue/admin, against a temporary BBS_ROOT.
# It runs the real sbin/bbs-admin, whose tools (bbs-svara, bbs-keys, bbs-alias,
# getent, usermod, userdel, pkill, chown) are stubs that only log their arguments.
# BBS_TEST_OWNER stands in for the owner of the request files; BBS_TEST_EUID=0
# lets bbs-admin accept --as as if root ran it.
# Usage: tests/admin_apply_test.sh [logfile]   (full log in the file; the screen
# shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$(mktemp -d)}
log=${1:-$scratch/admin_apply_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" "$1"; }
not_has() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
eq() { [[ $1 == "$2" ]]; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/aap.XXXXXX")
sbin=$root/stubs
calls=$root/calls.log
mkdir -p "$sbin" "$root"/{queue/admin,state,keys,home/bbs-bob,drop}
printf 'coffe\ncarol\n' > "$root/sysops"
: > "$calls"
for t in bbs-approve bbs-svara bbs-alias usermod userdel pkill chown; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$calls" > "$sbin/$t"
done
# bbs-keys also saves the key file it got, to show what was passed.
printf '#!/bin/bash\necho "bbs-keys $*" >> "%s"\n[[ $1 == add ]] && cp -- "$3" "%s"\n' \
    "$calls" "$root/key-seen" > "$sbin/bbs-keys"
cat > "$sbin/getent" <<EOF
#!/bin/bash
case \$2 in
    bbs-ghost) exit 2 ;;
    bbs-bob) echo "bbs-bob:x:1001:1001::$root/home/bbs-bob:/usr/local/sbin/bbs-shell" ;;
    *) echo "bbs-bob:x:1001:1001::$root/home/bbs-bob:/usr/local/sbin/bbs-shell" ;;
esac
EOF
chmod +x "$sbin"/*

apply() { # apply [VAR=value...]: one sorter run as owner bbs-coffe unless overridden
    env -u SUDO_USER BASHBBS_TEST=1 BBS_ROOT=$root BBS_TEST_OWNER=bbs-coffe \
        BBS_TEST_EUID=0 BBS_SBIN=$sbin BBS_GETENT=$sbin/getent BBS_USERMOD=$sbin/usermod \
        BBS_USERDEL=$sbin/userdel BBS_PKILL=$sbin/pkill BBS_CHOWN=$sbin/chown "$@" \
        "$here/sbin/bbs-admin-apply" >>"$log" 2>&1
}
req() { # req <file id> <lines...>: one request file in the queue
    local f=$root/queue/admin/$1.req; shift
    printf '%s\n' "$@" > "$f"
}
res=$root/state/admin-results
alog=$root/state/admin.log
nq() { ls -A "$root/queue/admin" | wc -l; }

# 1. Sender binding: wrong owner, real uid lookup, symlink
req a1 id=1-a1 action=users-disable name=bob
apply BBS_TEST_OWNER=bbs-bob
check "request from a non-sysop is removed from the queue" eq "$(nq)" 0
check "request from a non-sysop leaves no result" test ! -e "$res/1-a1"
check "request from a non-sysop is logged as rejected" has "$alog" "rejected owner-uid"
check "request from a non-sysop is kept in drop/rejected" test -n "$(ls "$root/drop/rejected")"
check "request from a non-sysop runs nothing" not_has "$calls" usermod
req a2 id=1-a2 action=users-disable name=bob
apply BBS_TEST_OWNER=
check "owner without the test hook (a real non-bbs account) is rejected" test ! -e "$res/1-a2"
check "real-owner rejection runs nothing" not_has "$calls" usermod
printf 'id=1-a3\naction=users-disable\nname=bob\n' > "$root/target"
ln -s "$root/target" "$root/queue/admin/a3.req"
apply
check "symlinked request is rejected" test ! -e "$res/1-a3"
check "symlink rejection is logged" has "$alog" "rejected bind-open"
check "symlink target is untouched" test -f "$root/target"

# 2. Malformed requests
req b1 id=../x action=users-disable name=bob
req b2 id=1-b2 action=users-disable action=users-enable name=bob
req b3 'id=1-b3' 'action=users-disable' 'name=bob' 'shell=/bin/sh'
apply
check "bad id is rejected without result" test ! -e "$root/state/x"
check "duplicate key is rejected" test ! -e "$res/1-b2"
check "unknown key is rejected" test ! -e "$res/1-b3"
check "malformed requests run nothing" not_has "$calls" usermod
check "malformed requests leave the queue" eq "$(nq)" 0

# 3. Unknown action, bad name, extra field
req c1 id=1-c1 action=users-chsh name=bob
req c2 'id=1-c2' 'action=users-disable' 'name=Bob;rm'
req c3 id=1-c3 action=users-disable name=bob code=4528
apply
check "unknown action gets status 64" has "$res/1-c1" "status=64"
check "unknown action is logged" has "$alog" "rejected unknown-action"
check "bad name gets status 65" has "$res/1-c2" "status=65"
check "field the action does not use gets status 65" has "$res/1-c3" "status=65"
check "rejected actions run nothing" not_has "$calls" usermod

# 4. Guard: yourself, another sysop, system account
req d1 id=1-d1 action=users-disable name=coffe
req d2 id=1-d2 action=users-remove name=carol
req d3 id=1-d3 action=alias-remove name=carol
req d4 id=1-d4 action=users-disable name=news
req d5 id=1-d5 action=keys-remove name=carol fingerprint=SHA256:abcdefghijklmnop
req d6 id=1-d6 action=keys-remove name=coffe fingerprint=SHA256:abcdefghijklmnop
req d7 id=1-d7 action=users-enable name=carol
apply
check "disabling yourself is refused" has "$res/1-d1" "status=77"
check "removing another sysop is refused" has "$res/1-d2" "status=77"
check "removing another sysop's alias is refused" has "$res/1-d3" "status=77"
check "disabling bbs-news is refused" has "$res/1-d4" "status=65"
check "removing another sysop's key is refused" has "$res/1-d5" "status=77"
check "removing your own key is refused" has "$res/1-d6" "status=77"
check "enabling another sysop is refused" has "$res/1-d7" "status=77"
check "guarded requests run no key change" not_has "$calls" "bbs-keys remove carol"
check "guarded requests run nothing" not_has "$calls" usermod
check "guarded requests run no alias change" not_has "$calls" "bbs-alias"

# 5. Success paths
req e1 id=1700000000-e1 action=users-disable name=bob
apply
r=$res/1700000000-e1
check "success writes a result with status 0" has "$r" "status=0"
check "result carries the bbs-admin output" has "$r" "bbs-bob: disable done"
check "result is mode 0400" eq "$(stat -c %a "$r")" 400
check "result is handed to the sender uid" has "$calls" "chown $(id -u) "
check "results directory is 0711" eq "$(stat -c %a "$res")" 711
check "bbs-admin ran with --as (log names the sysop)" grep -qP '\tcoffe\tusers disable bob$' "$alog"
check "disable reached usermod" has "$calls" "usermod -s /usr/sbin/nologin bbs-bob"
check "handled request is removed" eq "$(nq)" 0
req e2 id=1-e2 action=alias-check name=bob
req e3 id=1-e3 action=apps-accept code=4528
req e4 id=1-e4 action=keys-add name=bob 'key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbcdefghijklmnopqrstuvwxyz0123456789ABCD laptop'
req e5 id=1-e5 action=keys-remove name=bob fingerprint=SHA256:abcdefghijklmnop
req e6 id=1-e6 action=alias-add name=bob
apply
check "alias-check runs without --ja" has "$calls" "bbs-alias check bob"
check "alias-check result is status 0" has "$res/1-e2" "status=0"
check "apps-accept reaches bbs-svara" has "$calls" "bbs-svara accept 4528"
check "keys-add passes the key line in a file" has "$root/key-seen" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"
check "keys-add result is status 0" has "$res/1-e4" "status=0"
check "keys-remove reaches bbs-keys" has "$calls" "bbs-keys remove bob SHA256:abcdefghijklmnop"
check "alias-add reaches bbs-alias" has "$calls" "bbs-alias add bob"
check "all handled requests leave the queue" eq "$(nq)" 0
req e7 'id=1-e7' 'action=keys-add' 'name=bob' 'key=ssh-ed25519 AAAA$(id)AAAAAAAAAAAAAAAA'
apply
check "keys-add refuses a key line with shell characters" has "$res/1-e7" "status=65"

# 6. An old result owned by the same uid is replaced (another uid is refused; needs root to test)
printf 'old\n' > "$res/1-f1"; chmod 0400 "$res/1-f1"
req f1 id=1-f1 action=alias-check name=bob
apply BBS_TEST_OWNER=bbs-carol
check "own old result may be replaced" has "$res/1-f1" "status=0"

# 7. Key check: lengths by ${#}, not {m,n} (that regex took ~800 MB on a Pi 2 and was OOM-killed).
long=$(head -c 3000 /dev/zero | tr '\0' 'A')
req g1 id=1-g1 action=keys-add name=bob "key=ssh-rsa $long== big key"
( ulimit -v 400000; apply )
check "keys-add: a 3000-char key passes under 400 MB in time" has "$res/1-g1" "status=0"
req g2 id=1-g2 action=keys-add name=bob "key=ssh-rsa $long$long$(head -c 2050 /dev/zero | tr '\0' A)"   # 8050 chars, request still under 8192 bytes
apply
check "keys-add: base64 over 8000 chars refused" has "$res/1-g2" "status=65"
req g3 id=1-g3 action=keys-add name=bob 'key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA===='
apply
check "keys-add: four = refused" has "$res/1-g3" "status=65"
req g4 id=1-g4 action=keys-add name=bob 'key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA bad;comment'
apply
check "keys-add: comment with ; refused" has "$res/1-g4" "status=65"
req g5 id=1-g5 action=keys-add name=bob 'key=ss AAAAC3NzaC1lZDI1NTE5AAAA'
apply
check "keys-add: type under 3 chars refused" has "$res/1-g5" "status=65"
# A run that dies (signal, OOM) is not reported as "unknown action".
req g6 id=1-g6 action=alias-check name=bob
env -u SUDO_USER BASHBBS_TEST=1 BBS_ROOT=$root BBS_TEST_OWNER=bbs-coffe BBS_TEST_EUID=0 \
    BBS_SBIN=$sbin BBS_GETENT=$sbin/getent BBS_CHOWN=$sbin/chown bash -c '
    source "$1"; run_request() { kill -9 $BASHPID; }; handle_file "$2"' _ \
    "$here/sbin/bbs-admin-apply" "$root/queue/admin/g6.req" >>"$log" 2>&1
check "a killed request is not reported as unknown action" has "$res/1-g6" "status=70"
check "a killed request names the exit" has "$res/1-g6" "exit 137"

# 8. Waiting applications: one list per sysop, from applications/incoming.
mkdir -p "$root/applications/incoming"
printf 'name=dave\nemail=x\n' > "$root/applications/incoming/1500000070-0a50511c-1111-2222-3333-444455556666.app"
printf 'name=e\033[31mve\nemail=x\n' > "$root/applications/incoming/1500000060-noid.app"
ln -s /etc/passwd "$root/applications/incoming/1500000080-link.app"
: > "$calls"
apply
lst=$root/state/apps-waiting
check "apps list: written for sysop coffe" test -f "$lst/coffe"
check "apps list: two applications, link skipped" eq "$(wc -l < "$lst/coffe")" 2
check "apps list: oldest first, code from the file name" eq "$(tail -n 1 "$lst/coffe")" "$(printf '1500000070\t0a50511c\tdave')"
check "apps list: no usable id gives -, control bytes stripped" eq "$(head -n 1 "$lst/coffe")" "$(printf '1500000060\t-\te31mve')"
check "apps list: owned by the sysop (chown)" has "$calls" "chown"
check "apps list: mode 0400" eq "$(stat -c %a "$lst/coffe")" 400
printf 'x\n' > "$lst/oldsysop"
rm -f "$root/applications/incoming"/*.app
apply
check "apps list: empty when none wait" eq "$(wc -l < "$lst/coffe")" 0
check "apps list: a former sysop's list is removed" test ! -e "$lst/oldsysop"

echo "pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
