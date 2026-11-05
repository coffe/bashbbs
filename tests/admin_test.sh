#!/bin/bash
# bbs-admin: every subcommand against a temporary BBS_ROOT. The tools it calls
# (bbs-approve, bbs-svara, bbs-keys, bbs-health, getent, usermod, userdel, pkill,
# chown) are stubs that only log their arguments, so nothing real is touched.
# Usage: tests/admin_test.sh [logfile]   (full log in the file; the screen
# shows only failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$(mktemp -d)}
log=${1:-$scratch/admin_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
has() { grep -qF -- "$2" "$1"; }
not_has() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
empty() { [[ ! -s $1 ]]; }
rc_is() { [[ $1 == "$2" ]]; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/adm.XXXXXX")
sbin=$root/stubs
calls=$root/calls.log
mkdir -p "$sbin" "$root"/{boards/general,queue/incoming,state,keys,home/bbs-bob}
echo coffe > "$root/sysops"
: > "$calls"

# Stubs: log "name args" and succeed. bbs-health prints one fact line.
for t in bbs-approve bbs-svara bbs-keys bbs-alias; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$calls" > "$sbin/$t"
done
printf '#!/bin/bash\necho "bbs-health" >> "%s"\necho "sshd=active"\n' "$calls" > "$sbin/bbs-health"
cat > "$sbin/getent" <<EOF
#!/bin/bash
echo "getent \$*" >> "$calls"
case \$2 in
    bbs-ghost) exit 2 ;;
    bbs-bob) echo "bbs-bob:x:1001:1001::$root/home/bbs-bob:/usr/local/sbin/bbs-shell" ;;
    bbs-coffe) echo "bbs-coffe:x:1002:1002::$root/home/bbs-coffe:/usr/local/sbin/bbs-shell" ;;
    *) echo "bbs-bob:x:1001:1001::$root/home/bbs-bob:/usr/local/sbin/bbs-shell"
       echo "bbs-coffe:x:1002:1002::$root/home/bbs-coffe:/usr/local/sbin/bbs-shell"
       echo "bbs-zed:x:1003:1003::/nowhere:/usr/sbin/nologin"
       echo "nobody:x:65534:65534::/:/usr/sbin/nologin" ;;
esac
EOF
for t in usermod userdel pkill chown; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$calls" > "$sbin/$t"
done
chmod +x "$sbin"/*

# Fixture: a live post by bob, and a deleted one.
uid=0b8c6f3e-1111-4222-8333-444455556666
dead=0b8c6f3e-1111-4222-8333-777788889999
printf 'Msgid: %s\nAuthor: bbs-bob\nNode: n\nDate: 2026-10-30T10:00:00+00:00\nSubject: Hej\n\nText\n' "$uid" \
    > "$root/boards/general/1700000000-$uid.msg"
printf 'Msgid: %s\nAuthor: bbs-bob\nNode: n\nDate: 2026-10-30T10:00:00+00:00\nSubject: [deleted]\nDeleted: 2026-10-30T11:00:00+00:00\n\n' "$dead" \
    > "$root/boards/general/1700000001-$dead.msg"
printf 'name=bobby\n' > "$root/keys/bbs-bob"
printf 'stamp\tcoffe\tgeneral\t%s\n' "$dead" > "$root/state/mod.log"
printf 'ssh-ed25519 AAAA test\n' > "$scratch/adm-key.pub"

admin() { # admin <args...>: run bbs-admin in test mode as the sysop coffe
    BASHBBS_TEST=1 BBS_ROOT=$root BBS_SBIN=$sbin BBS_ADMIN_USER=coffe \
        BBS_GETENT=$sbin/getent BBS_USERMOD=$sbin/usermod BBS_USERDEL=$sbin/userdel \
        BBS_PKILL=$sbin/pkill BBS_CHOWN=$sbin/chown \
        "$here/sbin/bbs-admin" "$@"
}
out=$scratch/adm-out.txt
run() { admin "$@" >"$out" 2>&1; rc=$?; cat "$out" >>"$log"; }

# 1. Guards
BASHBBS_TEST=1 BBS_ROOT=/srv/bashbbs "$here/sbin/bbs-admin" status >"$out" 2>&1; rc=$?
check "refuses /srv/bashbbs in test mode" rc_is "$rc" 1
BASHBBS_TEST=1 BBS_ROOT=$root BBS_ADMIN_USER=mallory "$here/sbin/bbs-admin" status >"$out" 2>&1; rc=$?
check "refuses a user who is not a sysop" rc_is "$rc" 1
run
check "no subcommand prints usage with rc 64" rc_is "$rc" 64
run apps list --bogus
check "unknown option refused" rc_is "$rc" 1
run keys add bobby /dev/null --force
check "--force only for keys remove" rc_is "$rc" 1

# 2. status and apps list
run status
check "status runs bbs-health" has "$calls" "bbs-health"
run apps list
check "apps list calls bbs-approve list" has "$calls" "bbs-approve list"

# 3. apps accept: dry run, bad id, real run
: > "$calls"
run apps accept 4528
check "apps accept without --ja is a dry run" rc_is "$rc" 0
check "dry run calls no bbs-svara" empty "$calls"
run apps accept "../etc"
check "apps accept refuses a bad id" rc_is "$rc" 1
run apps accept 4528 --ja
check "apps accept --ja calls bbs-svara" has "$calls" "bbs-svara accept 4528"
check "apps accept is logged" has "$root/state/admin.log" "apps accept 4528"

# 4. keys: list, remove dry run, add, force, bad names
: > "$calls"
run keys list bob
check "keys list passes the name" has "$calls" "bbs-keys list bob"
: > "$calls"
run keys remove bob "SHA256:abcdefghijklmnop"
check "keys remove without --ja does nothing" empty "$calls"
run keys remove bob "SHA256:abcdefghijklmnop" --force --ja
check "keys remove --force --ja passes --force" has "$calls" "bbs-keys remove bob SHA256:abcdefghijklmnop --force"
run keys add Bad "$scratch/adm-key.pub" --ja
check "keys add refuses a bad name" rc_is "$rc" 1
run keys add bob "$scratch/adm-key.pub" --label "Laptop" --legacy --ja
check "keys add passes label and legacy" has "$calls" "bbs-keys add bob $scratch/adm-key.pub --label Laptop --legacy"
run keys add bob "$scratch/adm-key.pub" --label 'x;rm' --ja
check "keys add refuses a bad label" rc_is "$rc" 1
run keys restore bob "$scratch/missing.hist" --ja
check "keys restore refuses a missing file" rc_is "$rc" 1

# 5. mod list and mod delete
run mod list 5
check "mod list shows the log" has "$out" "$dead"
run mod delete general "not-a-uuid"
check "mod delete refuses a bad msgid" rc_is "$rc" 1
run mod delete general "$dead"
check "mod delete refuses an already deleted post" rc_is "$rc" 1
: > "$calls"
run mod delete general "$uid"
check "mod delete without --ja queues nothing" test -z "$(ls -A "$root/queue/incoming")"
check "mod delete dry run shows the author" has "$out" "bbs-bob"
run mod delete general "$uid" --ja
req=$(ls "$root/queue/incoming"/*.req 2>/dev/null | head -n 1)
check "mod delete --ja writes one request" test -n "$req"
check "request has the delete action" has "$req" "Action: delete-post"
check "request names board and msgid" has "$req" "Msgid: $uid"
check "request is handed to the sysop account" has "$calls" "chown bbs-coffe"
check "mod delete is logged" has "$root/state/admin.log" "mod delete general $uid"

# 6. users list, disable, enable, remove
run users list
check "users list shows disabled state" has "$out" "zed"
run users disable coffe
check "users disable refuses your own account" rc_is "$rc" 1
run users disable bob
check "users disable without --ja changes nothing" not_has "$calls" "usermod -s /usr/sbin/nologin"
run users disable bob --ja
check "users disable sets nologin" has "$calls" "usermod -s /usr/sbin/nologin bbs-bob"
check "users disable ends sessions" has "$calls" "pkill -TERM -u bbs-bob"
check "users disable also disables the short-name alias" has "$calls" "bbs-alias shell bob /usr/sbin/nologin"
run users enable bob --ja
check "users enable restores bbs-shell" has "$calls" "usermod -s /usr/local/sbin/bbs-shell bbs-bob"
run users disable ghost --ja
check "users disable refuses an unknown account" rc_is "$rc" 1
run users remove bob
check "users remove without --ja changes nothing" not_has "$calls" "userdel bbs-bob"
mkdir -p "$root/home/bbs-bob"; printf 'mail\n' > "$root/home/bbs-bob/.mail"
mkdir -p "$root/users/bob"; printf 'name=bob\n' > "$root/users/bob/profile"
run users remove bob --ja
check "users remove calls userdel without -r" has "$calls" "userdel bbs-bob"
kar=$(ls -d "$root"/_karantan-users-*/bob 2>/dev/null | head -n 1)
check "users remove removes the alias before userdel" has "$calls" "bbs-alias remove bob"
check "users remove never uses userdel -r" not_has "$calls" "userdel -r"
check "users remove moves the home to quarantine" test -f "$kar/home/.mail"
check "users remove moves the key file to quarantine" test -f "$kar/keys"
check "users remove moves users/<name> to quarantine" test -f "$kar/users/profile"
check "users remove leaves no users/<name> behind" test ! -e "$root/users/bob"

# 7. --as: only for root itself (the sorter), never through sudo or as a user
echo carol >> "$root/sysops"
: > "$calls"
asrun() { # asrun <env...> -- <args...>
    local e=()
    while [[ $1 != -- ]]; do e+=("$1"); shift; done; shift
    env -u SUDO_USER "${e[@]}" BASHBBS_TEST=1 BBS_ROOT=$root BBS_SBIN=$sbin \
        BBS_GETENT=$sbin/getent BBS_USERMOD=$sbin/usermod BBS_USERDEL=$sbin/userdel \
        BBS_PKILL=$sbin/pkill BBS_CHOWN=$sbin/chown \
        "$here/sbin/bbs-admin" "$@" >"$out" 2>&1; rc=$?; cat "$out" >>"$log"; }
asrun -- apps accept 77aa --as carol --ja
check "--as refused when not root" rc_is "$rc" 1
asrun BBS_TEST_EUID=0 SUDO_USER=coffe -- apps accept 77aa --as carol --ja
check "--as refused through sudo (SUDO_USER set)" rc_is "$rc" 1
asrun BBS_TEST_EUID=0 SUDO_USER= -- apps accept 77aa --as carol --ja
check "--as refused with SUDO_USER set but empty" rc_is "$rc" 1
check "refused --as ran nothing" empty "$calls"
asrun BBS_TEST_EUID=0 -- apps accept 77aa --as mallory --ja
check "--as refuses a name not in sysops" rc_is "$rc" 1
asrun BBS_TEST_EUID=0 -- apps accept 77aa --as carol --ja
check "--as accepted for root without sudo" rc_is "$rc" 0
check "--as runs the command" has "$calls" "bbs-svara accept 77aa"
check "--as logs the named sysop" grep -qP '\tcarol\tapps accept 77aa$' "$root/state/admin.log"
asrun BBS_TEST_EUID=0 -- users disable carol --as carol --ja
check "--as still refuses your own account" rc_is "$rc" 1

# 8. Guard: other sysops and system accounts
: > "$calls"
run users disable carol --ja
check "users disable refuses another sysop" rc_is "$rc" 1
run users remove carol --ja
check "users remove refuses another sysop" rc_is "$rc" 1
run users disable news --ja
check "users disable refuses bbs-news" rc_is "$rc" 1
run users remove newsstatus --ja
check "users remove refuses bbs-newsstatus" rc_is "$rc" 1
run alias remove carol --ja
check "alias remove refuses another sysop" rc_is "$rc" 1
run alias remove coffe --ja
check "alias remove refuses yourself" rc_is "$rc" 1
check "guards ran no tool" not_has "$calls" "usermod"
check "guards ran no alias change" not_has "$calls" "bbs-alias"
run users enable carol --ja
check "users enable is allowed for another sysop" rc_is "$rc" 0

# 9. alias subcommands
: > "$calls"
run alias check bob
check "alias check runs bbs-alias check" has "$calls" "bbs-alias check bob"
run alias check "Bad;x"
check "alias check refuses a bad name" rc_is "$rc" 1
: > "$calls"
run alias add bob
check "alias add without --ja is a dry run" rc_is "$rc" 0
check "alias add dry run calls nothing" not_has "$calls" "bbs-alias add"
run alias add ghost --ja
check "alias add refuses an unknown account" rc_is "$rc" 1
run alias add bob --ja
check "alias add --ja calls bbs-alias add" has "$calls" "bbs-alias add bob"
check "alias add is logged" has "$root/state/admin.log" "alias add bob"
run alias remove bob
check "alias remove without --ja is a dry run" not_has "$calls" "bbs-alias remove bob"
run alias remove bob --ja
check "alias remove --ja calls bbs-alias remove" has "$calls" "bbs-alias remove bob"
check "alias remove is logged" has "$root/state/admin.log" "alias remove bob"
run alias frob bob
check "unknown alias subcommand prints usage" rc_is "$rc" 64
run alias add bob --as carol --ja
check "--as refused for a non-root caller" rc_is "$rc" 1

echo "pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
