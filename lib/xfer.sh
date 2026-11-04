# File transfers through a browser. The session makes a ticket, shows a link and
# waits; web/x.cgi moves the bytes and sbin/bbs-upload sorts them, so a transfer goes
# on even if the session ends. Sourced by menu.sh, never run. Needs BBS_ROOT, login
# and the helpers in menu.sh and upload-common.sh.

XFER_POLL=${XFER_POLL:-2}       # seconds between looks at the results while waiting
XFER_OUTCOME=                   # how the last wait ended: done, left or expired

# xfer_ticket <up|down> [line...]: prints the new token. The lines are id=<file id> for a
# download, area=<slug> for an upload. Only the owner of the file
# counts for who the ticket is for, so it has to be readable for www-data.
xfer_ticket() {
    local dir=$1 token line body; shift
    token=$(head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    [[ $token =~ ^[A-Za-z0-9_-]{22}$ ]] || return 1
    body="dir=$dir"$'\n'
    for line in "$@"; do body+="$line"$'\n'; done
    ( umask 022; set -C; printf '%s' "$body" > "$BBS_ROOT/queue/xfer/$token" ) 2>/dev/null || return 1
    printf '%s' "$token"
}

# The link for a token. $BBS_ROOT/xfer-url (written by root, one line, no slash at the
# end) replaces the public address on a machine that is not the public one.
xfer_url() { # xfer_url <token>
    local base
    base=$(sed -n 1p "$BBS_ROOT/xfer-url" 2>/dev/null)
    printf '%s/%s\n' "${base:-https://$BBS_PUBLIC_HOST/x.cgi}" "$1"
}

# xfer_wait <seconds> <check> [args...]: runs the check every turn, also when no key
# was pressed, until it says yes, Q is pressed or the link has run out. Sets
# XFER_OUTCOME. Returns 1 at end of input. Input is drained once, here: draining in
# the loop would swallow the Q.
xfer_wait() {
    local ttl=$1 start=$SECONDS c rc; shift
    drain_input
    while true; do
        if "$@"; then XFER_OUTCOME=done; return 0; fi
        if (( SECONDS - start >= ttl )); then XFER_OUTCOME=expired; return 0; fi
        c=
        IFS= read -t "$XFER_POLL" -rsn1 c
        rc=$?
        if (( rc == 0 )); then
            if [[ $c == [Qq] ]]; then XFER_OUTCOME=left; return 0; fi
        elif (( rc <= 128 )); then
            return 1
        fi
    done
}

XFER_SEEN=0 XFER_OK=0 XFER_BAD=0
XFER_NEW_IDS=() XFER_NEW_NAMES=()

# Prints the result lines not shown yet. Yes when the page has said it is finished.
# The sorter's note says what it found: "archive" opened, "archive+diz" also had a
# FILE_ID.DIZ. Files with no description of their own are kept for xfer_describe_new.
xfer_check_up() { # xfer_check_up <token>
    local f=$BBS_ROOT/state/xfer-results/$1 lines=() i what name why note finished=1 said
    [[ -r $f ]] || return 1
    mapfile -t lines < "$f"
    for (( i = XFER_SEEN; i < ${#lines[@]}; i++ )); do
        IFS=$'\t' read -r what name why note <<< "${lines[i]}"
        case $what in
            ok) XFER_OK=$(( XFER_OK + 1 ))
                case $note in
                    archive+diz) said="OK, the archive opens, description found" ;;
                    archive) said="OK, the archive opens" ;;
                    *) said=OK ;;
                esac
                printf '  Testing %s... %s\n' "$(safe <<< "$name")" "$said"
                if [[ $note != archive+diz && $why =~ ^[0-9]+-[0-9a-f]{8}$ ]]; then
                    XFER_NEW_IDS+=("$why")
                    XFER_NEW_NAMES+=("$name")
                fi
                ;;
            rejected) XFER_BAD=$(( XFER_BAD + 1 ))
                printf '  Testing %s... Rejected: %s\n' "$(safe <<< "$name")" "$(safe <<< "$why")" ;;
            done) finished=0 ;;
        esac
    done
    XFER_SEEN=${#lines[@]}
    return "$finished"
}

# ---- Flags: files marked for one D. One id per line, kept in the home directory ----
XFER_MAX_FILES=20               # what x.cgi takes on one ticket
FLAGS=()

flag_has() { # flag_has <id>
    local f
    for f in "${FLAGS[@]}"; do [[ $f == "$1" ]] && return 0; done
    return 1
}

# Files that have gone away drop out here, without a word.
flags_load() {
    local id
    FLAGS=()
    [[ -f $HOME/.bashbbs-flags ]] || return 0
    while IFS= read -r id; do
        (( ${#FLAGS[@]} < XFER_MAX_FILES )) || break
        [[ $id =~ ^[0-9]+-[0-9a-f]{8}$ && -f $BBS_ROOT/published/$id && -f $BBS_ROOT/published/$id.meta ]] || continue
        flag_has "$id" || FLAGS+=("$id")
    done < <(head -c 8192 "$HOME/.bashbbs-flags" 2>/dev/null)
    return 0
}

flags_save() {
    local tmp
    tmp=$(mktemp "$HOME/.bashbbs-flags.XXXXXX" 2>/dev/null) || return 1
    if { (( ${#FLAGS[@]} == 0 )) || printf '%s\n' "${FLAGS[@]}"; } > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$HOME/.bashbbs-flags" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

flags_saved_or_say() {
    flags_save && return 0
    echo "Could not save your flags right now."
    pause
}

flag_drop() { # flag_drop <id>
    local f keep=()
    for f in "${FLAGS[@]}"; do [[ $f == "$1" ]] || keep+=("$f"); done
    FLAGS=("${keep[@]}")
}

flag_toggle() { # flag_toggle <id>
    if flag_has "$1"; then
        flag_drop "$1"
    elif (( ${#FLAGS[@]} >= XFER_MAX_FILES )); then
        echo "You can flag up to $XFER_MAX_FILES files at a time."
        pause
        return 0
    else
        FLAGS+=("$1")
    fi
    flags_saved_or_say
}

flags_clear() {
    FLAGS=()
    flags_saved_or_say
}

# ---- Downloads ---------------------------------------------------------------------
declare -gA XFER_BASE=() XFER_GOT=()
XFER_IDS=()

# Sets XF_NAME and XF_SIZE. No when the file has gone away.
xfer_facts() { # xfer_facts <id>
    local meta=$BBS_ROOT/published/$1.meta
    [[ -f $BBS_ROOT/published/$1 && -r $meta ]] || return 1
    XF_NAME=$(sed -n 's/^name=//p' "$meta" | head -n 1 | safe)
    XF_SIZE=$(sed -n 's/^size=//p' "$meta" | head -n 1)
    [[ $XF_SIZE =~ ^[0-9]+$ ]] || XF_SIZE=0
}

# "count id" per file <login> has downloaded, from the log the session can already read.
xfer_down_counts() {
    awk -F'\t' -v u="$login" '$2 == u && $3 == "down" { c[$4]++ } END { for (i in c) print c[i], i }' \
        "$BBS_ROOT/state/transfers.log" 2>/dev/null
}

# Yes when every file of this D has a new line in the log. One line per file when
# there are several, so the wait shows it is moving.
xfer_check_down() {
    local n id left=0
    local -A now=()
    while read -r n id; do now[$id]=$n; done < <(xfer_down_counts)
    for id in "${XFER_IDS[@]}"; do
        [[ -n ${XFER_GOT[$id]:-} ]] && continue
        if (( ${now[$id]:-0} > ${XFER_BASE[$id]:-0} )); then
            XFER_GOT[$id]=1
            if (( ${#XFER_IDS[@]} > 1 )) && xfer_facts "$id"; then
                printf '  Sent  %s\n' "$XF_NAME"
            fi
        else
            left=1
        fi
    done
    (( left == 0 ))
}

# What has come through stops being flagged, also when the wait ended early.
xfer_unflag_got() {
    local id changed=0
    flags_load
    for id in "${!XFER_GOT[@]}"; do
        if flag_has "$id"; then flag_drop "$id"; changed=1; fi
    done
    (( changed == 0 )) || flags_save || true
}

xfer_no_link() {
    echo "Could not make a link right now. Try again later."
    pause
}

# The link and the promise, the same on both screens.
xfer_show_link() { # xfer_show_link <token> <minutes>
    echo "Open this link in your browser. It works for $2 minutes."
    echo
    xfer_url "$1"
    echo
    echo "Waiting for your browser... (Q) back to menu."
    echo "The transfer goes on if you leave."
    echo
}

# U: what there is room for, then the link. Files go to the area given, or the default.
# Returns 1 at end of input.
xfer_upload() { # xfer_upload [area]
    local why token area=${1:-}
    redraw
    local_header "Upload" "[Q] Back"
    if [[ -n $area ]] && (( ${#FA_SLUGS[@]} > 1 )); then
        printf '%-11s %s\n' "Area:" "$(fa_title "$area")"
    fi
    printf '%-11s %s\n' "Per file:" "up to $(files_size "$UPLOAD_MAX_BYTES")"
    printf '%-11s %s of %s\n' "Your files:" "$(files_size "$(ub_used "$login")")" "$(files_size "$UPLOAD_USER_QUOTA")"
    echo
    if ! why=$(ub_check "$login"); then
        echo "Uploads are closed right now: $why."
        pause
        return 0
    fi
    token=$(xfer_ticket up ${area:+"area=$area"}) || { xfer_no_link; return 0; }
    xfer_show_link "$token" "$(( XFER_TTL_UP / 60 ))"
    echo "Each file is tested for name, size, your quota and duplicates, and zip and"
    echo "lha archives for whether they open. This is not a virus scan."
    echo
    XFER_SEEN=0 XFER_OK=0 XFER_BAD=0 XFER_NEW_IDS=() XFER_NEW_NAMES=()
    xfer_wait "$XFER_TTL_UP" xfer_check_up "$token" || return 1
    case $XFER_OUTCOME in
        done)
            echo
            echo "Finished: $XFER_OK published, $XFER_BAD rejected. New files show within a minute."
            xfer_describe_new || return 1
            pause ;;
        expired)
            echo "The link has run out. Press U for a new one."
            pause ;;
    esac
}

# Up to 3 lines of 60 characters into XFER_DESC. An empty line finishes. Returns 1 at
# end of input. The sorter cleans the text again; this only keeps it short.
xfer_ask_desc() { # xfer_ask_desc <name>
    local n line
    XFER_DESC=
    echo "Enter a description for $1."
    echo "Up to 3 lines of 60 characters. An empty line finishes."
    for n in 1 2 3; do
        rline line "$n> " || return 1
        [[ -n $line ]] || break
        XFER_DESC+=${line:0:60}$'\n'
    done
    return 0
}

# Hands the text to the sorter, which alone can write the .meta: written beside the
# final name first, so it never reads half a request. Empty text removes the description.
xfer_send_desc() { xfer_request filedesc "$1.desc" "$2"; } # xfer_send_desc <id> <text>
xfer_send_area() { xfer_request filearea "$1.area" "$2"; } # xfer_send_area <id> <slug>

# M in a file's view: sets XFER_AREA, empty when nothing was picked. Needs fa_load.
# Returns 1 at end of input.
xfer_ask_area() { # xfer_ask_area <the area it is in>
    local i mark
    XFER_AREA=""
    echo "Move it to which area?"
    for (( i = 0; i < ${#FA_SLUGS[@]}; i++ )); do
        mark=""
        [[ ${FA_SLUGS[i]} == "$1" ]] && mark=" (it is here)"
        printf '%s %s%s\n' "$(paint KEY "$(printf '%2d)' $(( i + 1 )))")" "${FA_TITLES[i]}" "$mark"
    done
    printf 'Number, or anything else to leave it: '
    read_key_raw || return 1
    [[ $MKEY == [1-9] ]] || return 0
    read_num "${#FA_SLUGS[@]}" || return 0
    XFER_AREA=${FA_SLUGS[NUM - 1]}
}

# A request to the sorter: the file appears whole, and the sorter is woken.
xfer_request() { # xfer_request <queue> <file name> <text>
    local dir=$BBS_ROOT/queue/$1 tmp
    tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 1
    if ! printf '%s' "$3" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$2" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    { : > "$BBS_ROOT/queue/kick/$login.$$"; } 2>/dev/null
    return 0
}

# After an upload: the files that brought no FILE_ID.DIZ. Returns 1 at end of input.
xfer_describe_new() {
    local i
    for i in "${!XFER_NEW_IDS[@]}"; do
        echo
        xfer_ask_desc "$(safe <<< "${XFER_NEW_NAMES[i]}")" || return 1
        [[ -n $XFER_DESC ]] || continue
        xfer_send_desc "${XFER_NEW_IDS[i]}" "$XFER_DESC" \
            || echo "Could not save that right now. E on the file's page tries again."
    done
    return 0
}

# D: what is about to go, the last chance to say no, then the link. Returns 1 at end of
# input and after Goodbye (nav_req is then quit); XFER_OUTCOME says how the wait went.
xfer_download() { # xfer_download <id>...
    local id token title= total=0 goodbye=0 ids=() w rc
    XFER_OUTCOME=
    redraw
    (( $# == 1 )) && xfer_facts "$1" && title=$XF_NAME
    local_header "${title:-Download}" "[Q] Back"
    w=$(( $(list_width) - 11 ))
    for id in "$@"; do
        xfer_facts "$id" || continue
        ids+=("$id")
        total=$(( total + XF_SIZE ))
        printf '%-*s %8s\n' "$w" "$(list_fit "$w" "$XF_NAME")" "$(files_size "$XF_SIZE")"
    done
    if (( ${#ids[@]} == 0 )); then
        echo "That file is no longer here."
        pause
        return 0
    fi
    echo
    echo "$(count_text "${#ids[@]}" file files), $(files_size "$total")."
    drain_input
    printf 'LAST CHANCE! (Enter) to Start, (G)oodbye after transfer, (A)bort? '
    while true; do
        read_key_raw || return 1
        [[ -z $MESC ]] || continue
        case $MKEY in
            '') break ;;
            [Gg]) goodbye=1; break ;;
            [AaQq]) echo; return 0 ;;
        esac
    done
    echo
    echo
    XFER_IDS=("${ids[@]}") XFER_BASE=() XFER_GOT=()
    while read -r rc id; do XFER_BASE[$id]=$rc; done < <(xfer_down_counts)
    token=$(xfer_ticket down "${ids[@]/#/id=}") || { xfer_no_link; return 0; }
    xfer_show_link "$token" "$(( XFER_TTL_DOWN / 60 ))"
    if (( goodbye )); then
        echo "You will be logged out when it is done. (Q) stays logged in."
        echo
    fi
    xfer_wait "$XFER_TTL_DOWN" xfer_check_down
    rc=$?
    [[ $XFER_OUTCOME == done ]] || xfer_check_down > /dev/null
    xfer_unflag_got
    (( rc == 0 )) || return 1
    case $XFER_OUTCOME in
        done) echo "Downloaded." ;;
        expired) echo "The link has run out. Press D for a new one." ;;
        *) return 0 ;;
    esac
    if (( goodbye )); then
        nav_req=quit
        LOGOUT_QUIET=1
        return 1
    fi
    pause
}

# O: the ways a file can travel. There is nothing to choose between yet.
xfer_options() {
    redraw
    local_header "Transfer options" "[Q] Back"
    echo "Web link   U and D show a link. Open it in any browser, also on a phone."
    echo "           Nothing else to install."
    echo
    echo "scp        From a terminal on your own machine, next to the session:"
    echo "           scp -O -P $BBS_PUBLIC_PORT FILE $login@$BBS_PUBLIC_HOST:"
    echo "           scp -O -P $BBS_PUBLIC_PORT $login@$BBS_PUBLIC_HOST:NAME ."
    echo
    pause
}
