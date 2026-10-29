#!/bin/bash
# BashBBS main menu. Runs as the login shell of a bbs-<name> account.
# Menu choices are single keys (read_key). Text is read line by line with
# read -r. Neither reaches eval or a shell.
set -u
umask 077

BBS_ROOT=${BBS_ROOT:-/srv/bashbbs}
LIB=/usr/local/lib/bashbbs
# Who is logged in is the kernel's account name, never $USER. BASHBBS_TEST_ID
# exists only for the test harness and is ignored unless BASHBBS_TEST is set.
login=$(id -un) || exit 1
[[ -n ${BASHBBS_TEST:-} && -n ${BASHBBS_TEST_ID:-} ]] && login=$BASHBBS_TEST_ID
[[ $login =~ ^bbs-[a-z][a-z0-9]{2,8}$ ]] || { echo "Bad account." >&2; exit 1; }
me=${login#bbs-}
# Postfix sendmail. BBS_SENDMAIL may point at a stub, but only in tests.
sendmail=/usr/sbin/sendmail
[[ -n ${BASHBBS_TEST:-} && -n ${BBS_SENDMAIL:-} ]] && sendmail=$BBS_SENDMAIL

# Strip control characters (ESC, CR, BEL, ...) from text shown to the user.
safe() { LC_ALL=C.UTF-8 sed 's/[[:cntrl:]]//g'; }

# ---- Keys -------------------------------------------------------------------
# A menu choice is one key, no Enter. MKEY holds the key; it is empty for Enter
# and for escape sequences (arrow keys), which are read to the end and ignored.

# Input that arrived before a screen was drawn is thrown away (a stray Enter, a paste,
# a double press). That happens BEFORE the screen or the prompt is drawn: drain_input,
# then draw, then read. Nothing that drains runs between the prompt and the read, so a
# key typed as soon as the prompt is visible is never lost. Never waits for more.
# A pipe is not drained: the tests feed it whole, and a person cannot type into it.
drain_input() {
    [[ -t 0 ]] || return 0
    while read -t 0; do
        read -rsn1 -t 0.01 _ || break
    done
    return 0
}

# Start of a screen: drain, then clear. The screen is drawn after this.
redraw() {
    drain_input
    clear
}

# One key, no draining, so keys typed on purpose a moment ago are not lost.
read_key_raw() {
    local c o
    MKEY=
    IFS= read -rsn1 c || return 1
    if [[ $c == $'\e' ]]; then
        # Arrow keys are ESC [ A or ESC O A, longer ones ESC [ 1 ; 5 C. Read to the
        # final byte (64..126). 0.2 s so the rest survives a slow link.
        if IFS= read -rsn1 -t 0.2 c && [[ $c == '[' || $c == O ]]; then
            while IFS= read -rsn1 -t 0.2 c; do
                printf -v o '%d' "'$c" 2>/dev/null || break
                (( o >= 64 && o <= 126 )) && break
            done
        fi
        return 0
    fi
    MKEY=$c
}

# Drain what is waiting, then show the prompt, then read one key (no draining after
# the prompt is shown). Returns 1 at end of input.
read_key() { # read_key [prompt]
    drain_input
    [[ -n ${1:-} ]] && printf '%s' "$1"
    read_key_raw
}

# Only y or Y confirms. Enter, an arrow key or any other key means no.
read_confirm() { # read_confirm <prompt>
    read_key "$1" || { echo; return 1; }
    case $MKEY in
        [YyNn]) printf '%s\n' "$MKEY" ;;
        *) echo ;;
    esac
    [[ $MKEY == [Yy] ]]
}

# A screen that only waits: any key goes on.
pause() { read_key "[Any key] " || true; echo; }

# Up to nine digit keys for a list of <n> entries: "123" for three.
digit_keys() { # digit_keys <n>
    local d out=""
    for (( d = 1; d <= $1 && d <= 9; d++ )); do out+=$d; done
    printf '%s' "$out"
}

# MKEY is a digit that starts a number up to <max>. A second digit is waited for
# only when a longer number could still be valid; Enter ends the number early.
# The number is in NUM. Returns 1 when it is abandoned or too big.
read_num() { # read_num <max>
    local n=$MKEY
    NUM=
    printf '%s' "$n"
    while (( n * 10 <= $1 )); do
        read_key_raw || return 1
        case $MKEY in
            [0-9]) n=$((n * 10 + MKEY)); printf '%s' "$MKEY" ;;
            '') break ;;
            *) return 1 ;;
        esac
    done
    (( n >= 1 && n <= $1 )) || return 1
    NUM=$n
}

# Help: a header and at most three lines, then the way back. Any key returns.
show_help() { # show_help <text, lines separated by newlines>
    redraw
    local_header "Help"
    printf '%s\n' "$1"
    echo "[Any key] Back"
    read_key_raw || true   # redraw drained before the help was drawn
    MKEY='?'
}

# Wait for one menu key. Letters match in both cases. ? (help) always works; B M P W G
# (jump) work on a top-level screen only; <chars> adds this screen's keys. Enter, arrows and other keys are
# ignored without redrawing. ? shows the help and returns with MKEY set to ?, so
# the screen redraws. A fourth argument "local" turns the jump keys off (an open post
# or message, a folder, a question in the middle of a task); they are then ignored. Does not drain: the caller's screen did that before drawing
# (redraw). Returns 1 at end of input.
menu_key() { # menu_key <prompt> <chars> <help text> [local]
    printf '%s' "$1"
    while read_key_raw; do
        [[ -n $MKEY ]] || continue
        case $MKEY in
            '?') [[ -n ${3:-} ]] && show_help "$3"; [[ -n ${3:-} ]] && return 0 ;;
            [BbMmPpWwGg]) [[ ${4:-} == local ]] || return 0 ;;&
            *) [[ ${2:-} == *"$MKEY"* ]] && return 0 ;;
        esac
    done
    return 1
}

# Log out? One key; only y or Y says yes.
confirm_logout() { read_confirm "Log out? [y/N] "; }

# News reader (sections, article list, article view).
# shellcheck source=news.sh
source "$(dirname "${BASH_SOURCE[0]}")/news.sh"

# Accept a name only if it matches the naming rule and a profile exists.
valid_user() {
    [[ $1 =~ ^[a-z][a-z0-9]{2,8}$ ]] && [[ -f $BBS_ROOT/users/$1/profile ]]
}

list_users() {
    local f name uuid width
    redraw
    local_header "Users"
    # Name (padded to 16), a space, then as much of the UUID as the terminal has room for.
    width=$(( $(list_width) - 17 ))
    for f in "$BBS_ROOT"/users/*/profile; do
        [[ -f $f && ! -L $f ]] || continue
        name=$(sed -n 's/^name=//p' "$f" | safe)
        uuid=$(sed -n 's/^uuid=//p' "$f" | safe)
        if (( width >= 8 )); then
            printf '%-16s %s\n' "$(list_fit 16 "$name")" "$(list_fit "$width" "$uuid")"
        else
            printf '%s\n' "$(list_fit "$(( $(list_width) ))" "$name")"
        fi
    done
}

my_account() {
    local uuid keys
    uuid=$(sed -n 's/^uuid=//p' "$BBS_ROOT/users/$me/profile" 2>/dev/null | safe)
    keys=$(grep -c . "$BBS_ROOT/keys/$USER" 2>/dev/null || echo 0)
    redraw
    local_header "My account"
    echo "Name:  $me"
    if (( ${#uuid} + 7 > $(list_width) )); then   # 36 characters do not fit beside the label at 40 columns
        echo "UUID:"
        echo "  $uuid"
    else
        echo "UUID:  $uuid"
    fi
    echo "Keys:  $keys registered"
}

# ---- Navigation -------------------------------------------------------------

# Quick keys work on every screen. nav_key sets nav_req and the screen returns
# at once; the loop at the bottom then opens the section that was asked for.
nav_req=

# The [P] Mail label only fits from 50 columns. The key works at every width.
# When the bar is wider than the terminal, Goodbye goes to a second line.
top_bar() {
    local mail="" cols line
    cols=$(term_width)
    (( cols >= 50 )) && mail=" [P] Mail"
    line="[B] Boards [M] Main${mail} [W] Wall [G] Goodbye${1:+  $1}"
    if (( ${#line} <= cols )); then
        echo "$line"
    else
        echo "[B] Boards [M] Main${mail} [W] Wall"
        echo "[G] Goodbye${1:+  $1}"
    fi
    echo
}

nav_key() {
    case $1 in
        [Bb]) nav_req=boards ;;
        [Mm]) nav_req=main ;;
        [Pp]) nav_req=mail ;;
        [Ww]) nav_req=wall ;;
        # The question reads its own key into MKEY. A "no" must not reach the caller's
        # case as a command (n = New post, q = Back), so MKEY is put back to G.
        [Gg]) if confirm_logout; then nav_req=quit; else MKEY=$1; return 1; fi ;;
        *) return 1 ;;
    esac
}

# The top of every screen: the quick-key bar, the title, one blank line.
screen_header() { # screen_header <title> [bar text]
    top_bar "[?] Help${2:+  $2}"
    echo "== $1 =="
    echo
}

# The top of a screen that is inside something (an open post or message, a folder, a
# short form): no jump keys are shown, because none work there. Same layout as
# screen_header.
local_header() { # local_header <title> [bar text]
    echo "[?] Help${2:+  $2}"
    echo
    echo "== $1 =="
    echo
}

# ---- Stage B: public boards -------------------------------------------------

board_menu() {
    local boards b
    while true; do
        redraw
        screen_header "Public boards" "[Q] Back"
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
        menu_key "> " "KkQq$(digit_keys "${#boards[@]}")" \
"Number: open a board
K: new private board   Q: back
B M P W: jump   G: log out" || return
        nav_key "$MKEY" && return
        case $MKEY in
            [Qq]) return ;;
            [Kk]) new_private_board; continue ;;
            [1-9]) read_num "${#boards[@]}" || continue ;;
            *) continue ;;
        esac
        board_view "${boards[NUM - 1]}"
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

# Real terminal width for single-line rows (not clamped like term_width): a row must
# fit the screen it is shown on. 76 when the width is unknown.
list_width() {
    local cols
    cols=$(stty size 2>/dev/null | awk '{print $2}')
    [[ $cols =~ ^[0-9]+$ ]] || cols=76
    echo "$cols"
}

# Fit text into <width> columns, counted the way the terminal counts (wrap.py widths,
# so å is one column and wide characters are two). Too wide: cut, end with "...".
# Display only: the stored text is never changed.
list_fit() { # list_fit <width> <text>
    (( $1 < 1 )) && return
    printf '%s' "$2" | PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=UTF-8 \
        python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from wrap import clusters, vwidth
width = int(sys.argv[2])
text = sys.stdin.read()
if vwidth(text) <= width:
    sys.stdout.write(text)
else:
    budget = width - 3 if width >= 4 else width
    out, used = "", 0
    for cl in clusters(text):
        w = vwidth(cl)
        if used + w > budget:
            break
        out += cl
        used += w
    sys.stdout.write(out.rstrip() + ("..." if width >= 4 else ""))
' "$NEWS_LIB" "$1"
}

# Date header (UTC, written by the publisher) as local time, YYYY-MM-DD HH:MM.
local_time() {
    date -d "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# Show one post: title, author and date, then the body wrapped to width.
# Only the known fields are read; raw headers are never printed. A stub
# (Deleted header) shows [deleted] and no body.
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
        echo "[deleted]"
        echo "by $author, $(local_time "$date")"
        echo "deleted $(local_time "$deleted")"
        return
    fi
    printf '%s\n' "$subject" | python3 "$NEWS_LIB/wrap.py" --keep-lines "$width"
    echo "by $author, $(local_time "$date")"
    [[ -n $edited ]] && echo "edited $(local_time "$edited")"
    printf '%*s\n' "$width" '' | tr ' ' '-'
    sed '1,/^$/d' "$file" | safe | python3 "$NEWS_LIB/wrap.py" --keep-lines "$width"
}

board_view() {
    local board=$1 f rc keys hint wrapw
    local -a files=()
    # A news board with a section marker shows sections, not a thread list.
    if [[ $board == news && -f $BBS_ROOT/meta/news.sections ]]; then
        news_board
        return
    fi
    while true; do
        redraw
        screen_header "$board" "[Q] Back"
        # Measured here, not inside the pipe below: there stdin is not the terminal and
        # term_width would fall back to 76 columns.
        wrapw=$(( $(term_width) - 5 ))
        files=()
        for f in "$BBS_ROOT"/boards/"$board"/*.msg; do
            [[ -f $f && ! -L $f ]] || continue
            files+=("$f")
        done
        local i=1 subject
        for f in "${files[@]}"; do
            # Word wrap with a hanging indent, so a title fits the terminal. wrap.py counts
            # columns, not bytes, so å ä ö and wide characters never split.
            subject=$(sed -n 's/^Subject: //p' "$f" | head -n 1 | safe)
            printf '%s' "$subject" | python3 "$NEWS_LIB/wrap.py" "$wrapw" \
                | awk -v n="$i" 'NR == 1 { printf "%3d) %s\n", n, $0; next } { print "     " $0 }'
            echo
            i=$((i + 1))
        done
        keys=Qq hint="Q: back"
        if is_readonly "$board"; then
            echo "Q) Back"
        elif manages "$board"; then
            echo "N) New post   S) Members   Q) Back"
            keys+=NnSs hint="N: new post   S: members   Q: back"
        else
            echo "N) New post   Q) Back"
            keys+=Nn hint="N: new post   Q: back"
        fi
        # A read-only board has no N. Its owner can still reach S.
        is_readonly "$board" && manages "$board" && keys+=Ss
        menu_key "> " "$keys$(digit_keys "${#files[@]}")" \
"Number: read a post
$hint
B M P W: jump   G: log out" || return
        nav_key "$MKEY" && return
        case $MKEY in
            [Qq]) return ;;
            [Nn]) is_readonly "$board" || compose "$board" ""; continue ;;
            [Ss]) manages "$board" && members_menu "$board"; continue ;;
            [1-9]) read_num "${#files[@]}" || continue ;;
            *) continue ;;
        esac
        f=${files[NUM - 1]}
        while true; do
            redraw
            local_header "$board" "[Q] Back"
            show_post "$f" "$(term_width)"
            echo
            post_actions "$board" "$f"; rc=$?
            (( rc == 2 )) || break
        done
        (( rc == 1 )) && return
    done
}

# One header value from a post file. Reads only up to the blank line after the headers.
post_hdr() { sed '/^$/q' "$1" | sed -n "s/^$2: *//p" | head -n 1 | safe; }

# Commands under an open post. Deleted posts and read-only boards have none.
# Edit is for the author. Delete is for the author, the board owner and sysops.
# Returns 0 for back to the list, 1 at end of input, 2 to redraw the post.
post_actions() { # post_actions <board> <file>
    local board=$1 f=$2 cmds="" keys=Qq hint="Q: back"
    local author
    author=$(post_hdr "$f" Author)
    if [[ -z $(post_hdr "$f" Deleted) ]] && ! is_readonly "$board"; then
        cmds="R) Reply"; keys+=Rr hint="R: reply"
        [[ $author == "$me" ]] && { cmds+="  E) Edit"; keys+=Ee; hint+="  E: edit"; }
        if [[ $author == "$me" ]] || is_sysop || manages "$board"; then
            cmds+="  D) Delete"; keys+=Dd; hint+="  D: delete"
        fi
    fi
    echo "${cmds:+$cmds  }Q) Back"
    # Inside an open post the jump keys are off.
    menu_key "> " "$keys" "$hint  Q: back" local || return 1
    case $MKEY in
        '?') return 2 ;;
        [Rr]) compose "$board" "$(post_hdr "$f" Msgid)" ;;
        [Ee]) edit_post "$board" "$f" ;;
        [Dd]) delete_post "$board" "$f" ;;
    esac
    return 0
}

# Ask for a new subject and, optionally, a new text. Enter keeps the old subject.
# The publisher keeps the old version in its history.
edit_post() { # edit_post <board> <file>
    local board=$1 f=$2 subject new body
    subject=$(post_hdr "$f" Subject)
    echo
    echo "Subject: $(list_fit "$(( $(list_width) - 9 ))" "$subject")"
    read -r -p "New subject ([Enter] keeps): " new || return
    new=$(printf '%s' "$new" | safe | head -c 100)
    [[ -n $new ]] && subject=$new
    while true; do
        drain_input   # before the prompt is drawn, never between it and the read
        echo "K) Keep text   N) New text   Q) Cancel"
        menu_key "> " "KkNnQq" "K: keep the text   N: write new text
Q: cancel the edit" local || return
        [[ $MKEY == '?' ]] || break
        redraw
    done
    [[ $MKEY == [Qq] ]] && return
    if [[ $MKEY == [Nn] ]]; then
        echo "Write text. End with a single dot (.)."
        body=$(read_body)
    else
        body=$(sed '1,/^$/d' "$f")
    fi
    if [[ -z $body ]]; then echo "Empty text, no change."; pause; return; fi
    {
        printf 'Action: edit-post\nBoard: %s\nMsgid: %s\nSubject: %s\n\n' "$board" "$(post_hdr "$f" Msgid)" "$subject"
        printf '%s\n' "$body"
    } | queue_request
    echo "Sent. Appears within a minute."
    pause
}

# Delete needs the word DELETE. A yes/no key is not enough.
delete_post() { # delete_post <board> <file>
    local answer
    echo
    read -r -p "Type DELETE ([Enter] Back): " answer || return
    [[ $answer == DELETE ]] || return
    printf 'Action: delete-post\nBoard: %s\nMsgid: %s\n\n' "$1" "$(post_hdr "$2" Msgid)" | queue_request
    echo "Sent. Appears within a minute."
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
    echo "Write text. End with a single dot (.)."
    tmp=$(mktemp "$BBS_ROOT/queue/incoming/.tmp.XXXXXX") || return
    {
        printf 'Board: %s\n' "$board"
        printf 'Subject: %s\n' "$subject"
        [[ -n $parent ]] && printf 'Parent: %s\n' "$parent"
        printf '\n'
        read_body
    } > "$tmp"
    mv -f "$tmp" "$BBS_ROOT/queue/incoming/$(date +%s)-$(cat /proc/sys/kernel/random/uuid).post"
    echo "Sent. Appears within a minute."
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
    [[ $name =~ ^[a-z0-9][a-z0-9_-]{1,23}$ ]] || { echo "Bad name."; pause; return; }
    printf 'Action: create-board\nBoard: %s\n' "$name" | queue_request
    echo "Sent. Applies in a minute. Log in again."
    pause
}

members_menu() {
    local board=$1 action user cols
    while true; do
        redraw
        local_header "Members"
        cols=$(term_width)   # not inside the pipe: there term_width cannot see the terminal
        echo "Members: $(getent group "bbsb-$board" | cut -d: -f4 | sed 's/bbs-//g; s/,/ /g')" \
            | python3 "$NEWS_LIB/wrap.py" "$cols"
        echo
        echo "A) Add   R) Remove   Q) Back"
        menu_key "> " "AaRrQq" "A: add a member   R: remove one
Q: back" local || return
        [[ $MKEY == '?' ]] || break
    done
    case $MKEY in
        [Aa]) action=invite ;;
        [Rr]) action=remove ;;
        *) return ;;
    esac
    read -r -p "User: " user || return
    valid_user "$user" || { echo "Unknown user."; pause; return; }
    printf 'Action: %s\nBoard: %s\nUser: %s\n' "$action" "$board" "$user" | queue_request
    echo "Sent. Applies in a minute. Log in again."
    pause
}

# ---- Stage B: private mail via local Postfix --------------------------------

# ---- Private messages -------------------------------------------------------
# Mail is Maildir in ~/Maildir and Postfix delivers. The Inbox is ~/Maildir,
# Sent and Trash are Maildir++ dot folders. A user moves or deletes only
# files in the own Maildir. The other side keeps its copy.

mail_menu() {
    while true; do
        redraw
        screen_header "Private messages" "[Q] Back"
        echo "1) Inbox   2) Write"
        echo "3) Sent    4) Trash   Q) Back"
        menu_key "> " "1234Qq" "1-4: Inbox, Write, Sent, Trash
Q: back   B M P W: jump   G: log out" || return
        nav_key "$MKEY" && return
        case $MKEY in
            1) mail_view Inbox ;;
            2) mail_write ;;
            3) mail_view Sent ;;
            4) mail_view Trash ;;
            [Qq]) return ;;
        esac
        [[ -n $nav_req ]] && return
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

# Unread count for the main menu: files in the Inbox new folder.
mail_unread() {
    local f n=0
    for f in "$HOME"/Maildir/new/*; do [[ -f $f ]] && n=$((n + 1)); done
    printf '%d' "$n"
}

# The only place that knows local addresses: a name becomes a local account.
resolve_local() {
    valid_user "$1" || return 1
    # Sysops and the news account are never private-message recipients, even with a profile.
    grep -qx -- "$1" "$BBS_ROOT/sysops" 2>/dev/null && return 1
    [[ $1 == news ]] && return 1
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

# Message-ID as we write it: <something@host>, no spaces or brackets inside.
MAIL_MSGID_RE='^<[^]<>[:space:][:cntrl:]]+>$'

# Subject: at most 60 characters (not bytes), no control characters.
mail_subject() { # mail_subject <text>; prints the subject, or a reason on stderr and returns 1
    local LC_ALL=C.UTF-8
    if [[ $1 == *[[:cntrl:]]* ]]; then echo "Subject: no control characters." >&2; return 1; fi
    if (( ${#1} > 60 )); then echo "Subject: at most 60 characters." >&2; return 1; fi
    printf '%s' "$1"
}

# Body: lines up to a line with only a dot. Limit 8 192 bytes, line ends included.
# A line with /cancel stops without output. Returns 1 on cancel or when too long.
mail_body() {
    local line total=0 LC_ALL=C
    while IFS= read -r line; do
        [[ $line == . ]] && break
        [[ $line == /cancel ]] && return 1
        total=$((total + ${#line} + 1))
        if (( total > 8192 )); then echo "Text: at most 8192 bytes." >&2; return 1; fi
        printf '%s\n' "$line" | safe
    done
    return 0
}

# Send one message and keep a copy in Sent. The body is read from stdin.
# The sender is the login account. Nothing from the environment or the input sets it.
mail_send() { # mail_send <name> <subject> [in-reply-to]
    local to=$1 subject=$2 reply=${3:-} acct host tmp
    valid_user "$me" || return 1
    acct=$(resolve_local "$to") || return 1
    host=$(hostname)
    tmp=$(mktemp) || return 1
    {
        printf 'Message-ID: <%s@%s>\n' "$(cat /proc/sys/kernel/random/uuid)" "$host"
        printf 'Date: %s\n' "$(date -R)"
        printf 'From: %s@%s\n' "$me" "$host"
        printf 'To: %s@%s\n' "$to" "$host"
        printf 'Subject: %s\n' "$subject"
        [[ $reply =~ $MAIL_MSGID_RE ]] && printf 'In-Reply-To: %s\n' "$reply"
        printf '\n'
    } > "$tmp"
    if ! mail_body >> "$tmp"; then rm -f "$tmp"; echo "Not sent."; pause; return 1; fi
    if ! read_confirm "Send? [y/N] "; then rm -f "$tmp"; echo "Not sent."; pause; return 1; fi
    # The recipient goes on the command line, so the To header cannot change delivery.
    # env -i: sendmail runs with an empty environment, and -f is always bbs-<login>.
    if /usr/bin/env -i "$sendmail" -i -f "bbs-$me" "$acct" < "$tmp"; then
        mail_store Sent cur "$tmp"
        echo "Queued for delivery."
    else
        echo "Could not queue the message."
    fi
    rm -f "$tmp"
    pause
}

# Write a new message, or a reply when called from mail_reply. /cancel stops at any prompt.
mail_write() { # mail_write [name subject in-reply-to]
    local to=${1:-} subject=${2:-} reply=${3:-} line
    if [[ -z $to ]]; then read -r -p "To (/cancel stops): " to || return; fi
    [[ $to == /cancel ]] && return
    resolve_local "$to" >/dev/null || { echo "Unknown user."; pause; return; }
    # The default in brackets is shown cut to the line; Enter still keeps the full subject.
    local shown=""
    [[ -n $subject ]] && shown=" [$(list_fit $(( $(list_width) - 28 )) "$subject")]"
    read -r -p "Subject${shown} (/cancel stops): " line || return
    [[ $line == /cancel ]] && return
    [[ -n $line ]] && subject=$line
    subject=$(mail_subject "$subject") || { pause; return; }
    [[ -n $subject ]] || subject="(no subject)"
    echo "Write text. End with a single dot (.)."
    mail_send "$to" "$subject" "$reply"
}

# Reply: To is the sender, Subject gets Re: once (cut to 60 characters), In-Reply-To is the Message-ID.
mail_reply() { # mail_reply <file>
    local from subject
    from=$(post_hdr "$1" From)
    subject=$(post_hdr "$1" Subject)
    [[ $subject == Re:* ]] || subject="Re: $subject"
    local LC_ALL=C.UTF-8
    subject=${subject:0:60}
    mail_write "${from%%@*}" "$subject" "$(post_hdr "$1" Message-ID)"
}

# A folder list. Unread messages in new are marked with *.
mail_view() { # mail_view <Inbox|Sent|Trash>
    local folder=$1 dir f mark i width
    local -a files
    while true; do
        redraw
        dir=$(mail_dir "$folder")
        files=()
        for f in "$dir"/new/* "$dir"/cur/*; do
            [[ -f $f && ! -L $f ]] || continue
            files+=("$f")
        done
        local_header "$folder" "[Q] Back"
        if (( ${#files[@]} == 0 )); then
            echo "No messages."
            echo
            pause
            return
        fi
        i=1
        width=$(( $(list_width) - 7 ))  # "%3d) %s " is 7 columns
        for f in "${files[@]}"; do
            mark=" "
            [[ $f == "$dir"/new/* ]] && mark="*"
            printf '%3d) %s %s\n' "$i" "$mark" "$(list_fit "$width" "$(post_hdr "$f" Subject)")"
            i=$((i + 1))
        done
        echo
        echo "Number: open   Q) Back"
        # Inside a mailbox the jump keys are off: Q goes back one level.
        menu_key "> " "Qq$(digit_keys "${#files[@]}")" \
"Number: open a message
Q: back" local || return
        case $MKEY in
            [Qq]) return ;;
            [1-9]) read_num "${#files[@]}" || continue ;;
            *) continue ;;
        esac
        mail_open "$folder" "${files[NUM - 1]}"
    done
}

# Show one message. Reading moves it from new to cur, the Maildir way.
mail_open() { # mail_open <folder> <file>
    local folder=$1 f=$2 dir name rc
    dir=$(mail_dir "$folder")
    if [[ $f == "$dir"/new/* ]]; then
        name=$(mail_cur_name "$(basename "$f")")
        mkdir -p "$dir/cur"
        mv -n "$f" "$dir/cur/$name" && f=$dir/cur/$name
    fi
    while true; do
        redraw
        local_header "$folder" "[Q] Back"
        show_post "$f" "$(term_width)"
        echo
        mail_actions "$folder" "$f"; rc=$?
        (( rc == 2 )) || break
    done
    return 0
}

# Commands under a message. Inbox: reply and delete. Sent: delete the own copy. Trash: none.
# R is Reply and D is Delete, the same keys as on the boards.
# Returns 0 for back to the list, 1 at end of input, 2 to redraw.
mail_actions() { # mail_actions <folder> <file>
    local folder=$1 f=$2 cmds="" keys=Qq hint="Q: back"
    case $folder in
        Inbox) cmds="R) Reply   D) Delete   "; keys+=RrDd; hint="R: reply  D: delete  Q: back" ;;
        Sent) cmds="D) Delete   "; keys+=Dd; hint="D: delete  Q: back" ;;
    esac
    echo "${cmds}Q) Back"
    # Inside an open message the jump keys are off.
    menu_key "> " "$keys" "$hint" local || return 1
    case $MKEY in
        '?') return 2 ;;
        [Rr]) mail_reply "$f" ;;
        [Dd]) mail_delete "$f" ;;
    esac
    return 0
}

# Move the own copy to Trash. Other copies are not touched. Nothing is erased in 1.3.
mail_delete() { # mail_delete <file>
    local trash name
    echo
    if ! read_confirm "Move to Trash? [y/N] "; then echo "Not moved."; pause; return; fi
    trash=$(mail_dir Trash)
    name=$(mail_cur_name "$(basename "$1")")
    mkdir -p "$trash"/{tmp,new,cur}
    mv -n "$1" "$trash/cur/$name" && echo "Moved to Trash."
    pause
}

# ---- Main menu --------------------------------------------------------------

main_menu() {
    while true; do
        redraw
        screen_header "BashBBS"
        echo "1) Public boards"
        echo "2) Wall"
        echo "3) Users"
        echo "4) My account"
        echo "5) Private messages   ($(mail_unread) unread)"
        echo "Q) Log out"
        menu_key "> " "12345Qq" "1-5: pick a section
Q or G: log out
B M P W: jump" || { nav_req=quit; return; }
        case $MKEY in
            [QqGg]) confirm_logout && { nav_req=quit; return; }; continue ;;
        esac
        nav_key "$MKEY" && return
        case $MKEY in
            1) nav_req=boards; return ;;
            2) nav_req=wall; return ;;
            3) list_users; pause ;;
            4) my_account; pause ;;
            5) nav_req=mail; return ;;
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
    echo "$(local_time "$date")  by $author"
    sed '1,/^$/d' "$file" | safe | python3 "$NEWS_LIB/wrap.py" --keep-lines "$width"
}

# Write one greeting into the queue. Empty input cancels.
wall_write() {
    local text len tmp
    echo "Greeting, max $WALL_MAX_CHARS chars. [Enter] Back."
    read -r -p "> " text || return
    text=$(printf '%s' "$text" | safe)
    [[ -n $text ]] || return
    len=$(printf '%s' "$text" | LC_ALL=C.UTF-8 wc -m)
    if (( len > WALL_MAX_CHARS )); then
        echo "Too long ($len/$WALL_MAX_CHARS characters)."
        pause
        return
    fi
    tmp=$(mktemp "$BBS_ROOT/queue/incoming/.tmp.XXXXXX") || return
    printf '%s\n' "$text" > "$tmp"
    mv -f "$tmp" "$BBS_ROOT/queue/incoming/$(date +%s%N)-$(cat /proc/sys/kernel/random/uuid).wall"
    echo "Sent. Appears within a minute."
    pause
}

# Newest first, WALL_PAGE per page. Space goes to the next page, after the last one to the first.
wall_menu() {
    local -a files=() newest=()
    local f i page=0 pages start
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
        redraw
        screen_header "Wall"
        if (( ${#newest[@]} == 0 )); then
            echo "No greetings yet."
            echo
        fi
        start=$(( page * WALL_PAGE ))
        for (( i = start; i < start + WALL_PAGE && i < ${#newest[@]}; i++ )); do
            wall_entry "${newest[i]}" "$(term_width)"
            echo
        done
        if (( ${#newest[@]} > 0 )); then
            echo
        fi
        echo "Page $((page + 1)) of $pages"
        echo "[Space] Next  N) Write  Q) Back  [?]"
        menu_key "> " "NnQq " "N: write a greeting
[Space]: next page   Q: back
B M P W: jump   G: log out" || { nav_req=quit; return; }
        nav_key "$MKEY" && return
        case $MKEY in
            [Qq]) return ;;
            [Nn]) wall_write ;;
            ' ') page=$(( (page + 1) % pages )) ;;
        esac
        [[ -n $nav_req ]] && return
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

# ---- What's new: summary at login -------------------------------------------
# The counts are new since the previous login. Nothing is marked as read.
# The last login is kept in ~/.bashbbs-seen as login=<epoch>. Only counts are
# shown, never subjects or names. News has its own menu and is not counted.

# Public board posts newer than <since>. The file name starts with the publish epoch.
new_board_posts() { # new_board_posts <since>
    local since=$1 b f pre n=0
    for b in "$BBS_ROOT"/boards/*/; do
        b=${b%/}
        [[ $(basename "$b") == news ]] && continue
        # Same visibility rule as board_menu: private boards stay hidden.
        [[ -d $b && ! -L $b && -r $b && -x $b ]] || continue
        for f in "$b"/*.msg; do
            [[ -f $f && ! -L $f ]] || continue
            pre=$(basename "$f"); pre=${pre%%-*}
            [[ $pre =~ ^[0-9]+$ ]] && (( 10#$pre > since )) && n=$((n + 1))
        done
    done
    printf '%d' "$n"
}

# Wall greetings newer than <since>. The file name starts with date +%s%N.
new_wall_greetings() { # new_wall_greetings <since>
    local since=$1 f pre n=0
    for f in "$BBS_ROOT"/wall/*.msg; do
        [[ -f $f && ! -L $f ]] || continue
        pre=$(basename "$f"); pre=${pre%%-*}
        [[ $pre =~ ^[0-9]{10,}$ ]] && (( 10#${pre:0:10} > since )) && n=$((n + 1))
    done
    printf '%d' "$n"
}

# "1 new post" or "2 new posts".
count_text() { # count_text <n> <singular> <plural>
    if (( $1 == 1 )); then printf '%d %s' "$1" "$2"; else printf '%d %s' "$1" "$3"; fi
}

# First screen after login. Sets nav_req: [Enter] main menu, or a quick key.
welcome_screen() {
    local seen=$HOME/.bashbbs-seen prev=""
    prev=$(sed -n 's/^login=//p' "$seen" 2>/dev/null | head -n 1)
    [[ $prev =~ ^[0-9]+$ ]] || prev=""
    printf 'login=%s\n' "$(date +%s)" > "$seen" 2>/dev/null || true
    while true; do
        redraw
        screen_header "Welcome, $me"
        if [[ -n $prev ]]; then
            echo "Last login: $(local_time "@$prev")"
            echo
            echo "  $(count_text "$(mail_unread)" "unread private message" "unread private messages")"
            echo "  $(count_text "$(new_board_posts "$prev")" "new post" "new posts") on Public boards"
            echo "  $(count_text "$(new_wall_greetings "$prev")" "new greeting" "new greetings") on the Wall"
        else
            echo "First visit. Welcome to BashBBS."
            echo
            echo "  $(count_text "$(mail_unread)" "unread private message" "unread private messages")"
        fi
        echo
        echo "[Any key] Main"
        printf '> '
        # redraw drained before this screen was drawn; nothing drains here.
        read_key_raw || { nav_req=quit; return; }
        echo
        case $MKEY in
            '?') show_help "Any key: go to the main menu
    B M P W: jump   G: log out"; continue ;;
            [Gg]) confirm_logout && { nav_req=quit; return; }; continue ;;
        esac
        nav_key "$MKEY" || nav_req=main
        return
    done
}

# ---- Start ------------------------------------------------------------------

# The tests source this file for its functions and skip the start loop.
if [[ -z ${BASHBBS_TEST:-} ]]; then
    welcome_screen
    # A section that returns without a nav request (Q) goes back to the main menu.
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
