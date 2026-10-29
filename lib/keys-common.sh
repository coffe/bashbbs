# Shared code for the root key tools: sbin/bbs-keys-apply (queue handler) and
# sbin/bbs-keys (sysop CLI). Sourced, never run. Not for the menu.
# Paths are built only from a validated account name (keys_name_ok).
#
# Callers set BBS_ROOT and KEYS_TEST (1 = test mode: no logger) before keys_init.
# Key state of one account is held in parallel arrays, filled by keys_load:
#   K_LINES (exact keyfile lines) K_FP K_LABEL K_ADDED K_SOURCE K_SEEN K_LEGACY K_BITS K_TYPE

KEYS_MAX=8

keys_init() {
    KEYS_DIR=$BBS_ROOT/keys
    KEYS_USERS=$BBS_ROOT/users
    KEYS_STATE=$BBS_ROOT/state
    KEYS_LOCK=$KEYS_STATE/keys.lock
    KEYS_HIST=$KEYS_STATE/keys-history
    KEYS_RESULTS=$KEYS_STATE/keys-results
    KEYS_LOG=$KEYS_STATE/keys.log
    KEYS_CONF=$BBS_ROOT/etc/keys.conf
    KEYS_LOCK_WAIT=${BBS_LOCK_WAIT:-20}
    declare -gA KEYS_HIST_DONE=()
    install -d -m 0700 "$KEYS_HIST" 2>/dev/null
    install -d -m 0755 "$KEYS_RESULTS" 2>/dev/null
}

keys_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Name without the bbs- prefix. bbs-news is a system account, never a key owner.
keys_name_ok() { [[ $1 =~ ^[a-z][a-z0-9]{2,8}$ && $1 != news ]]; }

# Lock on fd 7. Returns 2 on timeout.
keys_lock_take() {
    exec 7>>"$KEYS_LOCK" || return 2
    flock -w "$KEYS_LOCK_WAIT" 7 || { exec 7>&-; return 2; }
}
keys_lock_drop() { exec 7>&-; }

# keys_log <account> <action> <fp> <label> <result> <reason>. Never a key body.
keys_log() {
    local now; now=$(keys_now)
    ( umask 077; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$@" >> "$KEYS_LOG" )
    [[ ${KEYS_TEST:-0} == 1 ]] && return 0
    logger -t bbs-keys -- "account=$1 action=$2 fp=$3 label=$4 result=$5 reason=$6" 2>/dev/null || true
}

# ALLOW_LEGACY_RSA_1536 from etc/keys.conf, parsed (never sourced). Default yes.
keys_legacy_allowed() {
    local v
    [[ -f $KEYS_CONF ]] || return 0
    v=$(sed -n 's/^ALLOW_LEGACY_RSA_1536=\(yes\|no\)[[:space:]]*$/\1/p' "$KEYS_CONF" | tail -n 1)
    [[ $v != no ]]
}

# keys_fp_line <line> -> "fp bits KIND" (ssh-keygen view of a stored line).
keys_fp_line() {
    local t out bits fp
    t=$(mktemp) || return 1
    printf '%s\n' "$1" > "$t"
    out=$(ssh-keygen -l -E sha256 -f "$t" 2>/dev/null); rm -f -- "$t"
    read -r bits fp _ <<< "$out"
    [[ $bits =~ ^[0-9]+$ && $fp =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
    out=${out##*(}
    printf '%s %s %s\n' "$fp" "$bits" "${out%)}"
}

# keys_load <name>: fill K_* from keys/bbs-<name> and users/<name>/keys.meta.
# Lines without meta get a row (first: registration, others: key/sysop).
# Meta rows for keys no longer in the keyfile are dropped. Returns 1 when the
# keyfile or the user dir is missing or not a plain file/dir.
keys_load() {
    local name=$1 kf mf ud line fp label added source seen legacy info bits kind n=0
    keys_name_ok "$name" || return 1
    kf=$KEYS_DIR/bbs-$name; ud=$KEYS_USERS/$name; mf=$ud/keys.meta
    [[ -f $kf && ! -L $kf && -d $ud && ! -L $ud ]] || return 1
    local -A ml=() ma=() ms=() mseen=() mleg=()
    if [[ -f $mf && ! -L $mf ]]; then
        while IFS=$'\t' read -r fp label added source seen legacy; do
            [[ $fp =~ ^SHA256:[A-Za-z0-9+/]{43}$ && -z ${ml[$fp]+x} ]] || continue
            ml[$fp]=$label ma[$fp]=$added ms[$fp]=$source mseen[$fp]=${seen:--} mleg[$fp]=${legacy:-0}
        done < "$mf"
    fi
    K_LINES=() K_FP=() K_LABEL=() K_ADDED=() K_SOURCE=() K_SEEN=() K_LEGACY=() K_BITS=() K_TYPE=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n ${line//[[:space:]]/} ]] || continue
        if info=$(keys_fp_line "$line"); then
            read -r fp bits kind <<< "$info"
        else
            fp=- bits=0 kind=INVALID
        fi
        K_LINES+=("$line") K_FP+=("$fp") K_BITS+=("$bits") K_TYPE+=("$kind")
        if [[ $fp != - && -n ${ml[$fp]+x} ]]; then
            K_LABEL+=("${ml[$fp]}") K_ADDED+=("${ma[$fp]}") K_SOURCE+=("${ms[$fp]}")
            K_SEEN+=("${mseen[$fp]}") K_LEGACY+=("${mleg[$fp]}")
        else
            if (( n == 0 )); then
                label=registration source=registration
                added=$(sed -n 's/^created=//p' "$ud/profile" 2>/dev/null | head -n 1)
            else
                label=key source=sysop added=
            fi
            [[ $added =~ ^[0-9T:Z-]+$ ]] || added=$(date -u -r "$kf" +%Y-%m-%dT%H:%M:%SZ)
            legacy=0
            [[ $kind == RSA ]] && (( bits < 2048 )) && legacy=1
            [[ $fp == - ]] && label=invalid
            K_LABEL+=("$label") K_ADDED+=("$added") K_SOURCE+=("$source") K_SEEN+=(-) K_LEGACY+=("$legacy")
        fi
        n=$((n + 1))
    done < "$kf"
}

# Meta text for the current K_* arrays.
keys_meta_text() {
    local i
    for i in "${!K_LINES[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${K_FP[$i]}" "${K_LABEL[$i]}" "${K_ADDED[$i]}" \
            "${K_SOURCE[$i]}" "${K_SEEN[$i]}" "${K_LEGACY[$i]}"
    done
}

# keys_history <name>: copy the keyfile to state/keys-history once per run.
keys_history() {
    local name=$1 dest
    [[ -n ${KEYS_HIST_DONE[$name]:-} ]] && return 0
    dest=$KEYS_HIST/$name-$(date -u +%Y%m%dT%H%M%SZ)
    [[ -e $dest ]] && dest=$dest-$$
    install -m 0600 -- "$KEYS_DIR/bbs-$name" "$dest" || return 1
    KEYS_HIST_DONE[$name]=1
}

# keys_write <name> [meta]: write the keyfile (unless "meta") and keys.meta from K_*.
# Atomic: build keys/.bbs-<name>.new, sync, mv -f. Never writes an empty keyfile.
# The caller holds the lock.
keys_write() {
    local name=$1 only=${2:-} kf tmp mf mtmp
    keys_name_ok "$name" || return 1
    (( ${#K_LINES[@]} > 0 )) || return 1
    kf=$KEYS_DIR/bbs-$name; mf=$KEYS_USERS/$name/keys.meta
    if [[ $only != meta ]]; then
        keys_history "$name" || return 1
        tmp=$KEYS_DIR/.bbs-$name.new
        printf '%s\n' "${K_LINES[@]}" > "$tmp" && chmod 0644 "$tmp" && sync -- "$tmp" \
            && mv -f -- "$tmp" "$kf" || { rm -f -- "$tmp"; return 1; }
    fi
    mtmp=$KEYS_USERS/$name/.keys.meta.new
    keys_meta_text > "$mtmp" && chmod 0644 "$mtmp" && mv -f -- "$mtmp" "$mf" \
        || { rm -f -- "$mtmp"; return 1; }
}

# keys_write_meta_if_changed <name>
keys_write_meta_if_changed() {
    local mf=$KEYS_USERS/$1/keys.meta
    [[ -f $mf ]] && [[ $(keys_meta_text) == "$(cat -- "$mf")" ]] && return 0
    keys_write "$1" meta
}

# keys_owner_of <type> <body> -> account name (without bbs-) holding that key, if any.
keys_owner_of() {
    local f
    for f in "$KEYS_DIR"/bbs-*; do
        [[ -f $f && ! -L $f ]] || continue
        if awk -v t="$1" -v b="$2" '$1 == t && $2 == b { found = 1; exit } END { exit !found }' "$f"; then
            printf '%s\n' "${f##*/bbs-}"
            return 0
        fi
    done
    return 1
}
