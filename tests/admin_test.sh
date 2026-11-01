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
run users remove bob --ja
check "users remove calls userdel without -r" has "$calls" "userdel bbs-bob"
kar=$(ls -d "$root"/_karantan-users-*/bob 2>/dev/null | head -n 1)
check "users remove removes the alias before userdel" has "$calls" "bbs-alias remove bob"
check "users remove never uses userdel -r" not_has "$calls" "userdel -r"
check "users remove moves the home to quarantine" test -f "$kar/home/.mail"
check "users remove moves the key file to quarantine" test -f "$kar/keys"

echo "pass=$pass fail=$fail" | tee -a "$log"
[[ $fail -eq 0 ]]
