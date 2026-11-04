# Shared by bin/bbs-shell (the login side) and sbin/bbs-upload (root sorter).
# Sourced, never run. Needs BBS_ROOT set. Limits come from the environment so
# the tests can shrink them. Every user has the same quota.

UPLOAD_MAX_BYTES=${UPLOAD_MAX_BYTES:-10485760}          # 10 MB per file
UPLOAD_USER_QUOTA=${UPLOAD_USER_QUOTA:-209715200}       # 200 MB per user in published/
UPLOAD_GLOBAL_QUOTA=${UPLOAD_GLOBAL_QUOTA:-2147483648}  # 2 GB for all uploads
UPLOAD_MIN_FREE_KB=${UPLOAD_MIN_FREE_KB:-1048576}       # refuse when less than 1 GB is free

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
