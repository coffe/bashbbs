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
mkdir -p "$root"/{boards/general,boards/whatsup,applications/incoming,users/sys0p,users/bob,users/ghost,meta,home,bin}
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
printf 'name=alice\n' > "$root/applications/incoming/1500000050-alice.app"

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
check "applications: says how to decide" has "$out" "Approve or reject"
rm -f "$root/applications/incoming"/*.app
out=$(printf '\n' | lib sysop_applications)
check "applications: empty message when none wait" has "$out" "No applications waiting."
printf 'name=alice\n' > "$root/applications/incoming/1500000050-alice.app"

# 6. Users: hidden and sysop markers, no profile contents beyond the name.
out=$(printf '\n' | lib sysop_users)
check "users: hidden account marked" bash -c '[[ $1 == *Ghost*hidden* ]]' _ "$out"
check "users: sysop marked" bash -c '[[ $1 == *Sysop*sysop* ]]' _ "$out"
check "users: plain user has no marker" bash -c '[[ $(grep "^Bob " <<< "$1") != *hidden* && $(grep "^Bob " <<< "$1") != *sysop* && -n $(grep "^Bob " <<< "$1") ]]' _ "$out"

# 7. Red only with colour on.
red=$'\033[1;31m'
check "colour off: no red escape in status" not has "$(printf '\n' | lib sysop_status)" "$red"
out=$(printf '\n' | lib_colour sysop_status)
check "colour on: DOWN is red" has "$out" "$red"

echo "sysop_menu_test: $pass passed, $fail failed (log: $log)"
[[ $fail -eq 0 ]]
