# File transfers through a browser. The session makes a ticket, shows a link and
# waits; web/x.cgi moves the bytes and sbin/bbs-upload sorts them, so a transfer goes
# on even if the session ends. Sourced by menu.sh, never run. Needs BBS_ROOT, login
# and the helpers in menu.sh and upload-common.sh.

XFER_POLL=${XFER_POLL:-2}       # seconds between looks at the results while waiting
XFER_OUTCOME=                   # how the last wait ended: done, left or expired

# xfer_ticket <up|down> [id...]: prints the new token. Only the owner of the file
# counts for who the ticket is for, so it has to be readable for www-data.
xfer_ticket() {
    local dir=$1 token id body; shift
    token=$(head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    [[ $token =~ ^[A-Za-z0-9_-]{22}$ ]] || return 1
    body="dir=$dir"$'\n'
    for id in "$@"; do body+="id=$id"$'\n'; done
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

# Prints the result lines not shown yet. Yes when the page has said it is finished.
xfer_check_up() { # xfer_check_up <token>
    local f=$BBS_ROOT/state/xfer-results/$1 lines=() i what name why finished=1
    [[ -r $f ]] || return 1
    mapfile -t lines < "$f"
    for (( i = XFER_SEEN; i < ${#lines[@]}; i++ )); do
        IFS=$'\t' read -r what name why <<< "${lines[i]}"
        case $what in
            ok) XFER_OK=$(( XFER_OK + 1 ))
                printf '  OK        %s\n' "$(safe <<< "$name")" ;;
            rejected) XFER_BAD=$(( XFER_BAD + 1 ))
                printf '  Rejected  %s: %s\n' "$(safe <<< "$name")" "$(safe <<< "$why")" ;;
            done) finished=0 ;;
        esac
    done
    XFER_SEEN=${#lines[@]}
    return "$finished"
}

# Times <login> has downloaded <id>, from the log the session can already read.
xfer_down_count() { # xfer_down_count <id>
    local n
    n=$(awk -F'\t' -v u="$login" -v i="$1" '$2 == u && $3 == "down" && $4 == i { n++ } END { print n + 0 }' \
        "$BBS_ROOT/state/transfers.log" 2>/dev/null)
    printf '%s' "${n:-0}"
}

XFER_DOWN_BEFORE=0
xfer_check_down() { # xfer_check_down <id>
    (( $(xfer_down_count "$1") > XFER_DOWN_BEFORE ))
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

# U: what there is room for, then the link. Returns 1 at end of input.
xfer_upload() {
    local why token
    redraw
    local_header "Upload" "[Q] Back"
    printf '%-11s %s\n' "Per file:" "up to $(files_size "$UPLOAD_MAX_BYTES")"
    printf '%-11s %s of %s\n' "Your files:" "$(files_size "$(ub_used "$login")")" "$(files_size "$UPLOAD_USER_QUOTA")"
    echo
    if ! why=$(ub_check "$login"); then
        echo "Uploads are closed right now: $why."
        pause
        return 0
    fi
    token=$(xfer_ticket up) || { xfer_no_link; return 0; }
    xfer_show_link "$token" "$(( XFER_TTL_UP / 60 ))"
    XFER_SEEN=0 XFER_OK=0 XFER_BAD=0
    xfer_wait "$XFER_TTL_UP" xfer_check_up "$token" || return 1
    case $XFER_OUTCOME in
        done)
            echo
            echo "Finished: $XFER_OK published, $XFER_BAD rejected. New files show within a minute."
            pause ;;
        expired)
            echo "The link has run out. Press U for a new one."
            pause ;;
    esac
}

# D for one file. Returns 1 at end of input; XFER_OUTCOME says how it went.
xfer_download() { # xfer_download <id> <name>
    local id=$1 name=$2 token
    XFER_OUTCOME=
    redraw
    local_header "$name" "[Q] Back"
    XFER_DOWN_BEFORE=$(xfer_down_count "$id")
    token=$(xfer_ticket down "$id") || { xfer_no_link; return 0; }
    xfer_show_link "$token" "$(( XFER_TTL_DOWN / 60 ))"
    xfer_wait "$XFER_TTL_DOWN" xfer_check_down "$id" || return 1
    case $XFER_OUTCOME in
        done)
            echo "Downloaded."
            pause ;;
        expired)
            echo "The link has run out. Press D for a new one."
            pause ;;
    esac
}
