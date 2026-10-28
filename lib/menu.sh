#!/bin/bash
# BashBBS main menu. Runs as the login shell of a bbs-<name> account.
# Input is read line by line with read -r and never reaches eval or a shell.
set -u
umask 077

BBS_ROOT=${BBS_ROOT:-/srv/bashbbs}
LIB=/usr/local/lib/bashbbs
me=${USER#bbs-}
[[ $me =~ ^[a-z][a-z0-9]{2,8}$ ]] || { echo "bad account" >&2; exit 1; }

# Strip control characters (ESC, CR, BEL, ...) from text shown to the user.
safe() { LC_ALL=C.UTF-8 sed 's/[[:cntrl:]]//g'; }

pause() { read -r -p "[Enter] " _ || true; }

# News reader (sections, article list, article view).
# shellcheck source=news.sh
source "$(dirname "${BASH_SOURCE[0]}")/news.sh"

# Accept a name only if it matches the naming rule and a profile exists.
valid_user() {
    [[ $1 =~ ^[a-z][a-z0-9]{2,8}$ ]] && [[ -f $BBS_ROOT/users/$1/profile ]]
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
    echo "[B] Boards [M] Main [W] Wall [G] Goodbye${1:+  $1}"
    echo
}

nav_key() {
    case $1 in
        [Bb]) nav_req=boards ;;
        [Mm]) nav_req=main ;;
        [Ww]) nav_req=wall ;;
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

# Text width for post and mail views: the terminal width when it is known,
# otherwise 76. Kept between 40 and 80 so both phones and wide terminals work.
term_width() {
    local cols
    cols=$(stty size 2>/dev/null | awk '{print $2}')
    [[ $cols =~ ^[0-9]+$ ]] || cols=76
    (( cols < 40 )) && cols=40
    (( cols > 80 )) && cols=80
    echo "$cols"
}

# Date header (UTC, written by the publisher) as local time, YYYY-MM-DD HH:MM.
local_time() {
    date -d "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# Show one post: title, author and date, then the body wrapped to width.
# Only the known fields are read; raw headers are never printed. A stub
# (Deleted header) shows [raderat] and no body.
show_post() {
    local file=$1 width=$2 line key val
    local subject="" author="" date="" edited="" deleted=""
    while IFS= read -r line && [[ -n $line ]]; do
        key=${line%%:*}
        val=$(printf '%s' "${line#*: }" | safe)
        case $key in
            Subject) subject=$val ;;
            Author|From) author=${val#bbs-}; author=${author%%@*} ;;
            Date) date=$val ;;
            Edited) edited=$val ;;
            Deleted) deleted=$val ;;
        esac
    done < "$file"
    if [[ -n $deleted ]]; then
        echo "[raderat]"
        echo "av $author, $(local_time "$date")"
        echo "raderat $(local_time "$deleted")"
        return
    fi
    echo "$subject"
    echo "av $author, $(local_time "$date")"
    [[ -n $edited ]] && echo "redigerad $(local_time "$edited")"
    printf '%*s\n' "$width" '' | tr ' ' '-'
    sed '1,/^$/d' "$file" | safe | python3 "$NEWS_LIB/wrap.py" --keep-lines "$width"
}

board_view() {
    local board=$1 f n body choice
    local -a files=()
    # A news board with a section marker shows sections, not a thread list.
    if [[ $board == news && -f $BBS_ROOT/meta/news.sections ]]; then
        news_board
        return
    fi
    while true; do
        clear
        top_bar "[Q] Back"
        echo "== $board =="
        files=()
        for f in "$BBS_ROOT"/boards/"$board"/*.msg; do
            [[ -f $f && ! -L $f ]] || continue
            files+=("$f")
        done
        local i=1 subject
        for f in "${files[@]}"; do
            # Word wrap with a hanging indent, so a title fits a phone-width terminal.
            subject=$(sed -n 's/^Subject: //p' "$f" | head -n 1 | safe)
            printf '%3d) %s\n' "$i" "$(printf '%s' "$subject" | fold -s -w 26 | sed '2,$s/^/     /')"
            echo
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
        show_post "$f" "$(term_width)"
        echo
        post_actions "$board" "$f" || return
    done
}

# One header value from a post file. Reads only up to the blank line after the headers.
post_hdr() { sed '/^$/q' "$1" | sed -n "s/^$2: *//p" | head -n 1 | safe; }

# Commands under an open post. Deleted posts and read-only boards have none.
# Edit is for the author. Delete is for the author, the board owner and sysops.
post_actions() { # post_actions <board> <file>
    local board=$1 f=$2 cmd cmds="" author
    author=$(post_hdr "$f" Author)
    if [[ -z $(post_hdr "$f" Deleted) ]] && ! is_readonly "$board"; then
        cmds="R) Svara"
        [[ $author == "$me" ]] && cmds+="   E) Ändra"
        if [[ $author == "$me" ]] || is_sysop || manages "$board"; then cmds+="   D) Radera"; fi
    fi
    read -r -p "${cmds:+$cmds   }[Enter] Tillbaka: " cmd || return 1
    nav_key "$cmd" && return 1
    case $cmd in
        [Rr]) [[ $cmds == *"R)"* ]] && compose "$board" "$(post_hdr "$f" Msgid)" ;;
        [Ee]) [[ $cmds == *"E)"* ]] && edit_post "$board" "$f" ;;
        [Dd]) [[ $cmds == *"D)"* ]] && delete_post "$board" "$f" ;;
    esac
    return 0
}

# Ask for a new subject and, optionally, a new text. Enter keeps the old subject.
# The publisher keeps the old version in its history.
edit_post() { # edit_post <board> <file>
    local board=$1 f=$2 subject new choice body
    subject=$(post_hdr "$f" Subject)
    echo
    read -r -p "Rubrik: $subject   [Enter] behåll: " new || return
    new=$(printf '%s' "$new" | safe | head -c 100)
    [[ -n $new ]] && subject=$new
    read -r -p "[b]ehåll text   [n]y text: " choice || return
    if [[ $choice == [Nn] ]]; then
        echo "Skriv den nya texten. Avsluta med en rad som bara innehåller en punkt."
        body=$(read_body)
    else
        body=$(sed '1,/^$/d' "$f")
    fi
    if [[ -z $body ]]; then echo "Tom text, ingen ändring."; pause; return; fi
    {
        printf 'Action: edit-post\nBoard: %s\nMsgid: %s\nSubject: %s\n\n' "$board" "$(post_hdr "$f" Msgid)" "$subject"
        printf '%s\n' "$body"
    } | queue_request
    echo "Skickat. Ändringen syns inom en minut."
    pause
}

# Delete needs the word radera. A yes/no key is not enough.
delete_post() { # delete_post <board> <file>
    local answer
    echo
    read -r -p "Skriv radera för att ta bort inlägget, annars Enter: " answer || return
    [[ $answer == radera ]] || return
    printf 'Action: delete-post\nBoard: %s\nMsgid: %s\n\n' "$1" "$(post_hdr "$2" Msgid)" | queue_request
    echo "Skickat. Ändringen syns inom en minut."
    pause
}

# Text lines up to a line with only a dot, at most 200 lines. Used by compose and edit.
read_body() {
    local line count=0
    while IFS= read -r line; do
        [[ $line == . ]] && break
        count=$((count + 1))
        (( count > 200 )) && break
        printf '%s\n' "$line" | safe
    done
}

# Write one post into the queue. The publisher checks it and copies it
# into boards/. Users cannot write into boards/ themselves.
compose() {
    local board=$1 parent=$2 subject tmp
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
        read_body
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

# ---- Private messages -------------------------------------------------------
# Mail is Maildir in ~/Maildir and Postfix delivers. The Inbox is ~/Maildir,
# Sent and Trash are Maildir++ dot folders. A user moves or deletes only
# files in the own Maildir. The other side keeps its copy.

mail_menu() {
    local choice
    while true; do
        clear
        top_bar "[Q] Back"
        echo "== Private messages =="
        echo "1) Inbox   2) Write   3) Sent   4) Trash   Q) Back"
        read -r -p "> " choice || return
        nav_key "$choice" && return
        case $choice in
            1) mail_view Inbox ;;
            2) mail_write ;;
            3) mail_view Sent ;;
            4) mail_view Trash ;;
            [Qq]) return ;;
        esac
    done
}

# Folder path. The Inbox is the Maildir itself.
mail_dir() {
    case $1 in
        Inbox) printf '%s' "$HOME/Maildir" ;;
        Sent) printf '%s' "$HOME/Maildir/.Sent" ;;
        Trash) printf '%s' "$HOME/Maildir/.Trash" ;;
    esac
}

# The only place that knows local addresses: a name becomes a local account.
resolve_local() {
    valid_user "$1" || return 1
    printf 'bbs-%s' "$1"
}

# File name for a message in cur. Maildir needs a flag suffix there.
mail_cur_name() {
    local name=$1
    if [[ $name == *:* ]]; then printf '%s' "$name"; else printf '%s:2,S' "$name"; fi
}

# Store a message in a Maildir folder: write to tmp, then move it into new or cur.
mail_store() { # mail_store <folder> <new|cur> <file>
    local dir name
    dir=$(mail_dir "$1")
    name="$(date +%s).$(cat /proc/sys/kernel/random/uuid).$(hostname)"
    [[ $2 == cur ]] && name=$(mail_cur_name "$name")
    mkdir -p "$dir"/{tmp,new,cur}
    cp "$3" "$dir/tmp/$name" && mv -f "$dir/tmp/$name" "$dir/$2/$name"
}

# Send one message and keep a copy in Sent. The body is read from stdin.
mail_send() { # mail_send <name> <subject> [in-reply-to]
    local to=$1 subject=$2 reply=${3:-} acct host tmp
    acct=$(resolve_local "$to") || return 1
    host=$(hostname)
    tmp=$(mktemp) || return 1
    {
        printf 'Message-ID: <%s@%s>\n' "$(cat /proc/sys/kernel/random/uuid)" "$host"
        printf 'Date: %s\n' "$(date -R)"
        # From is always the login account. Users cannot choose it.
        printf 'From: %s@%s\n' "$me" "$host"
        printf 'To: %s@%s\n' "$to" "$host"
        printf 'Subject: %s\n' "$subject"
        [[ -n $reply ]] && printf 'In-Reply-To: %s\n' "$reply"
        printf '\n'
        read_body
    } > "$tmp"
    # The recipient goes on the command line, so the To header cannot change delivery.
    if "${BBS_SENDMAIL:-/usr/sbin/sendmail}" -i -f "$USER" "$acct" < "$tmp"; then
        mail_store Sent cur "$tmp"
        echo "Sent."
    else
        echo "Kunde inte skickas."
    fi
    rm -f "$tmp"
    pause
}

# Write a new message, or a reply when called from mail_reply.
mail_write() { # mail_write [name subject in-reply-to]
    local to=${1:-} subject=${2:-} reply=${3:-} line
    [[ -n $to ]] || read -r -p "To (name): " to || return
    resolve_local "$to" >/dev/null || { echo "unknown user"; pause; return; }
    read -r -p "Subject${subject:+ [$subject]}: " line || return
    [[ -n $line ]] && subject=$line
    subject=$(printf '%s' "$subject" | safe | head -c 100)
    echo "Write your text. End with a line containing only a dot."
    mail_send "$to" "$subject" "$reply"
}

# Reply: To is the sender, Subject gets Re: once, In-Reply-To is the Message-ID.
mail_reply() { # mail_reply <file>
    local from subject
    from=$(post_hdr "$1" From)
    subject=$(post_hdr "$1" Subject)
    [[ $subject == Re:* ]] || subject="Re: $subject"
    mail_write "${from%%@*}" "$subject" "$(post_hdr "$1" Message-ID)"
}

# A folder list. Unread messages in new are marked with *.
mail_view() { # mail_view <Inbox|Sent|Trash>
    local folder=$1 dir f mark choice i
    local -a files
    while true; do
        clear
        dir=$(mail_dir "$folder")
        files=()
        for f in "$dir"/new/* "$dir"/cur/*; do
            [[ -f $f && ! -L $f ]] || continue
            files+=("$f")
        done
        echo "== $folder =="
        if (( ${#files[@]} == 0 )); then
            echo "Inga meddelanden."
            pause
            return
        fi
        i=1
        for f in "${files[@]}"; do
            mark=" "
            [[ $f == "$dir"/new/* ]] && mark="*"
            printf '%3d) %s %s\n' "$i" "$mark" "$(post_hdr "$f" Subject)"
            i=$((i + 1))
        done
        read -r -p "Nummer (Enter = tillbaka): " choice || return
        nav_key "$choice" && return
        [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )) || return
        mail_open "$folder" "${files[choice - 1]}"
    done
}

# Show one message. Reading moves it from new to cur, the Maildir way.
mail_open() { # mail_open <folder> <file>
    local folder=$1 f=$2 dir name
    dir=$(mail_dir "$folder")
    if [[ $f == "$dir"/new/* ]]; then
        name=$(mail_cur_name "$(basename "$f")")
        mkdir -p "$dir/cur"
        mv -n "$f" "$dir/cur/$name" && f=$dir/cur/$name
    fi
    clear
    show_post "$f" "$(term_width)"
    echo
    mail_actions "$folder" "$f"
}

# Commands under a message. Inbox: reply and delete. Sent: delete the own copy. Trash: none.
mail_actions() { # mail_actions <folder> <file>
    local folder=$1 f=$2 cmd cmds=""
    case $folder in
        Inbox) cmds="S) Svara   R) Radera   " ;;
        Sent) cmds="R) Radera   " ;;
    esac
    read -r -p "${cmds}[Enter] Tillbaka: " cmd || return
    nav_key "$cmd" && return
    case $cmd in
        [Ss]) [[ $cmds == *"S)"* ]] && mail_reply "$f" ;;
        [Rr]) [[ $cmds == *"R)"* ]] && mail_delete "$f" ;;
    esac
}

# Move the own copy to Trash. Other copies are not touched.
mail_delete() { # mail_delete <file>
    local trash name
    trash=$(mail_dir Trash)
    name=$(mail_cur_name "$(basename "$1")")
    mkdir -p "$trash"/{tmp,new,cur}
    mv -n "$1" "$trash/cur/$name" && echo "Flyttat till papperskorgen."
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
        echo "2) Wall"
        echo "3) Users"
        echo "4) My account"
        read -r -p "> " choice || { nav_req=quit; return; }
        nav_key "$choice" && return
        case $choice in
            1) nav_req=boards; return ;;
            2) nav_req=wall; return ;;
            3) clear; list_users; pause ;;
            4) clear; my_account; pause ;;
        esac
    done
}

# ---- Wall: one-line greetings -----------------------------------------------
# A greeting goes through the queue as *.wall. The publisher checks it, keeps
# the newest 100 in wall/ and removes the rest. The sender is the file owner.
WALL_PAGE=10
WALL_MAX_CHARS=140

# One greeting: date and sender, then the text wrapped to width.
wall_entry() { # wall_entry <file> <width>
    local file=$1 width=$2 line key val date="" author=""
    while IFS= read -r line && [[ -n $line ]]; do
        key=${line%%:*}
        val=$(printf '%s' "${line#*: }" | safe)
        case $key in
            Author) author=$val ;;
            Date) date=$val ;;
        esac
    done < "$file"
    echo "$(local_time "$date")  av $author"
    sed '1,/^$/d' "$file" | safe | python3 "$NEWS_LIB/wrap.py" --keep-lines "$width"
}

# Write one greeting into the queue. Empty input cancels.
wall_write() {
    local text len tmp
    echo "Write a greeting (max $WALL_MAX_CHARS characters). Empty line cancels."
    read -r -p "> " text || return
    text=$(printf '%s' "$text" | safe)
    [[ -n $text ]] || return
    len=$(printf '%s' "$text" | LC_ALL=C.UTF-8 wc -m)
    if (( len > WALL_MAX_CHARS )); then
        echo "Too long: $len characters. The limit is $WALL_MAX_CHARS."
        pause
        return
    fi
    tmp=$(mktemp "$BBS_ROOT/queue/incoming/.tmp.XXXXXX") || return
    printf '%s\n' "$text" > "$tmp"
    mv -f "$tmp" "$BBS_ROOT/queue/incoming/$(date +%s%N)-$(cat /proc/sys/kernel/random/uuid).wall"
    echo "Sent to the publisher. It appears within a minute."
    pause
}

# Newest first, WALL_PAGE per page. Enter goes to the next page, after the last one to the first.
wall_menu() {
    local -a files=() newest=()
    local f i page=0 pages start choice
    while true; do
        files=()
        for f in "$BBS_ROOT"/wall/*.msg; do
            [[ -f $f && ! -L $f ]] && files+=("$f")
        done
        newest=()
        for (( i = ${#files[@]} - 1; i >= 0; i-- )); do newest+=("${files[i]}"); done
        pages=$(( (${#newest[@]} + WALL_PAGE - 1) / WALL_PAGE ))
        (( pages > 0 )) || pages=1
        (( page < pages )) || page=0
        clear
        top_bar ""
        echo "== Wall =="
        if (( ${#newest[@]} == 0 )); then
            echo "No greetings yet."
        fi
        start=$(( page * WALL_PAGE ))
        for (( i = start; i < start + WALL_PAGE && i < ${#newest[@]}; i++ )); do
            wall_entry "${newest[i]}" "$(term_width)"
            echo
        done
        echo "Page $((page + 1)) of $pages"
        echo "N) Write   Enter) Next   Q) Back"
        read -r -p "> " choice || { nav_req=quit; return; }
        nav_key "$choice" && return
        case $choice in
            [Qq]) return ;;
            [Nn]) wall_write ;;
            '') page=$(( (page + 1) % pages )) ;;
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
    cat <<'EOF'
        /\_/\
       ( o.o )
        > ^ <

EOF
    echo "Bye."
}

# ---- Start ------------------------------------------------------------------

# The tests source this file for its functions and skip the start loop.
if [[ -z ${BASHBBS_TEST:-} ]]; then
    # A section that returns without a nav request (Q) goes back to the main menu.
    nav_req=main
    while true; do
        section=$nav_req
        nav_req=
        case $section in
            quit) break ;;
            main) main_menu ;;
            boards) board_menu ;;
            wall) wall_menu ;;
            mail) mail_menu ;;
        esac
        [[ -n $nav_req ]] || nav_req=main
    done
    goodbye
fi
