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

# ---- Stage B: public boards -------------------------------------------------

board_menu() {
    local boards b
    while true; do
        clear
        echo "== Public boards =="
        boards=()
        for b in "$BBS_ROOT"/boards/*/; do
            [[ -d $b && ! -L ${b%/} ]] || continue
            boards+=("$(basename "$b")")
        done
        local i=1
        for b in "${boards[@]}"; do
            echo "$i) $b"
            i=$((i + 1))
        done
        echo "Q) Back"
        read -r -p "> " choice || return
        case $choice in
            [Qq]) return ;;
            ''|*[!0-9]*) continue ;;
        esac
        (( choice >= 1 && choice <= ${#boards[@]} )) || continue
        board_view "${boards[choice - 1]}"
    done
}

board_view() {
    local board=$1 f n body
    local -a files=()
    while true; do
        clear
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
        echo "N) New post   Q) Back"
        read -r -p "> " choice || return
        case $choice in
            [Qq]) return ;;
            [Nn]) compose "$board" ""; continue ;;
            ''|*[!0-9]*) continue ;;
        esac
        (( choice >= 1 && choice <= ${#files[@]} )) || continue
        clear
        f=${files[choice - 1]}
        head -c 16384 "$f" | safe
        echo
        read -r -p "R) Reply   [Enter] Back: " reply || return
        if [[ $reply == [Rr] ]]; then
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

# ---- Stage B: private mail via local Postfix --------------------------------

mail_menu() {
    local choice
    while true; do
        clear
        echo "== Private messages =="
        echo "1) Inbox   2) Write   Q) Back"
        read -r -p "> " choice || return
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

while true; do
    clear
    echo "== BashBBS =="
    echo "1) Public boards"
    echo "2) Private messages"
    echo "3) Users"
    echo "4) My account"
    echo "Q) Disconnect"
    read -r -p "> " choice || break
    case $choice in
        1) board_menu ;;
        2) mail_menu ;;
        3) clear; list_users; pause ;;
        4) clear; my_account; pause ;;
        [Qq]) break ;;
    esac
done
echo "Bye."
