#!/bin/bash
# BashBBS main menu. Runs as the login shell of a bbs-<name> account.
# Input is read line by line with read -r and never reaches eval or a shell.
set -u
umask 077

BBS_ROOT=/srv/bashbbs
LIB=/usr/local/lib/bashbbs
me=${USER#bbs-}
[[ $me =~ ^[a-z][a-z0-9]{2,15}$ ]] || { echo "bad account" >&2; exit 1; }

# Strip control characters (ESC, CR, BEL, ...) from text shown to the user.
safe() { LC_ALL=C.UTF-8 sed 's/[[:cntrl:]]//g'; }

pause() { read -r -p "[Enter] " _ || true; }

# Accept a name only if it matches the naming rule and a profile exists.
valid_user() {
    [[ $1 =~ ^[a-z][a-z0-9]{2,15}$ ]] && [[ -f $BBS_ROOT/users/$1/profile ]]
}

list_users() {
    local f name uuid
    for f in "$BBS_ROOT"/users/*/profile; do
        [[ -f $f && ! -L $f ]] || continue
        name=$(sed -n 's/^name=//p' "$f" | safe)
        uuid=$(sed -n 's/^uuid=//p' "$f" | safe)
        printf '%-16s %s\n' "$name" "$uuid"
    done
}

my_account() {
    local uuid keys
    uuid=$(sed -n 's/^uuid=//p' "$BBS_ROOT/users/$me/profile" 2>/dev/null | safe)
    keys=$(grep -c . "$BBS_ROOT/keys/$USER" 2>/dev/null || echo 0)
    echo "Name:  $me"
    echo "UUID:  $uuid"
    echo "Keys:  $keys registered"
}

# ---- Navigation -------------------------------------------------------------

# Quick keys work on every screen. nav_key sets nav_req and the screen returns
# at once; the loop at the bottom then opens the section that was asked for.
nav_req=

top_bar() {
    echo "[B] Boards  [P] Mail  [M] Main  [G] Goodbye  $1"
    echo
}

nav_key() {
    case $1 in
        [Bb]) nav_req=boards ;;
        [Pp]) nav_req=mail ;;
        [Mm]) nav_req=main ;;
        [Gg]) nav_req=quit ;;
        *) return 1 ;;
    esac
}

# ---- Stage B: public boards -------------------------------------------------

board_menu() {
    local boards b choice
    while true; do
        clear
        top_bar "[Q] Back"
        echo "== Public boards =="
        boards=()
        for b in "$BBS_ROOT"/boards/*/; do
            b=${b%/}
            # Private boards stay hidden from users who are not members.
            [[ -d $b && ! -L $b && -r $b && -x $b ]] || continue
            boards+=("$(basename "$b")")
        done
        local i=1
        for b in "${boards[@]}"; do
            echo "$i) $b"
            i=$((i + 1))
        done
        echo "K) New private board   Q) Back"
        read -r -p "> " choice || return
        nav_key "$choice" && return
        case $choice in
            [Qq]) return ;;
            [Kk]) new_private_board; continue ;;
            ''|*[!0-9]*) continue ;;
        esac
        (( choice >= 1 && choice <= ${#boards[@]} )) || continue
        board_view "${boards[choice - 1]}"
        [[ -n $nav_req ]] && return
    done
}

board_view() {
    local board=$1 f n body choice reply
    local -a files=()
    while true; do
        clear
        top_bar "[Q] Back"
        echo "== $board =="
        files=()
        for f in "$BBS_ROOT"/boards/"$board"/*.msg; do
            [[ -f $f && ! -L $f ]] || continue
            files+=("$f")
        done
        local i=1
        for f in "${files[@]}"; do
            printf '%3d) %s\n' "$i" "$(sed -n 's/^Subject: //p' "$f" | head -n 1 | safe)"
            i=$((i + 1))
        done
        if is_readonly "$board"; then
            echo "Q) Back"
        elif manages "$board"; then
            echo "N) New post   S) Members   Q) Back"
        else
            echo "N) New post   Q) Back"
        fi
        read -r -p "> " choice || return
        nav_key "$choice" && return
        case $choice in
            [Qq]) return ;;
            [Nn]) is_readonly "$board" || compose "$board" ""; continue ;;
            [Ss]) manages "$board" && members_menu "$board"; continue ;;
            ''|*[!0-9]*) continue ;;
        esac
        (( choice >= 1 && choice <= ${#files[@]} )) || continue
        clear
        f=${files[choice - 1]}
        head -c 16384 "$f" | safe
        echo
        read -r -p "R) Reply   [Enter] Back: " reply || return
        nav_key "$reply" && return
        if [[ $reply == [Rr] ]] && ! is_readonly "$board"; then
            thread=$(sed -n 's/^Msgid: //p' "$f" | head -n 1 | safe)
            compose "$board" "$thread"
        fi
    done
}

# Write one post into the queue. The publisher checks it and copies it
# into boards/. Users cannot write into boards/ themselves.
compose() {
    local board=$1 parent=$2 subject line count=0 tmp
    read -r -p "Subject: " subject || return
    subject=$(printf '%s' "$subject" | safe | head -c 100)
    [[ -n $subject ]] || return
    echo "Write your text. End with a line containing only a dot."
    tmp=$(mktemp "$BBS_ROOT/queue/incoming/.tmp.XXXXXX") || return
    {
        printf 'Board: %s\n' "$board"
        printf 'Subject: %s\n' "$subject"
        [[ -n $parent ]] && printf 'Parent: %s\n' "$parent"
        printf '\n'
        while IFS= read -r line; do
            [[ $line == . ]] && break
            count=$((count + 1))
            (( count > 200 )) && break
            printf '%s\n' "$line" | safe
        done
    } > "$tmp"
    mv -f "$tmp" "$BBS_ROOT/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).post"
    echo "Sent to the publisher. It appears within a minute."
    pause
}

# ---- Stage C: private boards ------------------------------------------------

is_sysop() { grep -qx -- "$me" "$BBS_ROOT/sysops" 2>/dev/null; }

# True for the owner or a sysop of a private board. Public boards have no meta file.
manages() {
    [[ -f $BBS_ROOT/meta/$1.meta ]] || return 1
    [[ $(sed -n 's/^owner=//p' "$BBS_ROOT/meta/$1.meta") == "$me" ]] || is_sysop
}

# A read-only board has a .readonly marker in meta/. Only the news account posts there.
is_readonly() { [[ -f $BBS_ROOT/meta/$1.readonly ]]; }

# Requests go through the queue. The publisher runs as root and does the work.
queue_request() {
    local tmp
    tmp=$(mktemp "$BBS_ROOT/queue/incoming/.tmp.XXXXXX") || return
    cat > "$tmp"
    mv -f "$tmp" "$BBS_ROOT/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).req"
}

new_private_board() {
    local name
    read -r -p "Name (a-z, 0-9, - and _; 2-24 chars): " name || return
    [[ $name =~ ^[a-z0-9][a-z0-9_-]{1,23}$ ]] || { echo "bad name"; pause; return; }
    printf 'Action: create-board\nBoard: %s\n' "$name" | queue_request
    echo "Sent. The board appears within a minute. Log in again to see it."
    pause
}

members_menu() {
    local board=$1 choice action user
    echo "Members: $(getent group "bbsb-$board" | cut -d: -f4 | sed 's/bbs-//g; s/,/ /g')"
    read -r -p "[a] Add  [r] Remove  [Enter] Back: " choice || return
    case $choice in
        a) action=invite ;;
        r) action=remove ;;
        *) return ;;
    esac
    read -r -p "User: " user || return
    valid_user "$user" || { echo "unknown user"; pause; return; }
    printf 'Action: %s\nBoard: %s\nUser: %s\n' "$action" "$board" "$user" | queue_request
    echo "Sent. It applies within a minute. The user must log in again to see the board."
    pause
}

# ---- Stage B: private mail via local Postfix --------------------------------

mail_menu() {
    local choice
    while true; do
        clear
        top_bar "[Q] Back"
        echo "== Private messages =="
        echo "1) Inbox   2) Write   Q) Back"
        read -r -p "> " choice || return
        nav_key "$choice" && return
        case $choice in
            1) mail_inbox ;;
            2) mail_write ;;
            [Qq]) return ;;
        esac
    done
}

mail_inbox() {
    local -a files=()
    local f i=1 choice
    for f in "$HOME"/Maildir/new/* "$HOME"/Maildir/cur/*; do
        [[ -f $f && ! -L $f ]] || continue
        files+=("$f")
    done
    if (( ${#files[@]} == 0 )); then
        echo "No messages."; pause; return
    fi
    for f in "${files[@]}"; do
        printf '%3d) %s\n' "$i" "$(sed -n 's/^Subject: //p' "$f" | head -n 1 | safe)"
        i=$((i + 1))
    done
    read -r -p "Read number (Enter = back): " choice || return
    [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )) || return
    clear
    head -c 16384 "${files[choice - 1]}" | safe
    pause
}

mail_write() {
    local to subject line count=0 tmp
    read -r -p "To (name): " to || return
    valid_user "$to" || { echo "unknown user"; pause; return; }
    read -r -p "Subject: " subject || return
    subject=$(printf '%s' "$subject" | safe | head -c 100)
    echo "Write your text. End with a line containing only a dot."
    tmp=$(mktemp) || return
    {
        # From is always the login account; users cannot choose it.
        printf 'From: %s\n' "$USER"
        printf 'To: bbs-%s\n' "$to"
        printf 'Subject: %s\n' "$subject"
        printf '\n'
        while IFS= read -r line; do
            [[ $line == . ]] && break
            count=$((count + 1))
            (( count > 200 )) && break
            printf '%s\n' "$line" | safe
        done
    } > "$tmp"
    # Envelope sender is the login account; Postfix does the delivery.
    /usr/sbin/sendmail -t -f "$USER" < "$tmp"
    rm -f "$tmp"
    echo "Sent."
    pause
}

# ---- Main menu --------------------------------------------------------------

main_menu() {
    local choice
    while true; do
        clear
        top_bar ""
        echo "== BashBBS =="
        echo "1) Public boards"
        echo "2) Private messages"
        echo "3) Users"
        echo "4) My account"
        read -r -p "> " choice || { nav_req=quit; return; }
        nav_key "$choice" && return
        case $choice in
            1) nav_req=boards; return ;;
            2) nav_req=mail; return ;;
            3) clear; list_users; pause ;;
            4) clear; my_account; pause ;;
        esac
    done
}

# Shown on logout. Plain ASCII only, so it works on any terminal.
goodbye() {
    cat <<'EOF'
    .-----------.
    |  BashBBS  |
    |  bye bye  |
    '-----------'
EOF
    # Picked at random per logout. Same art as sleepy-cat and bunny in lib/goodbye-art.txt.
    case $(( RANDOM % 2 )) in
        0) cat <<'EOF'
   /\_/\      z Z
  ( -.- )  z
   > ^ <

EOF
        ;;
        1) cat <<'EOF'
  (\_/)
  ( '.' )
  (")_(")
   Hop back soon.

EOF
        ;;
    esac
    echo "Bye."
}

# ---- Start ------------------------------------------------------------------

# A section that returns without a nav request (Q) goes back to the main menu.
nav_req=main
while true; do
    section=$nav_req
    nav_req=
    case $section in
        quit) break ;;
        main) main_menu ;;
        boards) board_menu ;;
        mail) mail_menu ;;
    esac
    [[ -n $nav_req ]] || nav_req=main
done
goodbye
