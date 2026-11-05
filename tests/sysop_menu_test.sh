#!/bin/bash
# Sysop menu: shown only to sysops, hidden by sysop-menu=off, read-only screens with
# plain-English status, red only when colour is on. Everything runs in a temporary BBS_ROOT
# with a stubbed systemctl. Usage: tests/sysop_menu_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/sysop_menu_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/sysop.XXXXXX")
mkdir -p "$root"/{boards/general,boards/whatsup,applications/incoming,state/apps-waiting,users/sys0p,users/bob,users/ghost,meta,home,bin}
printf 'sys0p\n' > "$root/sysops"   # login names without bbs-, as install.sh uses
printf 'name=Sysop\n' > "$root/users/sys0p/profile"
printf 'name=Bob\n' > "$root/users/bob/profile"
printf 'name=Ghost\nhidden=yes\n' > "$root/users/ghost/profile"

# post <board> <epoch> <id> <author> <subject> [deleted]
post() {
    {
        printf 'Msgid: %s\nAuthor: %s\nDate: 2026-11-04T10:00:00+00:00\nSubject: %s\n' "$3" "$4" "$5"
        [[ -n ${6:-} ]] && printf 'Deleted: 2026-11-04T11:00:00+00:00\n'
        printf '\nSECRET BODY %s\n' "$3"
    } > "$root/boards/$1/$2-$3.msg"
}
post general 1500000100 old bbs-bob "Old post"
post general 1500000400 gone bbs-bob "Removed post" deleted
post whatsup 1500000300 new bbs-kitty "Newest post"
printf '1500000050\t-\talice\n' > "$root/state/apps-waiting/sys0p"   # the sorter's list, not incoming/

# Stub systemctl: sshd-style units are fine, bbs-drop.timer is failed.
cat > "$root/bin/systemctl" <<'EOF'
#!/bin/bash
case $2 in bbs-drop.timer) echo failed; exit 3 ;; *) echo active ;; esac
EOF
chmod +x "$root/bin/systemctl"

lib() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-sys0p TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=80 PATH="$root/bin:$PATH"
          source "$here/lib/menu.sh"; "$@" ); }
lib_as() { local who=$1; shift; ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=$who TERM=dumb \
          BASHBBS_COLOR=0 COLUMNS=80 PATH="$root/bin:$PATH"
          source "$here/lib/menu.sh"; "$@" ); }

lib_colour() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-sys0p TERM=dumb \
          BASHBBS_COLOR=1 COLUMNS=80 PATH="$root/bin:$PATH"
          source "$here/lib/menu.sh"; "$@" ); }

# 1. Visibility in the main menu.
check "bob (not a sysop): no Sysop item" not has "$(printf 'q' | lib_as bbs-bob main_menu)" "Sysop"
check "sys0p: Sysop item shown" has "$(printf 'q' | lib main_menu)" "Sysop"
echo off > "$root/sysop-menu"
check "sysop-menu=off: Sysop item hidden" not has "$(printf 'q' | lib main_menu)" "Sysop"
check "sysop-menu=off: sysop_menu prints nothing" bash -c '[[ -z $("$@") ]]' _ lib sysop_menu
rm -f "$root/sysop-menu"
check "sysop-menu missing: Sysop item shown (default on)" has "$(printf 'q' | lib main_menu)" "Sysop"

# 2. The sysop screen has six read-only items and goes back on Q.
out=$(printf 'q' | lib sysop_menu)
check "sysop menu: lists Status, Applications, Recent posts, Users" bash -c \
    '[[ $1 == *Status* && $1 == *Applications* && $1 == *"Recent posts"* && $1 == *Users* ]]' _ "$out"
check "sysop menu: lists Transfers and Quota" bash -c '[[ $1 == *Transfers* && $1 == *Quota* ]]' _ "$out"
out=$(printf 'q' | lib main_menu)
check "main menu: Files is 8 and Sysop is 9" bash -c '[[ $1 == *"8) Files"* && $1 == *"9) Sysop"* ]]' _ "$out"
out=$(printf 'q' | lib_as bbs-bob main_menu)
check "main menu: Files is shown to everybody" has "$out" "8) Files"

# 3. Status: plain English, DOWN for the failed unit, counts shown.
out=$(printf '\n' | lib sysop_status)
check "status: running units say running" has "$out" "running"
check "status: failed unit says DOWN (failed)" has "$out" "DOWN (failed)"
check "status: account count shown" has "$out" "Accounts:"
check "status: waiting applications counted" bash -c '[[ $1 == *"Applications waiting: 1"* ]]' _ "$out"

# 4. Recent posts: newest first, deleted hidden, no bbs- prefix, no body.
out=$(printf '\n' | lib sysop_posts)
check "posts: newest first" bash -c '[[ $1 == *"Newest post"*"Old post"* ]]' _ "$out"
check "posts: deleted post hidden" not has "$out" "Removed post"
check "posts: no bbs- prefix on author" not has "$out" "bbs-kitty"
check "posts: author shown without prefix" has "$out" "kitty"
check "posts: body never shown" not has "$out" "SECRET BODY"

# 5. Applications: listed read-only, with the date from the filename.
out=$(printf '\n' | lib sysop_applications)
check "applications: applicant listed" has "$out" "alice"
check "applications: says how to decide" has "$out" "Number) Decide"
: > "$root/state/apps-waiting/sys0p"
out=$(printf '\n' | lib sysop_applications)
check "applications: empty message when none wait" has "$out" "No applications waiting."
printf '1500000050\t-\t\033[31mevil\n' > "$root/state/apps-waiting/sys0p"
out=$(printf '\n' | lib sysop_applications)
check "applications: control bytes in a name are made safe" bash -c '[[ $1 != *$'"'"'\033[31m'"'"'* ]]' _ "$out"
printf '1500000050\t-\talice\n' > "$root/state/apps-waiting/sys0p"

# 6. Users: hidden and sysop markers, no profile contents beyond the name.
out=$(printf '\n' | lib sysop_users)
check "users: hidden account marked" bash -c '[[ $1 == *Ghost*hidden* ]]' _ "$out"
check "users: sysop marked" bash -c '[[ $1 == *Sysop*sysop* ]]' _ "$out"
check "users: plain user has no marker" bash -c '[[ $(grep -E "^ *[0-9]+\) Bob " <<< "$1") != *hidden* && $(grep -E "^ *[0-9]+\) Bob " <<< "$1") != *sysop* && -n $(grep -E "^ *[0-9]+\) Bob " <<< "$1") ]]' _ "$out"

# 7. Red only with colour on.
red=$'\033[1;31m'
check "colour off: no red escape in status" not has "$(printf '\n' | lib sysop_status)" "$red"
out=$(printf '\n' | lib_colour sysop_status)
check "colour on: DOWN is red" has "$out" "$red"

# 8. Request side: a fake root sorter answers every request in queue/admin.
mkdir -p "$root/queue/admin" "$root/state/admin-results" "$root/seen"
printf 'bbs-bob:x:2001:2001::/home/bbs-bob:/usr/local/sbin/bbs-shell\nbob:x:2001:2001::/home/bbs-bob:/usr/local/sbin/bbs-shell\nbbs-ghost:x:2002:2002::/h:/usr/sbin/nologin\nbbs-sys0p:x:2003:2003::/h:/bin/true\n' > "$root/passwd"
cat > "$root/bin/getent" <<EOF
#!/bin/bash
[[ \$1 == passwd ]] || exit 2
if [[ -n \${2:-} ]]; then grep "^\$2:" "$root/passwd"; else cat "$root/passwd"; fi
EOF
chmod +x "$root/bin/getent"
printf '%s\t%s\t2026-11-01\tweb\t-\t0\n' 'SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' laptop > "$root/users/bob/keys.meta"
mkdir -p "$root/state"
printf '2026-11-01T10:00Z bob\n2026-11-02T10:00Z bob\n2026-11-03T10:00Z ghost\n' > "$root/state/callers.log"
# fake_root <seconds>: answer requests with status=0 and keep a copy of each in seen/
fake_root() {
    local end=$((SECONDS + $1)) f id
    while (( SECONDS < end )); do
        for f in "$root"/queue/admin/*.req; do
            [[ -e $f ]] || continue
            id=$(sed -n 's/^id=//p' "$f")
            cp "$f" "$root/seen/$id.req"
            printf 'status=0\nDONE %s\n' "$(sed -n 's/^action=//p' "$f")" > "$root/state/admin-results/$id"
            rm -f "$f"
        done
        sleep 0.1
    done
}
clear_seen() { find "$root/seen" -type f -delete; }
nothing_queued() { [[ $(find "$root/seen" -type f | wc -l) -eq 0 ]]; }
fake_root 150 & fake_pid=$!
trap 'kill $fake_pid 2>/dev/null' EXIT

# 8a. admin_request writes the fixed fields atomically and shows the result.
out=$(lib admin_request users-disable name=bob)
check "admin_request: result shown" has "$out" "DONE users-disable"
check "admin_request: status line not shown" not has "$out" "status="
req=$(cat "$root"/seen/*.req | tr '\n' ' ')
check "admin_request: request has id, action and name" bash -c '[[ $1 == *"action=users-disable"* && $1 == *"name=bob"* && $1 == *"id="* ]]' _ "$req"
check "admin_request: no dot file left in queue" bash -c '[[ -z $(ls -A "$1/queue/admin") ]]' _ "$root"
clear_seen

# 8b. Timeout when nobody answers.
mkdir -p "$root/noroot/q" "$root/noroot/r"
out=$(BBS_ADMIN_QUEUE=$root/noroot/q BBS_ADMIN_RESULTS=$root/noroot/r BBS_ADMIN_WAIT=1 lib admin_request users-enable name=bob)
check "admin_request: timeout message" has "$out" "Queued, check Status later"
check "admin_request: timeout leaves the .req queued" bash -c 'ls "$1"/*.req >/dev/null' _ "$root/noroot/q"

# 8c. Applications: accept and reject need y; code comes from the file name.
printf '1500000060\t0123abcd\tcarol\n' > "$root/state/apps-waiting/sys0p"
out=$(printf '1ay' | lib sysop_applications)
check "applications: accept shows result" has "$out" "DONE apps-accept"
check "applications: accept request has code" bash -c 'grep -qx "code=0123abcd" "$1"/seen/*.req && grep -qx "action=apps-accept" "$1"/seen/*.req' _ "$root"
clear_seen
out=$(printf '1ry' | lib sysop_applications)
check "applications: reject shows result" has "$out" "DONE apps-reject"
clear_seen
printf '1an' | lib sysop_applications >/dev/null
printf '1rx' | lib sysop_applications >/dev/null
printf 'q' | lib sysop_applications >/dev/null
check "applications: n, other key and Q queue nothing" nothing_queued

# 8d. Users: detail view. Listed in glob order: bob, ghost, sys0p.
out=$(printf '1q' | lib sysop_users)
check "user detail: account" has "$out" "bbs-bob"
check "user detail: short name from same uid" bash -c '[[ $1 == *"Short name:"*" bob"* ]]' _ "$out"
check "user detail: active" bash -c '[[ $1 == *"Status:"*active* ]]' _ "$out"
check "user detail: call count" bash -c '[[ $1 == *"Calls:"*" 2"* ]]' _ "$out"
check "user detail: key count and fingerprint" bash -c '[[ $1 == *"Keys:"*" 1"* && $1 == *SHA256:aaaa* ]]' _ "$out"
check "user detail: quota shown" has "$out" "of 200.0 MB"
out=$(printf '2q' | lib sysop_users)
check "user detail: suspended account says suspended" bash -c '[[ $1 == *"Status:"*suspended* && $1 == *Unsuspend* ]]' _ "$out"

# 8e. Suspend / unsuspend / remove.
out=$(printf '1sy' | lib sysop_users)
check "suspend: result shown" has "$out" "DONE users-disable"
check "suspend: request names bob" bash -c 'grep -qx "name=bob" "$1"/seen/*.req && grep -qx "action=users-disable" "$1"/seen/*.req' _ "$root"
clear_seen
printf '1sn' | lib sysop_users >/dev/null
check "suspend: n queues nothing" nothing_queued
out=$(printf '2sy' | lib sysop_users)
check "unsuspend: result shown" has "$out" "DONE users-enable"
check "unsuspend: request names ghost" bash -c 'grep -qx "name=ghost" "$1"/seen/*.req' _ "$root"
clear_seen
out=$(printf '1xno\n' | lib sysop_users)
check "remove: warns about quarantine and name reuse" bash -c '[[ $1 == *quarantine* && $1 == *"never given out again"* ]]' _ "$out"
printf '1xbo\n' | lib sysop_users >/dev/null
printf '1x\n' | lib sysop_users >/dev/null
check "remove: wrong or empty name queues nothing" nothing_queued
out=$(printf '1xbob\n' | lib sysop_users)
check "remove: typed name queues users-remove" has "$out" "DONE users-remove"
check "remove: request has action and name" bash -c 'grep -qx "name=bob" "$1"/seen/*.req && grep -qx "action=users-remove" "$1"/seen/*.req' _ "$root"
clear_seen

# 8f. Refusals happen in the menu, before anything is queued.
mkdir -p "$root/users/news" "$root/users/other"
printf 'name=News\n' > "$root/users/news/profile"; printf 'name=Other\n' > "$root/users/other/profile"
printf 'other\n' >> "$root/sysops"
# glob order: bob ghost news other sys0p
out=$(printf '5sy5xsys0p\n' | lib sysop_users)
check "refuse: self" has "$out" "Cannot be suspended or removed"
out=$(printf '3sy3xzz\n' | lib sysop_users)
check "refuse: system account news" has "$out" "Cannot be suspended or removed"
out=$(printf '4sy4xother\n' | lib sysop_users)
check "refuse: another sysop" has "$out" "Cannot be suspended or removed"
check "refuse: nothing was queued" nothing_queued
# 9. Keys: add (validated in the menu) and remove by number. bob has one key in keys.meta.
clear_seen
ssh-keygen -q -t ed25519 -N '' -C 'new@host' -f "$root/newkey" >/dev/null
goodkey=$(cat "$root/newkey.pub")
out=$(printf '1kaNOT A KEY\nq' | lib sysop_users)
check "keys add: bad key rejected" has "$out" "Not a plain public key line"
out=$(printf '1kassh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nq' | lib sysop_users)
check "keys add: right shape but not a key rejected by ssh-keygen" has "$out" "ssh-keygen does not accept"
check "keys add: bad keys queue nothing" nothing_queued
out=$(printf '1ka%s\nn' "$goodkey" | lib sysop_users)
check "keys add: n queues nothing" nothing_queued
out=$(printf '1ka%s\ny ' "$goodkey" | lib sysop_users)
check "keys add: result shown" has "$out" "DONE keys-add"
check "keys add: request has name and key" bash -c 'grep -qx "name=bob" "$1"/seen/*.req && grep -qxF "key=$2" "$1"/seen/*.req && grep -qx "action=keys-add" "$1"/seen/*.req' _ "$root" "$goodkey"
clear_seen
out=$(printf '1kr1\ny ' | lib sysop_users)
check "keys remove: result shown" has "$out" "DONE keys-remove"
check "keys remove: request has fingerprint" bash -c 'grep -qx "fingerprint=SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$1"/seen/*.req && grep -qx "name=bob" "$1"/seen/*.req' _ "$root"
clear_seen
out=$(printf '1kr9\n' | lib sysop_users)
check "keys remove: bad number queues nothing" nothing_queued
# Protected: key may be added, not removed.
out=$(printf '5kr' | lib sysop_users)
check "keys remove: protected account refused" has "$out" "not removed here"
check "keys remove: protected queues nothing" nothing_queued
out=$(printf '5ka%s\ny ' "$goodkey" | lib sysop_users)
check "keys add: protected account allowed" has "$out" "DONE keys-add"
clear_seen

# 10. Short name: alias-check, then add; with a short name, remove.
out=$(printf '2ny y ' | lib sysop_users)   # ghost has no short name
check "alias: check result shown" has "$out" "DONE alias-check"
check "alias: add result shown" has "$out" "DONE alias-add"
check "alias: check and add requests name ghost" bash -c 'for a in alias-check alias-add; do grep -lx "action=$a" "$1"/seen/*.req | xargs grep -qx "name=ghost" || exit 1; done' _ "$root"
clear_seen
out=$(printf '2nn' | lib sysop_users)
check "alias: n after check does not add" bash -c '! grep -lx "action=alias-add" "$1"/seen/*.req' _ "$root"
clear_seen
out=$(printf '1ny ' | lib sysop_users)   # bob has the short name bob
check "alias: remove result shown" has "$out" "DONE alias-remove"
check "alias: remove request names bob" bash -c 'grep -qx "name=bob" "$1"/seen/*.req && grep -qx "action=alias-remove" "$1"/seen/*.req' _ "$root"
clear_seen
out=$(printf '5n' | lib sysop_users)
check "alias: protected account short name not removed here" bash -c '[[ $1 == *"Not removed here"* || $1 == *"Checking whether"* ]]' _ "$out"
kill $fake_pid 2>/dev/null

# 11. Mail all: one sendmail call, every non-suspended account, To: all@.
cat > "$root/bin/fakemail" <<MAILEOF
#!/bin/bash
mkdir -p "$root/mailcalls"
n=\$(ls "$root"/mailcalls/*.args 2>/dev/null | wc -l)
printf '%s\n' "\$@" > "$root/mailcalls/\$n.args"
cat > "$root/mailcalls/\$n.msg"
MAILEOF
chmod +x "$root/bin/fakemail"
mkdir -p "$root/users/hid"; printf 'name=Hid\nhidden=yes\n' > "$root/users/hid/profile"
printf 'bbs-hid:x:2004:2004::/h:/usr/local/sbin/bbs-shell\n' >> "$root/passwd"
rm -rf "$root/mailcalls"
out=$(printf 'Hello all\nLine one\n.\ny ' | BBS_SENDMAIL="$root/bin/fakemail" lib sysop_mail_all)
check "mail all: asks with the count" has "$out" "Send to 3 users? [y/N]"
check "mail all: one sendmail call" bash -c '[[ $(ls "$1"/mailcalls/*.args | wc -l) -eq 1 ]]' _ "$root"
args=$(tr '\n' ' ' < "$root/mailcalls/0.args" 2>/dev/null)
check "mail all: -f bbs-sys0p" has "$args" "-f bbs-sys0p"
check "mail all: active and hidden recipients" bash -c '[[ $1 == *bbs-bob* && $1 == *bbs-hid* && $1 == *bbs-sys0p* ]]' _ "$args"
check "mail all: suspended, system and unknown excluded" bash -c '[[ $1 != *bbs-ghost* && $1 != *bbs-news* && $1 != *bbs-other* ]]' _ "$args"
msg=$(cat "$root/mailcalls/0.msg" 2>/dev/null)
check "mail all: header To is all@ only" bash -c '[[ $1 == *"To: all@bbs.localdomain"* && $1 != *"To: bbs-"* && $1 == *"Subject: Hello all"* && $1 == *"From: sys0p@"* && $1 == *"Line one"* ]]' _ "$msg"
check "mail all: copy kept in Sent" bash -c '[[ -n $(find "$1" -path "*Sent*" -type f 2>/dev/null) ]]' _ "$root/home"
rm -rf "$root/mailcalls"
out=$(printf 'Hello\nx\n.\nn' | BBS_SENDMAIL="$root/bin/fakemail" lib sysop_mail_all)
check "mail all: n sends nothing" bash -c '[[ ! -d $1/mailcalls ]]' _ "$root"
out=$(printf 'q' | lib sysop_menu)
check "sysop menu: lists Mail all" has "$out" "Mail all"


echo "sysop_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
