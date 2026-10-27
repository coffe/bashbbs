#!/bin/bash
# Stage A acceptance tests. Run from jelly against the Pi (host zero).
# Needs two test accounts, provisioned by bbs-provision, with keys in $KEYDIR.
set -u
HOST=${HOST:-zero}
KEYDIR=${KEYDIR:?set KEYDIR to a directory with testa and testb keys}
pass=0; fail=0
check() { # check <description> <expected: 0|nonzero> <command...>
    local desc=$1 want=$2; shift 2
    "$@" >/dev/null 2>&1; local rc=$?
    if { [[ $want == 0 ]] && (( rc == 0 )); } || { [[ $want != 0 ]] && (( rc != 0 )); }; then
        echo "PASS $desc"; pass=$((pass + 1))
    else
        echo "FAIL $desc (rc=$rc)"; fail=$((fail + 1))
    fi
}
ssh_as() { # ssh_as <user> <extra ssh args...>
    local u=$1; shift
    timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -i "$KEYDIR/$u" "$@" "bbs-$u@$HOST"
}

check "key login reaches menu"            0 bash -c "echo 'q' | timeout 20 ssh -tt -o BatchMode=yes -i $KEYDIR/testa bbs-testa@$HOST"
check "password login refused"            1 timeout 20 ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o BatchMode=yes bbs-testa@$HOST true
check "sftp refused"                      1 bash -c "echo ls | timeout 20 sftp -o BatchMode=yes -i $KEYDIR/testa bbs-testa@$HOST"
check "local port forward refused"        1 timeout 10 ssh -N -o ExitOnForwardFailure=yes -L 19999:localhost:22 -o BatchMode=yes -i $KEYDIR/testa bbs-testa@$HOST
check "remote command ignored (no shell)" 1 bash -c "timeout 20 ssh -o BatchMode=yes -i $KEYDIR/testa bbs-testa@$HOST 'id -u' | grep -qx 0"
check "cannot read other user's home"     1 ssh_as testa "ls /srv/bashbbs/home/testb"
check "cannot write into keys dir"        1 ssh_as testa "touch /srv/bashbbs/keys/bbs-testa.x"
check "cannot write into boards"          1 ssh_as testa "touch /srv/bashbbs/boards/general/x.msg"

echo "pass=$pass fail=$fail"
[[ $fail == 0 ]]
