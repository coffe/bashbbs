# Shared by bin/bbs-shell (the login side) and sbin/bbs-upload (root sorter).
# Sourced, never run. Needs BBS_ROOT set. Limits come from the environment so
# the tests can shrink them. Every user has the same quota.

UPLOAD_MAX_BYTES=${UPLOAD_MAX_BYTES:-10485760}          # 10 MB per file
UPLOAD_USER_QUOTA=${UPLOAD_USER_QUOTA:-209715200}       # 200 MB per user in published/
UPLOAD_GLOBAL_QUOTA=${UPLOAD_GLOBAL_QUOTA:-2147483648}  # 2 GB for all uploads
UPLOAD_MIN_FREE_KB=${UPLOAD_MIN_FREE_KB:-1048576}       # refuse when less than 1 GB is free
XFER_TTL_DOWN=${XFER_TTL_DOWN:-900}                     # a download link works for 15 minutes
XFER_TTL_UP=${XFER_TTL_UP:-1800}                        # an upload link works for 30 minutes

# File areas: $BBS_ROOT/etc/file-areas, one "slug|Title|Short text" per line, in menu order
# (see that file). A file's area is an area= line in its .meta; the first area is the
# default, and a file whose area is not listed shows there. The .meta is left as it is, so
# an area that comes back gets its files back.
# fa_load fills FA_SLUGS, FA_TITLES, FA_TEXTS (same order), FA_INDEX (slug to position) and
# FA_DEFAULT. Without a usable file there is one area. Shown to users, so only printable
# characters are kept.
fa_load() {
    local slug title text
    FA_SLUGS=() FA_TITLES=() FA_TEXTS=()
    declare -gA FA_INDEX=()
    while IFS='|' read -r slug title text || [[ -n $slug ]]; do
        slug=${slug//[[:space:]]/}
        [[ $slug =~ ^[a-z0-9][a-z0-9-]{0,19}$ && -z ${FA_INDEX[$slug]:-} ]] || continue
        title=${title#"${title%%[![:space:]]*}"}
        title=${title%"${title##*[![:space:]]}"}
        text=${text#"${text%%[![:space:]]*}"}
        text=${text%"${text##*[![:space:]]}"}
        FA_INDEX[$slug]=${#FA_SLUGS[@]}
        FA_SLUGS+=("$slug")
        FA_TITLES+=("${title:-$slug}")
        FA_TEXTS+=("$text")
    done < <(LC_ALL=C.UTF-8 sed 's/[^[:print:]]//g' "$BBS_ROOT/etc/file-areas" 2>/dev/null)
    if (( ${#FA_SLUGS[@]} == 0 )); then
        FA_INDEX[general]=0
        FA_SLUGS=(general) FA_TITLES=(General) FA_TEXTS=("All files")
    fi
    FA_DEFAULT=${FA_SLUGS[0]}
}

# After fa_load. The text tested can come from a user, so its form is checked first.
fa_known() { [[ $1 =~ ^[a-z0-9-]+$ && -n ${FA_INDEX[$1]:-} ]]; }
fa_pick() { if fa_known "$1"; then printf '%s' "$1"; else printf '%s' "$FA_DEFAULT"; fi; }
fa_title() { printf '%s' "${FA_TITLES[${FA_INDEX[$1]:-0}]}"; }

# ub_used [user]: bytes in published/, summed from the size= lines of the .meta
# files (only one user's files when a user is given). Always prints a number.
ub_used() {
    local pub=$BBS_ROOT/published
    [[ -d $pub ]] || { echo 0; return; }
    # Each .meta starts with its user= line, so plain concatenation is safe.
    find "$pub" -maxdepth 1 -name '*.meta' -type f -exec cat {} + 2>/dev/null \
        | awk -v u="${1:-}" '
            /^user=/ { owner = substr($0, 6) }
            /^size=/ { if (u == "" || owner == u) t += substr($0, 6) }
            END { print t + 0 }'
}

# ub_free_kb: free kilobytes on the filesystem holding BBS_ROOT.
ub_free_kb() {
    df -Pk "$BBS_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# ub_check <user> <size>: prints why an upload of <size> bytes (0 = size not
# known yet) must be refused and returns 1, or returns 0 when it may go ahead.
ub_check() {
    local u=$1 size=${2:-0} free
    free=$(ub_free_kb)
    if [[ -n $free ]] && (( free < UPLOAD_MIN_FREE_KB )); then
        echo "disk nearly full"; return 1
    fi
    if (( $(ub_used "$u") + size > UPLOAD_USER_QUOTA )); then
        echo "user quota exceeded"; return 1
    fi
    if (( $(ub_used) + size > UPLOAD_GLOBAL_QUOTA )); then
        echo "global quota exceeded"; return 1
    fi
    return 0
}
