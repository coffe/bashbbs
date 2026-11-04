#!/bin/bash
# Inherited unread marks: a gold * on a board row with a new thread, on Public/Private
# boards when one of their boards has one, and on Boards in the main menu. Own posts do
# not count, a read thread clears the mark, boards the user cannot see are not scanned
# (a 000 directory here), and redraws do not rescan (only a new visit does).
# Everything uses a temporary BBS_ROOT. Usage: tests/unread_marks_test.sh [logfile]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/unread_marks_test.log}
: > "$log"
pass=0; fail=0
check() { local d=$1; shift
    if "$@" >>"$log" 2>&1; then pass=$((pass + 1)); echo "ok   $d" >>"$log"
    else fail=$((fail + 1)); echo "FAIL $d" | tee -a "$log"; fi; }
eq() { [[ $1 == "$2" ]]; }
not() { ! "$@"; }
has() { grep -qF -- "$2" <<< "$1"; }

[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

root=$(mktemp -d "$scratch/um.XXXXXX")
T0=1500000000
SEEN=$((T0 + 100))   # login epoch: posts newer than this are new
mkdir -p "$root"/{boards/general,boards/sharednews,boards/whatsup,boards/priv,meta,home}
mkdir -p "$root/boards/secret"

# post <board> <epoch> <id> <author> [parent]
post() {
    local f=$root/boards/$1/$2-$3.msg
    {
        printf 'Msgid: %s\nAuthor: %s\nNode: n\nDate: 2017-07-14T04:00:00+00:00\nSubject: Post %s\n' "$3" "$4" "$3"
        [[ -n ${5:-} ]] && printf 'Parent: %s\n' "$5"
        printf '\nBody of %s\n' "$3"
    } > "$f"
}
post general "$((T0 + 10))" o1 bbs-bob            # old, before the login epoch
post general "$((T0 + 200))" n1 bbs-bob           # new thread from someone else
post sharednews "$((T0 + 300))" mine bbs-alice    # new, but written by the viewer
post whatsup "$((T0 + 20))" w1 bbs-bob            # only old posts
post priv "$((T0 + 400))" p1 bbs-bob              # new in a private board the viewer is in
post secret "$((T0 + 500))" s1 bbs-bob            # new, but the viewer may not see it
chmod 000 "$root/boards/secret"

# Private membership is group ownership in production; here "priv*" stands for a private board.
helpers=$root/helpers.sh
cat > "$helpers" <<'EOF'
board_is_private() { [[ $(basename "$1") == priv* ]]; }
scan() {
    UNREAD_STALE=1; unread_refresh
    echo "pub=$UNREAD_PUB priv=$UNREAD_PRIV boards=$(printf '%s\n' "${!UNREAD[@]}" | sort | tr '\n' ' ')"
}
cache_test() {
    UNREAD_STALE=1; unread_refresh
    printf 'Msgid: c1\nAuthor: bbs-bob\nSubject: late\n\nb\n' > "$BBS_ROOT/boards/whatsup/$((1500000600))-c1.msg"
    unread_refresh
    [[ -z ${UNREAD[whatsup]:-} ]] && echo cache-hold
    UNREAD_STALE=1; unread_refresh
    [[ -n ${UNREAD[whatsup]:-} ]] && echo cache-refresh
}
EOF

lib() { ( export BBS_ROOT="$root" HOME="$root/home" BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-alice TERM=dumb \
          BASHBBS_SEEN_PREV="$SEEN" BASHBBS_COLOR=0 COLUMNS=80
          source "$here/lib/menu.sh"; source "$helpers"; "$@" ); }

# 1. Scan: which boards are starred, and the parent flags.
out=$(lib scan)
check "scan: board with a new thread is marked, parents set" has "$out" "pub=1 priv=1 boards=general priv "
check "scan: own post does not mark its board" not has "$out" "sharednews"
check "scan: board with only old posts is not marked" not has "$out" "whatsup"
check "scan: board the viewer cannot see is not scanned" not has "$out" "secret"

# 2. Rendering in the menus, with the gold * after the row label.
check "boards: Public boards row shows *" has "$(printf 'q' | lib boards_home)" "Public boards *"
check "boards: Private boards row shows *" has "$(printf 'q' | lib boards_home)" "Private boards *"
check "main: Boards row shows *" has "$(printf '1' | lib main_menu)" "Boards *"
check "board list: The Pub row shows *" has "$(printf 'q' | lib board_menu public)" "The Pub *"
check "board list: Shared News (own post only) shows no *" not has "$(printf 'q' | lib board_menu public)" "Shared News *"
check "board list: What's up?! (old only) shows no *" not has "$(printf 'q' | lib board_menu public)" "What's up?! *"

# 3. Read state: reading the new thread clears its mark; the parent only follows the rest.
lib read_mark_save general n1 "$((T0 + 200))"
out=$(lib scan)
check "read: read thread clears the board mark" not has "$out" "general"
check "read: parent flag follows remaining marks (private still new)" has "$out" "pub=0 priv=1 boards=priv "
check "read: main menu keeps * while private is still new" has "$(printf '1' | lib main_menu)" "Boards *"
lib read_mark_save priv p1 "$((T0 + 400))"
check "read: main menu loses * when nothing is new" not has "$(printf '1' | lib main_menu)" "Boards *"

# 4. Caching: a redraw does not rescan, a new visit does.
out=$(lib cache_test)
check "cache: a redraw without a new visit keeps the old scan" has "$out" "cache-hold"
check "cache: a new visit rescans and marks the new board" has "$out" "cache-refresh"

echo "unread_marks_test: $pass passed, $fail failed (log: $log)"
chmod 700 "$root/boards/secret" 2>/dev/null
[[ $fail -eq 0 ]]
