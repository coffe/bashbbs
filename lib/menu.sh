#!/bin/bash
# BashBBS main menu. Runs as the login shell of a bbs-<name> account.
# Menu choices are single keys (read_key). Text is read line by line with
# rline (read -r). Neither reaches eval or a shell.
set -u
umask 077

BBS_ROOT=${BBS_ROOT:-/srv/bashbbs}
LIB=/usr/local/lib/bashbbs
# Domain of the private-message addresses. Same value as BASHBBS_MAIL_DOMAIN in
# lib/install-helpers.sh. It must be a domain that local Postfix delivers to.
BBS_MAIL_DOMAIN=${BBS_MAIL_DOMAIN:-bbs.localdomain}
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
    # A terminal type without a terminfo entry (SyncTERM sends "syncterm") makes clear fail.
    clear 2>/dev/null || printf '\033[H\033[2J'
}

# ---- Input lines ------------------------------------------------------------
# A typed line is at most INPUT_MAX characters (a mail body is 8192 bytes, so no honest
# line is longer). Over a terminal the kernel already caps a line near 4 KB and handles
# backspace; over a pipe (ssh -T) nothing caps it,
# so one endless line would grow bash until the Pi runs out of memory. A longer line
# is thrown away up to its Enter, so what is left of it can never act as menu keys.
# rline <var> [prompt] [raw]: RLINE_LONG=1 and <var> empty when the line was too long
# (the notice goes to stderr, stdout may be a post file). Returns 1 at end of input.
# Unless "raw" is given, leading and trailing blanks are trimmed, as read -r does.
INPUT_MAX=8192
RLINE_LONG=

rline_drain() { # discard the rest of the current line, in bounded pieces
    local d
    while IFS= read -r -n 4096 d; do
        (( ${#d} < 4096 )) && return 0
    done
    return 1
}

rline() {
    local __v=$1 __p=${2-} __raw=${3-} __l __c
    RLINE_LONG=
    if [[ -t 0 ]]; then
        IFS= read -r -p "$__p" __l || return 1
        (( ${#__l} > INPUT_MAX )) && RLINE_LONG=1
    else
        IFS= read -r -n "$INPUT_MAX" __l || return 1
        if (( ${#__l} >= INPUT_MAX )); then
            # Exactly INPUT_MAX read and no Enter yet: an Enter next is still a fit.
            IFS= read -r -n 1 __c || return 1
            [[ -z $__c ]] || { RLINE_LONG=1; rline_drain || true; }
        fi
    fi
    if [[ -n $RLINE_LONG ]]; then
        __l=
        echo "Line too long (max $INPUT_MAX characters), ignored." >&2
    elif [[ -z $__raw ]]; then
        __l=${__l#"${__l%%[![:space:]]*}"}; __l=${__l%"${__l##*[![:space:]]}"}
    fi
    printf -v "$__v" '%s' "$__l"
    return 0
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
        # hidden=yes keeps test and staff accounts off the public list.
        grep -qx 'hidden=yes' "$f" && continue
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
    echo
    echo "[K] SSH keys"
    read_key "[Any key] " || true
    echo
    [[ $MKEY == [Kk] ]] && ssh_keys_menu
    return 0
}

# ---- SSH keys ---------------------------------------------------------------
# The screen reads keys/bbs-<name> and users/<name>/keys.meta (both world-readable)
# and state/keys-results/<name>. It never writes there. A change is a request file
# in queue/keys; bbs-keys-apply (root) validates it again and does the work.
KEYS_MAX=8
KEYS_SENT_ID=()     # requests sent in this session ...
KEYS_SENT_TXT=()    # ... and a short text for each ("add laptop")
k_fp=() k_label=() k_type=() k_legacy=() k_seen=()
PICK=

# Fill k_* from the key file. Order is the order in the file. Labels, "tested" and the
# legacy flag come from keys.meta, matched by fingerprint. Fields are split on 0x1f
# (not Tab) so an empty field does not make the others shift.
keys_load() {
    local line bits fp ty t mfp mlabel madded msrc mseen mleg i=0
    local -A m_label=() m_seen=() m_leg=()
    k_fp=() k_label=() k_type=() k_legacy=() k_seen=()
    if [[ -r $BBS_ROOT/users/$me/keys.meta ]]; then
        while IFS=$'\x1f' read -r mfp mlabel madded msrc mseen mleg; do
            [[ $mfp =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || continue
            m_label[$mfp]=$(printf '%s' "$mlabel" | safe)
            m_seen[$mfp]=$(printf '%s' "${mseen:--}" | safe)
            m_leg[$mfp]=$(printf '%s' "${mleg:-0}" | safe)
        done < <(sed 's/\t/\x1f/g' "$BBS_ROOT/users/$me/keys.meta" 2>/dev/null)
    fi
    [[ -r $BBS_ROOT/keys/$login ]] || return 0
    while IFS= read -r line; do
        [[ $line =~ ^([0-9]+)\ (SHA256:[A-Za-z0-9+/]+)\ .*\(([A-Za-z0-9-]+)\)$ ]] || continue
        bits=${BASH_REMATCH[1]} fp=${BASH_REMATCH[2]} ty=${BASH_REMATCH[3],,}
        case $ty in
            ed25519) t=ed25519 ;;
            ed25519-sk) t=ed25-sk ;;
            *) t=$ty$bits ;;
        esac
        k_fp+=("$fp")
        k_type+=("$t")
        if [[ -n ${m_label[$fp]:-} ]]; then k_label+=("${m_label[$fp]}")
        elif (( i == 0 )); then k_label+=(registration)
        else k_label+=(key); fi
        if [[ ${m_leg[$fp]:-0} == 1 || ( $ty == rsa && $bits == 1536 ) ]]; then k_legacy+=(1); else k_legacy+=(0); fi
        if [[ -n ${m_seen[$fp]:-} && ${m_seen[$fp]} != - ]]; then k_seen+=(1); else k_seen+=(0); fi
        i=$((i + 1))
    done < <(ssh-keygen -l -f "$BBS_ROOT/keys/$login" 2>/dev/null)
    return 0
}

# One row per key, 39 columns: number, ! for a legacy key, label, type, the first
# eight characters of the fingerprint, tested or untested.
keys_list() {
    local i flag st
    if (( ${#k_fp[@]} == 0 )); then
        echo "No keys."
        return
    fi
    for i in "${!k_fp[@]}"; do
        flag=" "; (( k_legacy[i] )) && flag="!"
        st=untested; (( k_seen[i] )) && st=tested
        printf '%s%s %-9s %-8s %-8s %s\n' "$((i + 1))" "$flag" \
            "$(list_fit 9 "${k_label[i]}")" "$(list_fit 8 "${k_type[i]}")" \
            "${k_fp[i]:7:8}" "$st"
    done
}

# The last five lines of state/keys-results/<name>, then requests of this session that
# are still in the queue. A request that is still in queue/keys shows as pending.
keys_status() {
    local f=$BBS_ROOT/state/keys-results/$me id ts act label st why i out=""
    local -A got=()
    if [[ -r $f ]]; then
        while IFS=$'\x1f' read -r id ts act label st why; do
            [[ $id =~ ^[0-9]+-[A-Za-z0-9-]+$ ]] || continue
            got[$id]=1
            [[ -e $BBS_ROOT/queue/keys/$id.keys ]] && st=pending
            out+=$(printf '%s%s: %s%s' "$act" "${label:+ $label}" "$st" "${why:+ - $why}" | safe)$'\n'
        done < <(tail -n 5 "$f" | sed 's/\t/\x1f/g')
    fi
    for i in "${!KEYS_SENT_ID[@]}"; do
        [[ -n ${got[${KEYS_SENT_ID[i]}]:-} ]] && continue
        [[ -e $BBS_ROOT/queue/keys/${KEYS_SENT_ID[i]}.keys ]] || continue
        out+="${KEYS_SENT_TXT[i]}: pending"$'\n'
    done
    [[ -n $out ]] || return 0
    echo "Recent requests:"
    printf '%s' "$out" | python3 "$NEWS_LIB/wrap.py" --keep-lines "$(term_width)"
    echo
}

# Plain checks when bbs-keycheck is not installed. Same answer format as the tool:
# OK<Tab>type<Tab>body<Tab>fingerprint<Tab>bits (exit 0), ERR<Tab>code<Tab>text (exit 1),
# exit 2 for RSA 1536 without --legacy.
keys_check_local() { # keys_check_local <line> [--legacy]
    local type body rest tmp out bits fp want got
    read -r type body rest <<< "$1"
    case $type in
        ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *-cert-v01@openssh.com) printf 'ERR\tcert\tCertificates are not accepted.\n'; return 1 ;;
        *) printf 'ERR\ttype\tThat is not a public key line.\n'; return 1 ;;
    esac
    [[ $body =~ ^[A-Za-z0-9+/]+=*$ ]] || { printf 'ERR\tbase64\tThe key text is not valid.\n'; return 1; }
    tmp=$(mktemp) || { printf 'ERR\tkeygen\tCould not check the key.\n'; return 1; }
    printf '%s %s\n' "$type" "$body" > "$tmp"
    out=$(ssh-keygen -l -f "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [[ $out =~ ^([0-9]+)\ (SHA256:[A-Za-z0-9+/]+)\ .*\(([A-Za-z0-9-]+)\)$ ]] \
        || { printf 'ERR\tkeygen\tThe key is not valid.\n'; return 1; }
    bits=${BASH_REMATCH[1]} fp=${BASH_REMATCH[2]} got=${BASH_REMATCH[3]}
    case $type in
        ssh-ed25519) want=ED25519 ;;
        ssh-rsa) want=RSA ;;
        ecdsa-sha2-*) want=ECDSA ;;
        sk-ssh-ed25519@*) want=ED25519-SK ;;
        *) want=ECDSA-SK ;;
    esac
    [[ $got == "$want" ]] || { printf 'ERR\tmismatch\tThe key type does not match.\n'; return 1; }
    if [[ $want == RSA ]] && (( bits < 2048 )); then
        if (( bits == 1536 )); then
            [[ ${2:-} == --legacy ]] || {
                printf 'ERR\tlegacy-needed\tRSA keys under 2048 bits are not accepted. SyncTERM 1.9 uses 1536: type LEGACY to accept this one.\n'
                return 2
            }
        else
            printf 'ERR\trsa-short\tRSA keys under 2048 bits are not accepted.\n'
            return 1
        fi
    fi
    printf 'OK\t%s\t%s\t%s\t%s\n' "$type" "$body" "$fp" "$bits"
}

# One line in, the answer of bbs-keycheck out (its exit status too). The tool is the
# fast feedback; the root side checks again. BBS_KEYCHECK may point at a stub, tests only.
keys_check() { # keys_check <line> [--legacy]
    local kc=
    if [[ -n ${BASHBBS_TEST:-} && -n ${BBS_KEYCHECK:-} ]]; then
        kc=$BBS_KEYCHECK
    else
        kc=$(command -v bbs-keycheck) || kc=
        [[ -z $kc && -x /usr/local/sbin/bbs-keycheck ]] && kc=/usr/local/sbin/bbs-keycheck
    fi
    if [[ -n $kc ]]; then
        printf '%s\n' "$1" | "$kc" ${2:+"$2"}
        return
    fi
    keys_check_local "$@"
}

# Write a request file (text on stdin) into queue/keys. The directory is 1733: the user
# can create files there but not list or replace the others. Built under a dot name and
# moved into place without overwriting (mv -n), so the publisher never sees a half file.
# On success the id is in KEYS_REQ_ID.
keys_request() {
    local dir=$BBS_ROOT/queue/keys tmp uuid
    KEYS_REQ_ID=
    tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 1
    cat > "$tmp"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    KEYS_REQ_ID=$(date +%s)-${uuid//-/}
    mv -n "$tmp" "$dir/$KEYS_REQ_ID.keys" 2>/dev/null
    if [[ -e $tmp ]]; then rm -f "$tmp"; KEYS_REQ_ID=; return 1; fi
    return 0
}

# Send a request and say so. <text> is the short name for the status list.
keys_send() { # keys_send <text>; request on stdin
    if keys_request; then
        KEYS_SENT_ID+=("$KEYS_REQ_ID")
        KEYS_SENT_TXT+=("$1")
        echo "Received. Active within 60 s."
        return 0
    fi
    echo "Could not send the request."
    return 1
}

# Print a fingerprint folded to fit 40 columns.
keys_fp_show() {
    echo "Fingerprint:"
    printf '%s\n' "$1" | fold -w 36 | sed 's/^/  /'
}

# Label: trimmed, 1-20 of A-Za-z0-9 space . _ -. Returns it in KEYS_LABEL.
keys_label_ask() { # keys_label_ask <prompt>
    local l
    KEYS_LABEL=
    echo "Letters, digits, space . _ - (max 20)."
    echo "[Enter] cancels."
    rline l "$1" || return 1
    l=${l#"${l%%[![:space:]]*}"}; l=${l%"${l##*[![:space:]]}"}
    [[ -n $l ]] || return 1
    [[ $l =~ ^[A-Za-z0-9\ ._-]{1,20}$ ]] || { echo "Not a valid label."; pause; return 1; }
    KEYS_LABEL=$l
}

# Choose a key by number. The index is in PICK. Returns 1 when abandoned.
keys_pick() { # keys_pick <prompt>
    local n=${#k_fp[@]}
    PICK=
    (( n > 0 )) || { echo "No keys."; pause; return 1; }
    read_key "$1 [1-$n] " || { echo; return 1; }
    [[ $MKEY == [1-9] ]] || { echo; return 1; }
    read_num "$n" || { echo; return 1; }
    echo
    PICK=$((NUM - 1))
}

keys_add() {
    local line out rc kind ty body fp bits legacy="" ans f
    keys_load
    redraw
    local_header "Add SSH key"
    if (( ${#k_fp[@]} >= KEYS_MAX )); then
        echo "Key limit reached ($KEYS_MAX). Remove one first."
        pause
        return
    fi
    echo "Paste ONE public key line."
    echo "[Enter] cancels."
    rline line "> " || return
    line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] || return
    if [[ ${line^^} == -----BEGIN* || ${line^^} == *"PRIVATE KEY"* || ${line^^} == *"PUTTY-USER-KEY-FILE"* ]]; then
        echo "That looks like a private key. Never paste it anywhere." | python3 "$NEWS_LIB/wrap.py" "$(term_width)"
        pause
        return
    fi
    if (( $(printf '%s' "$line" | wc -c) > 4096 )); then
        echo "Too long (max 4096 bytes)."
        pause
        return
    fi
    if [[ $line == *[[:cntrl:]]* ]]; then
        echo "That is not a key line."
        pause
        return
    fi
    out=$(keys_check "$line"); rc=$?
    if (( rc == 2 )); then
        IFS=$'\t' read -r kind ty body <<< "$out"
        echo
        printf '%s\n' "$body" | safe | python3 "$NEWS_LIB/wrap.py" "$(term_width)"
        rline ans "Type LEGACY to accept: " || return
        [[ $ans == LEGACY ]] || { echo "Cancelled."; pause; return; }
        legacy=yes
        out=$(keys_check "$line" --legacy); rc=$?
    fi
    IFS=$'\t' read -r kind ty body fp bits <<< "$out"
    if [[ $kind != OK ]]; then
        if [[ $kind == ERR && -n $body ]]; then ans=$(printf '%s' "$body" | safe); else ans="The key was not accepted."; fi
        printf '%s\n' "$ans" | python3 "$NEWS_LIB/wrap.py" "$(term_width)"
        pause
        return
    fi
    if [[ ! $ty =~ ^[a-z0-9@.-]+$ || ! $body =~ ^[A-Za-z0-9+/]+=*$ || ! $fp =~ ^SHA256:[A-Za-z0-9+/]{43}$ || ! $bits =~ ^[0-9]+$ ]]; then
        echo "The key check gave a bad answer."
        pause
        return
    fi
    for f in "${k_fp[@]}"; do
        [[ $f == "$fp" ]] && { echo "That key is already added."; pause; return; }
    done
    echo
    keys_label_ask "Label: " || return
    echo
    echo "Label: $KEYS_LABEL"
    echo "Type:  $ty, $bits bits"
    [[ -n $legacy ]] && echo "Legacy RSA 1536 key."
    keys_fp_show "$fp"
    read_confirm "Add this key? [y/N] " || { echo "Cancelled."; pause; return; }
    keys_send "add $KEYS_LABEL" < <(
        printf 'Action: add\nLabel: %s\nKey: %s %s\n' "$KEYS_LABEL" "$ty" "$body"
        [[ -n $legacy ]] && printf 'Legacy: yes\n'
    ) || { pause; return; }
    echo "Test the new key in a second session"
    echo "before removing the old one."
    pause
}

keys_remove() {
    keys_load
    redraw
    local_header "Remove SSH key"
    if (( ${#k_fp[@]} < 2 )); then
        if (( ${#k_fp[@]} == 0 )); then echo "No keys."; else
            echo "This is your only key. Removing it"
            echo "would lock you out. Add another key,"
            echo "test it, then remove this one."
        fi
        pause
        return
    fi
    keys_list
    echo
    keys_pick "Remove number" || return
    echo "Label: ${k_label[PICK]}"
    keys_fp_show "${k_fp[PICK]}"
    echo
    echo "Make sure you can still log in with a remaining key." | python3 "$NEWS_LIB/wrap.py" "$(term_width)"
    read_confirm "Remove this key? [y/N] " || { echo "Cancelled."; pause; return; }
    keys_send "remove ${k_label[PICK]}" \
        < <(printf 'Action: remove\nFingerprint: %s\nConfirm: yes\n' "${k_fp[PICK]}")
    pause
}

keys_rename() {
    keys_load
    redraw
    local_header "Rename SSH key"
    (( ${#k_fp[@]} > 0 )) || { echo "No keys."; pause; return; }
    keys_list
    echo
    keys_pick "Rename number" || return
    keys_label_ask "New label: " || return
    keys_send "rename $KEYS_LABEL" \
        < <(printf 'Action: rename\nLabel: %s\nFingerprint: %s\n' "$KEYS_LABEL" "${k_fp[PICK]}")
    pause
}

ssh_keys_menu() {
    while true; do
        keys_load
        redraw
        local_header "SSH keys" "[Q] Back"
        keys_list
        echo
        keys_status
        echo "A) Add  R) Remove  N) Name  Q) Back"
        menu_key "> " "AaRrNnQq" "A: add  R: remove  N: rename  Q: back
!: legacy RSA 1536 key
untested: no login seen with this key
Test a new key before removing old ones" local || return
        case $MKEY in
            [Aa]) keys_add ;;
            [Rr]) keys_remove ;;
            [Nn]) keys_rename ;;
            [Qq]) return ;;
        esac
    done
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

# Posts of a board that are shown to users, in file order, one path per line. A
# deleted post (Deleted header) is a stub: it stays on disk with its Msgid and Parent, but
# it is listed only while an active post is below it (a reply, at any depth), so that
# thread stays readable. Deleted posts with nothing active below them are hidden.
# Only the headers are read; nothing is written.
visible_posts() { # visible_posts <board>
    local f dir=$BBS_ROOT/boards/$1
    for f in "$dir"/*.msg; do
        [[ -f $f && ! -L $f ]] && printf '%s\n' "$f"
    done | awk '
        function hdr(line) { sub(/\r$/, "", line); return substr(line, index(line, ":") + 2) }
        { file[++n] = $0; id[n] = ""; par[n] = ""; del[n] = 0
          while ((getline line < $0) > 0 && line != "" && line != "\r") {
              if (line ~ /^Msgid:/) id[n] = hdr(line)
              else if (line ~ /^Parent:/) par[n] = hdr(line)
              else if (line ~ /^Deleted:/) del[n] = 1
          }
          close($0)
          if (id[n] != "") at[id[n]] = n }
        END {
            for (i = 1; i <= n; i++) if (!del[i]) {
                keep[i] = 1
                # Mark every ancestor as needed context. The step limit guards against a loop.
                j = i
                for (step = 0; step < 1000 && par[j] != "" && (par[j] in at); step++) {
                    j = at[par[j]]
                    if (keep[j]) break
                    keep[j] = 1
                }
            }
            for (i = 1; i <= n; i++) if (keep[i]) print file[i]
        }'
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
        mapfile -t files < <(visible_posts "$board")
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
    rline new "New subject ([Enter] keeps): " || return
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
    rline answer "Type DELETE ([Enter] Back): " || return
    [[ $answer == DELETE ]] || return
    printf 'Action: delete-post\nBoard: %s\nMsgid: %s\n\n' "$1" "$(post_hdr "$2" Msgid)" | queue_request
    echo "Sent. Appears within a minute."
    pause
}

# Text lines up to a line with only a dot, at most 200 lines. Used by compose and edit.
read_body() {
    local line count=0
    while rline line "" raw; do
        [[ -n $RLINE_LONG ]] && continue
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
    rline subject "Subject: " || return
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
    rline name "Name (a-z, 0-9, - and _; 2-24 chars): " || return
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
    rline user "User: " || return
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

# The name a user typed as a BBS name: lower case, with one leading bbs- dropped.
pm_name() {
    local name=${1,,}
    printf '%s' "${name#bbs-}"
}

# The only place that knows local addresses: a name becomes a local account.
# Only names with a BBS profile count, so no Linux account is reachable this way.
resolve_local() {
    local name
    name=$(pm_name "$1")
    valid_user "$name" || return 1
    # The news accounts are never private-message recipients, even with a profile.
    [[ $name == news || $name == newsstatus ]] && return 1
    printf 'bbs-%s' "$name"
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
# A line with /cancel stops without output. Returns 1 on cancel, a line over INPUT_MAX
# or a body that is too long.
mail_body() {
    local line total=0 LC_ALL=C
    while rline line "" raw; do
        [[ -n $RLINE_LONG ]] && return 1
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
    to=$(pm_name "$to")
    host=$BBS_MAIL_DOMAIN
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
    if [[ -z $to ]]; then rline to "To, e.g. kitty (/cancel stops): " || return; fi
    [[ $to == /cancel ]] && return
    resolve_local "$to" >/dev/null || { echo "Unknown user."; pause; return; }
    # The default in brackets is shown cut to the line; Enter still keeps the full subject.
    local shown=""
    [[ -n $subject ]] && shown=" [$(list_fit $(( $(list_width) - 28 )) "$subject")]"
    rline line "Subject${shown} (/cancel stops): " || return
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
            4) my_account ;;
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
    rline text "> " || return
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

# Public board posts newer than <since>, deleted ones not counted. The file name starts
# with the publish epoch.
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
            [[ $pre =~ ^[0-9]+$ ]] && (( 10#$pre > since )) || continue
            # A deleted post is a stub, not new activity.
            [[ -z $(post_hdr "$f" Deleted) ]] && n=$((n + 1))
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

# ---- Intro ------------------------------------------------------------------
# Optional screens before the welcome screen. An installation shows its own, or none:
# without $BBS_ROOT/etc/intro/intro.conf nothing happens. The text and art live in
# files next to intro.conf, never in this script. One screen per line in intro.conf:
#     <seconds> <file> [<narrow-file> [<caption-file> [<narrow-caption-file>]]]   (- = no narrow-file)
# <file> may be a|b|c: one of them is picked at random for each login. It is shown as it is when the terminal is at least as wide as its widest line,
# otherwise <narrow-file>; with no fitting file the screen is skipped. <caption-file>
# is printed under the file with one empty line between. Lines are never wrapped,
# centred or changed (a CR from a DOS file is dropped, empty lines at the end of the
# art are not shown). Space ends a screen at once, any other key is ignored. File
# names are plain names in the intro directory.
INTRO_MAX_BYTES=16384

intro_file() { # intro_file <name>: prints the path when it is a plain, small file
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    local f=$BBS_ROOT/etc/intro/$1
    [[ -f $f && ! -L $f && -r $f ]] || return 1
    (( $(stat -c %s "$f") <= INTRO_MAX_BYTES )) || return 1
    printf '%s' "$f"
}

intro_width() { # intro_width <file>: widest line in terminal columns
    tr -d '\r' < "$1" | LC_ALL=C.UTF-8 wc -L
}

# Wait up to <seconds> for Space. Returns 0 when it ended on Space, 1 on timeout,
# 2 when the input is gone.
intro_wait() {
    local end=$(( SECONDS + $1 )) c
    while (( SECONDS < end )); do
        if IFS= read -rsn1 -t 0.25 c; then
            [[ $c == ' ' ]] && return 0
        elif (( $? <= 128 )); then
            return 2
        fi
    done
    return 1
}

# After the last screen: Space presses still on their way (someone smashing the bar)
# are eaten until it is quiet for 0.3 s, but for 2 s at the most.
intro_swallow() {
    local end=$(( SECONDS + 2 ))
    while (( SECONDS < end )) && IFS= read -rsn1 -t 0.3 _; do :; done
}

# One of the names in <a|b|c>, each with the same chance. A single name is returned as is.
intro_pick() {
    local -a alts
    IFS='|' read -ra alts <<< "$1"
    printf '%s\n' "${alts[RANDOM % ${#alts[@]}]}"
}

intro_run() {
    local conf=$BBS_ROOT/etc/intro/intro.conf secs file narrow caption ncaption extra cols f w c shown=0
    [[ -t 0 && -t 1 && -r $conf ]] || return 0
    cols=$(list_width)
    while read -r -u 3 secs file narrow caption ncaption extra; do
        [[ $secs =~ ^[0-9]+$ ]] && (( secs >= 1 && secs <= 60 )) || continue
        f=$(intro_file "$(intro_pick "${file:-}")") || continue
        w=$(intro_width "$f")
        if (( w > cols )); then
            [[ -n $narrow ]] && f=$(intro_file "$narrow") || continue
            w=$(intro_width "$f")
            (( w <= cols )) || continue
        fi
        (( shown )) && drain_input
        redraw
        tr -d '\r' < "$f" | awk '/^[[:space:]]*$/ { b = b $0 "\n"; next } { printf "%s%s\n", b, $0; b = "" }'
        printf '\033[0m'
        c=$(intro_file "${caption:--}") || c=""
        if [[ -n $c ]] && (( $(intro_width "$c") > cols )); then
            c=$(intro_file "${ncaption:--}") || c=""
            [[ -z $c ]] || (( $(intro_width "$c") <= cols )) || c=""
        fi
        if [[ -n $c ]]; then
            echo
            tr -d '\r' < "$c"
            printf '\033[0m\n'
        fi
        shown=1
        intro_wait "$secs"; (( $? == 2 )) && return 0
    done 3< <(grep -v '^[[:space:]]*#' "$conf")   # fd 3: the key reads below use stdin
    (( shown )) && intro_swallow
    return 0
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
    intro_run
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
