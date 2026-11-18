# Feature switches. $BBS_ROOT/features (written by root, read once per login) holds one
# name=on|off line per feature; every feature is listed, a new install has all off.
# Only an exact "on" is on: a missing line, a typo or any other value is off. A dotted
# name is on only when the part before the first dot is on too (games.turf needs games), and FEAT_NEEDS
# lists the other features a feature cannot work without. showoff=on shows a switched-off
# menu item greyed with "(off)" instead of hiding it.
declare -gA FEAT=()
declare -gA FEAT_NEEDS=([news.qr]=web [files.xfer.web]=web [apply]=web)

features_load() {
    FEAT=()
    local f=$BBS_ROOT/features k v all=""
    if [[ ! -r $f ]]; then
        # Tests (BASHBBS_TEST) without a features file run with every feature on.
        [[ -n ${BASHBBS_TEST:-} ]] || return 0
        f=$(dirname "${BASH_SOURCE[0]}")/../etc/features.example; all=1
    fi
    while IFS='=' read -r k v || [[ -n $k ]]; do
        k=${k//[[:space:]]/}; v=${v//[[:space:]]/}; [[ -z $all ]] || v=on
        [[ -z $k || $k == \#* ]] || FEAT[$k]=$v
    done < "$f"
}

feature_on() { # feature_on <name>
    local n=$1
    [[ -n ${FEAT_NEEDS[$n]:-} ]] && ! feature_on "${FEAT_NEEDS[$n]}" && return 1
    [[ ${FEAT[$n]:-} == on && ${FEAT[${n%%.*}]:-} == on ]]
}

# feat_item <feature> <menu_item args...>: the menu row when the feature is on, a grey
# "k) Label (off)" row when it is off and showoff=on, else nothing. The key is never
# accepted while the feature is off; the caller leaves it out of its key list.
feat_item() {
    local f=$1; shift
    if feature_on "$f"; then menu_item "$@"
    elif [[ ${FEAT[showoff]:-} == on ]]; then printf '%s) %s (off)\n' "$1" "$2"
    fi
    return 0
}
