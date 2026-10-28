#!/bin/bash
# BashBBS news reader: category list, article list and article reader.
# Sourced by menu.sh (needs safe() from there). Nothing here runs on its own.
#
# Design: the reader works on an index (news_index), not on the file system.
# A reading context is an ordered bash array of Article-Ids; news_read takes the
# name of such an array plus a position and knows nothing about categories, so
# "all news", "unread" or "search" can reuse it with a different array.
#
# All text shown to the user passes safe(). Links are shown as text only.

BBS_ROOT=${BBS_ROOT:-/srv/bashbbs}
NEWS_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEWS_PAGE=5

declare -A NEWS_PATH=() NEWS_CAT=() NEWS_TITLE=() NEWS_DATE=() NEWS_SOURCE=() NEWS_LEDE=()
declare -a NEWS_ORDER=() NEWS_CATS=()
NEWS_POS=0        # position of the article last read, set by news_read
KEY=              # last key, set by news_getkey
NEWS_W=76 NEWS_ROWS=24

# ---- Terminal -----------------------------------------------------------------

# Sets NEWS_W (text width) and NEWS_ROWS. Width: stty size on the pty, else
# BBS_COLS, else 80. W = min(cols - 1, 76), at least 30.
news_width() {
    local sz cols=0 rows=0
    if sz=$(stty size 2>/dev/null) && [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        rows=${BASH_REMATCH[1]}
        cols=${BASH_REMATCH[2]}
    fi
    if (( cols == 0 )); then
        cols=80
        [[ ${BBS_COLS:-} =~ ^[0-9]{1,4}$ ]] && cols=$((10#$BBS_COLS))
    fi
    if (( rows == 0 )); then
        rows=24
        [[ ${BBS_ROWS:-} =~ ^[0-9]{1,4}$ ]] && rows=$((10#$BBS_ROWS))
    fi
    NEWS_W=$((cols - 1))
    (( NEWS_W > 76 )) && NEWS_W=76
    (( NEWS_W < 30 )) && NEWS_W=30
    NEWS_ROWS=$rows
    (( NEWS_ROWS < 10 )) && NEWS_ROWS=10
    return 0
}

# The reader needs python3 for wrapping. No fallback wrapper exists.
news_need_python() {
    if ! python3 -c 'import unicodedata' 2>/dev/null; then
        echo "News requires python3. Ask the sysop."
        return 1
    fi
    return 0
}

# Wrap stdin to width $1 (visual columns, UTF-8 aware).
news_wrap() { python3 "$NEWS_LIB/wrap.py" "$1"; }

# Print a rule of dashes, W wide.
news_rule() {
    local s
    printf -v s '%*s' "$NEWS_W" ''
    printf '%s\n' "${s// /-}"
}

# Pack key hints into lines of at most W characters (ASCII only).
news_pack() {
    local line= it
    for it in "$@"; do
        if [[ -z $line ]]; then
            line=$it
        elif (( ${#line} + 2 + ${#it} <= NEWS_W )); then
            line+="  $it"
        else
            printf '%s\n' "$line"
            line=$it
        fi
    done
    [[ -n $line ]] && printf '%s\n' "$line"
    return 0
}

# Read one key into KEY: an upper-case character, SPACE, ENTER, PGUP, PGDN,
# EOF, or empty for anything unknown. Arrow up/down map to K/J.
news_getkey() {
    local c ch seq n=0
    KEY=
    IFS= read -rsn1 c || { KEY=EOF; return 0; }
    case $c in
        '' | $'\r') KEY=ENTER ;;
        ' ') KEY=SPACE ;;
        $'\e')
            IFS= read -rsn1 -t 0.05 ch || return 0
            [[ $ch == '[' || $ch == O ]] || return 0
            seq=$ch
            # Read up to a final byte (a letter or ~), a few characters at most.
            while (( n < 4 )) && IFS= read -rsn1 -t 0.05 ch; do
                seq+=$ch
                n=$((n + 1))
                [[ $ch == [[:alpha:]~] ]] && break
            done
            case $seq in
                '[A' | OA) KEY=K ;;
                '[B' | OB) KEY=J ;;
                '[5~') KEY=PGUP ;;
                '[6~') KEY=PGDN ;;
            esac
            ;;
        [[:print:]]) KEY=${c^^} ;;
    esac
    return 0
}

# ---- Index --------------------------------------------------------------------

# Allowed categories, one per line: $BBS_ROOT/lib copy first, then the copy
# next to this script (used by tests and by an unpacked source tree).
news_categories() {
    local conf line
    for conf in "$BBS_ROOT/lib/news-categories.conf" "$NEWS_LIB/news-categories.conf"; do
        [[ -r $conf && ! -L $conf ]] || continue
        while IFS= read -r line; do
            line=${line%%#*}
            line=${line//[[:space:]]/}
            [[ $line =~ ^[a-z][a-z0-9-]*$ ]] && printf '%s\n' "$line"
        done < "$conf"
        return 0
    done
    return 0
}

# Set NEWS_E to the epoch of a "YYYY-MM-DDTHH:MM:SSZ" string; fail if invalid.
# Pure arithmetic, no forks.
news_iso_epoch() {
    local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$'
    local y m d hh mm ss era yoe doy doe
    [[ $1 =~ $re ]] || return 1
    y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
    hh=$((10#${BASH_REMATCH[4]})); mm=$((10#${BASH_REMATCH[5]})); ss=$((10#${BASH_REMATCH[6]}))
    (( m >= 1 && m <= 12 && d >= 1 && d <= 31 && hh < 24 && mm < 60 && ss <= 60 )) || return 1
    (( y >= 1970 )) || return 1
    (( m <= 2 )) && y=$((y - 1))
    era=$((y / 400))
    yoe=$((y - era * 400))
    doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    NEWS_E=$(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss ))
    return 0
}

# The index is a ready-made file, $BBS_ROOT/state/news-index.tsv: one line per
# article, newest first, tab separated:
#   id  category  epoch  title  path  date  source  lede
# Opening News only READS that file (news_index, news_load_index); it never
# scans boards/news/. A missing file means an empty list, silently. The file is
# (re)built only on explicit repair by news_rebuild_index, which scans
# <root>/boards/news/<cat>/<epoch>-<msgid>.msg for every allowed
# category. Legacy files directly in boards/news/ are not listed. Sort key:
# Published when valid and not in the future, else Date, else the file name's
# epoch. Control characters are stripped from every field.
#
# Fast path for slow machines (Pi Zero W): the whole set of files is read by
# ONE awk process (no per-file fork, no bash read loop). Pipeline:
#   find (regular files only, never symlinks) | sort -> awk (headers, epoch)
#   | sort (epoch desc, then category order, stable) | awk (dedupe by id).
# The date arithmetic is the same as news_iso_epoch, done in awk.
_news_scan() {
    local root=$1 cat now
    local -a cats dirs
    mapfile -t cats < <(news_categories)
    (( ${#cats[@]} )) || return 0
    for cat in "${cats[@]}"; do
        [[ $cat =~ ^[a-z][a-z0-9-]*$ ]] || continue
        [[ -d $root/boards/news/$cat && ! -L $root/boards/news/$cat ]] || continue
        dirs+=("$root/boards/news/$cat")
    done
    (( ${#dirs[@]} )) || return 0
    printf -v now '%(%s)T' -1
    find "${dirs[@]}" -maxdepth 1 -type f -name '*.msg' 2>/dev/null |
        LC_ALL=C sort |
        LC_ALL=C awk -v now="$now" -v cats="${cats[*]}" -v base="$root/boards/news/" '
        function isoepoch(s,    y, m, d, hh, mm, ss, era, yoe, doy, doe) {
            if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return 0
            y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
            hh = substr(s, 12, 2) + 0; mm = substr(s, 15, 2) + 0; ss = substr(s, 18, 2) + 0
            if (!(m >= 1 && m <= 12 && d >= 1 && d <= 31 && hh < 24 && mm < 60 && ss <= 60)) return 0
            if (y < 1970) return 0
            if (m <= 2) y--
            era = int(y / 400); yoe = y - era * 400
            doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            E = (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss
            return 1
        }
        function ymd(t,    z, era, doe, yoe, y, doy, mp, d, m) {
            z = int(t / 86400) + 719468
            era = int(z / 146097); doe = z - era * 146097
            yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
            y = yoe + era * 400
            doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
            mp = int((5 * doy + 2) / 153)
            d = doy - int((153 * mp + 2) / 5) + 1
            m = mp < 10 ? mp + 3 : mp - 9
            if (m <= 2) y++
            return sprintf("%04d-%02d-%02d", y, m, d)
        }
        BEGIN {
            n = split(cats, c, " ")
            for (i = 1; i <= n; i++) rank[c[i]] = i
            FS = "\t"; OFS = "\t"
        }
        {
            f = $0
            if (substr(f, 1, length(base)) != base) next
            rest = substr(f, length(base) + 1)
            p = index(rest, "/")
            if (p < 2) next
            cat = substr(rest, 1, p - 1); fn = substr(rest, p + 1)
            if (!(cat in rank) || index(fn, "/")) next
            if (fn !~ /^[0-9]+-[0-9a-f-]+\.msg$/) next
            e = fn; sub(/-.*/, "", e)
            id = ""; pub = ""; dt = ""; title = ""; src = ""; lede = ""; hcat = ""
            while ((getline line < f) > 0) {
                sub(/\r$/, "", line)
                if (line == "") break
                k = index(line, ":")
                if (k == 0) { key = line; val = "" } else { key = substr(line, 1, k - 1); val = substr(line, k + 1) }
                if (key != "Article-Id" && key != "Category" && key != "Published" && key != "Date" \
                    && key != "Subject" && key != "Source" && key != "Lede") continue
                sub(/^ /, "", val)
                gsub(/[\001-\037\177]/, "", val)
                if (key == "Article-Id") id = val
                else if (key == "Category") hcat = val
                else if (key == "Published") pub = val
                else if (key == "Date") dt = val
                else if (key == "Subject") title = val
                else if (key == "Source") src = val
                else lede = val
            }
            close(f)
            if (id !~ /^[0-9a-f]+$/ || length(id) != 64) {
                if (!(length(id) == 43 && substr(id, 1, 7) == "legacy-" && substr(id, 8) ~ /^[0-9a-f-]+$/)) next
            }
            if (hcat != "" && hcat != cat) next
            date = ""
            if (isoepoch(pub) && E <= now) { e = sprintf("%.0f", E); date = substr(pub, 1, 10) }
            else if (isoepoch(dt)) { e = sprintf("%.0f", E); date = substr(dt, 1, 10) }
            else date = ymd(e + 0)
            if (title == "") title = "(untitled)"
            print rank[cat], id, cat, e, title, f, date, src, lede
        }' |
        LC_ALL=C sort -t $'\t' -s -k4,4nr -k1,1n |
        LC_ALL=C awk -F'\t' -v OFS='\t' '!seen[$2]++ {
            s = $2; for (i = 3; i <= NF; i++) s = s OFS $i; print s }'
}

# Rebuild state/news-index.tsv from the article files (one scan). Explicit
# repair only; never called when a user opens News. Writes a temp file in the
# same directory and renames it into place, so readers never see a partial
# index. Returns non-zero (index untouched) if the scan or the rename fails.
news_rebuild_index() {
    local root=${1:-$BBS_ROOT} dir tmp
    dir=$root/state
    [[ -L $dir ]] && return 1
    mkdir -p -- "$dir" || return 1
    tmp=$dir/.news-index.tsv.$$
    if _news_scan "$root" > "$tmp" && mv -f -- "$tmp" "$dir/news-index.tsv"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

NEWS_NOTICE=""    # set by news_load_index when the index is missing but articles exist
NEWS_MISSING_MSG="News index missing - reported to sysop"

# 0 if at least one article file exists under boards/news/<category>/. One
# find that stops at the first hit; it reads no file.
news_articles_exist() {
    local root=${1:-$BBS_ROOT}
    [[ -n $(find "$root/boards/news" -mindepth 2 -maxdepth 2 -type f -name '*.msg' -print -quit 2>/dev/null) ]]
}

# Report a missing index: a line in state/news-index-missing.log (at most one
# per five minutes) and, when that file cannot be written by this account, the
# system log. The sysop repairs with: bbs-news-index repair.
news_report_missing() {
    local root=${1:-$BBS_ROOT} log
    log=$root/state/news-index-missing.log
    [[ -L $log ]] && return 0
    if [[ -f $log ]] && [[ -z $(find "$log" -mmin +5 2>/dev/null) ]]; then
        return 0
    fi
    printf '%(%Y-%m-%dT%H:%M:%S%z)T news index missing, articles exist; run: bbs-news-index repair\n' -1 \
        >> "$log" 2>/dev/null && return 0
    command -v logger >/dev/null 2>&1 && logger -t bashbbs "news index missing, articles exist; run: bbs-news-index repair"
    return 0
}

# State of the index: 0 readable, 1 missing and no articles (an empty list is
# correct), 2 missing while articles exist (reported, never shown as empty).
# A test of one directory tree, not a scan of the articles.
news_index_state() {
    local root=${1:-$BBS_ROOT} f
    f=$root/state/news-index.tsv
    [[ -f $f && -r $f && ! -L $f ]] && return 0
    news_articles_exist "$root" || return 1
    news_report_missing "$root"
    return 2
}

# Print the index file (tab separated, see above). Missing index: nothing on
# stdout; with articles left it also says so on stderr (and is logged).
news_index() {
    local root=${1:-$BBS_ROOT} st=0
    news_index_state "$root" || st=$?
    case $st in
        0) cat -- "$root/state/news-index.tsv" ;;
        2) echo "$NEWS_MISSING_MSG" >&2; return 2 ;;
    esac
    return 0
}

# A row's path is opened by the reader, so it is checked before use. It must be
# <BBS_ROOT>/boards/news/<allowed category>/<epoch>-<hex-uuid>.msg, the same
# shape the scanner accepts. Anything else (other directory, "..", a relative
# path, a category not in the list) is skipped.
news_path_ok() { # news_path_ok <cat> <path>
    local cat=$1 path=$2 base name
    [[ $cat =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    [[ " ${NEWS_CATS[*]} " == *" $cat "* ]] || return 1
    base=$BBS_ROOT/boards/news/$cat/
    [[ $path == "$base"* ]] || return 1
    name=${path#"$base"}
    [[ $name =~ ^[0-9]+-[0-9a-f-]+\.msg$ ]]
}

# Load the index into the NEWS_* arrays. NEWS_ORDER is newest first.
# Reads the index file in one pass: tr turns the tabs into \037 (a
# non-whitespace IFS keeps empty fields; control characters were stripped from
# every field), then one builtin read per line. No file scan.
news_load_index() {
    local id cat e title path date src lede
    NEWS_PATH=() NEWS_CAT=() NEWS_TITLE=() NEWS_DATE=() NEWS_SOURCE=() NEWS_LEDE=()
    NEWS_ORDER=() NEWS_NOTICE=""
    mapfile -t NEWS_CATS < <(news_categories)
    local st=0
    news_index_state "$BBS_ROOT" || st=$?
    if (( st == 2 )); then
        NEWS_NOTICE=$NEWS_MISSING_MSG
        return 0
    fi
    while IFS=$'\037' read -r id cat e title path date src lede; do
        [[ -n $id ]] || continue
        news_path_ok "$cat" "$path" || continue
        NEWS_CAT[$id]=$cat
        NEWS_TITLE[$id]=$title
        NEWS_PATH[$id]=$path
        NEWS_DATE[$id]=$date
        NEWS_SOURCE[$id]=$src
        NEWS_LEDE[$id]=$lede
        NEWS_ORDER+=("$id")
    done < <(news_index "$BBS_ROOT" | tr '\t' '\037')
    return 0
}

# ---- Section list -------------------------------------------------------------

# Entry point from board_view: the news board with a section marker.
news_board() {
    local i cat id n key
    news_need_python || { pause; return 0; }
    while true; do
        news_width
        news_load_index
        clear
        {
            echo "NEWS"
            news_rule
            echo
            i=1
            for cat in "${NEWS_CATS[@]}"; do
                n=0
                for id in "${NEWS_ORDER[@]}"; do
                    [[ ${NEWS_CAT[$id]} == "$cat" ]] && n=$((n + 1))
                done
                printf '  %d  %-20s %3d\n' "$i" "$cat" "$n"
                i=$((i + 1))
            done
            echo
            if [[ -n $NEWS_NOTICE ]]; then
                echo "$NEWS_NOTICE"
                echo
            fi
            news_rule
            news_pack "[1-$((i - 1))] Open section" "[Q] Back"
        } | safe
        news_getkey
        case $KEY in
            Q | EOF) return 0 ;;
            [1-9])
                (( KEY >= 1 && KEY <= ${#NEWS_CATS[@]} )) || continue
                news_category "${NEWS_CATS[KEY - 1]}"
                ;;
        esac
    done
}

# Build the reading context of one category and show its list.
news_category() {
    local cat=$1 id
    local -a ctx=()
    for id in "${NEWS_ORDER[@]}"; do
        [[ ${NEWS_CAT[$id]} == "$cat" ]] && ctx+=("$id")
    done
    news_list ctx "$cat"
}

# ---- Article list -------------------------------------------------------------

# news_list CTXNAME TITLE: newest first, NEWS_PAGE entries per page.
news_list() {
    local -n _lctx=$1
    local title=$2 cur=0 total=${#_lctx[@]} page pages first last n
    while true; do
        news_width
        total=${#_lctx[@]}
        pages=$(( (total + NEWS_PAGE - 1) / NEWS_PAGE ))
        (( pages > 0 )) || pages=1
        page=$((cur / NEWS_PAGE))
        first=$((page * NEWS_PAGE))
        last=$((first + NEWS_PAGE))
        (( last > total )) && last=$total
        news_draw_list _lctx "$title" "$cur" "$first" "$last" "$((page + 1))" "$pages"
        news_getkey
        case $KEY in
            Q | EOF) return 0 ;;
            N) (( page + 1 < pages )) && cur=$(((page + 1) * NEWS_PAGE)) ;;
            P) (( page > 0 )) && cur=$(((page - 1) * NEWS_PAGE)) ;;
            J) (( cur + 1 < total )) && cur=$((cur + 1)) ;;
            K) (( cur > 0 )) && cur=$((cur - 1)) ;;
            ENTER) (( total > 0 )) && { news_read _lctx "$cur"; cur=$NEWS_POS; } ;;
            [1-9])
                n=$((first + KEY - 1))
                (( n < last )) && { news_read _lctx "$n"; cur=$NEWS_POS; }
                ;;
        esac
    done
}

# First paragraph of an article body, as one line of at most ~300 characters.
news_first_para() {
    local line out= started=0
    while IFS= read -r line; do
        if (( started == 0 )); then
            [[ -n $line ]] || started=1
            continue
        fi
        line=${line%$'\r'}
        if [[ -z $line ]]; then
            [[ -n $out ]] && break
            continue
        fi
        out+=${out:+ }$line
        (( ${#out} > 300 )) && break
    done < "$1"
    printf '%s\n' "${out:0:300}"
}

# Draw one list page. Fields go through safe() in one pass and through the
# wrapper in one pass, so a page costs two forks however many entries it has.
news_draw_list() {
    local -n _dctx=$1
    local title=$2 cur=$3 first=$4 last=$5 pageno=$6 pages=$7
    local i n id meta lede iw=5 tw=$((NEWS_W - 5)) k idx line mark
    local -a raw=() F=() FL=() L=() keys=()
    for ((i = first; i < last; i++)); do
        id=${_dctx[i]}
        meta=${NEWS_DATE[$id]:-}
        [[ -n ${NEWS_SOURCE[$id]:-} ]] && meta="${NEWS_SOURCE[$id]} - $meta"
        lede=${NEWS_LEDE[$id]:-}
        [[ -n $lede || ! -f ${NEWS_PATH[$id]:-} ]] || lede=$(news_first_para "${NEWS_PATH[$id]}")
        raw+=("${NEWS_TITLE[$id]:-}" "$lede" "$meta")
    done
    if (( ${#raw[@]} > 0 )); then
        mapfile -t F < <(printf '%s\n' "${raw[@]}" | safe)
        idx=-1
        while IFS= read -r line; do
            if [[ $line == $'\001' ]]; then
                idx=$((idx + 1)); FL[idx]=; continue
            fi
            [[ -n $line && $idx -ge 0 ]] && FL[idx]+=${FL[idx]:+$'\n'}$line
        done < <(
            for ((k = 0; k < ${#F[@]}; k++)); do
                printf '\001\n\n%s\n\n' "${F[k]}"
            done | news_wrap "$tw"
        )
    fi
    clear
    {
        echo "NEWS / $title"
        news_rule
        echo
        if (( last <= first )); then
            echo "No articles."
            echo
        fi
        for ((i = first; i < last; i++)); do
            k=$(((i - first) * 3))
            mark=' '
            (( i == cur )) && mark='>'
            # Title: number and marker on the first line, hanging indent after.
            mapfile -t L <<< "${FL[k]:-}"
            printf '%s %d  %s\n' "$mark" "$((i - first + 1))" "${L[0]:-}"
            for ((n = 1; n < ${#L[@]}; n++)); do printf '%*s%s\n' "$iw" '' "${L[n]}"; done
            # Lede: two lines at most; the second ends in "..." if cut.
            mapfile -t L <<< "${FL[k + 1]:-}"
            if [[ -n ${L[0]:-} ]]; then
                printf '%*s%s\n' "$iw" '' "${L[0]}"
                if (( ${#L[@]} > 2 )); then
                    news_ellipsis "${L[1]}" "$tw"
                elif (( ${#L[@]} == 2 )); then
                    printf '%*s%s\n' "$iw" '' "${L[1]}"
                fi
            fi
            mapfile -t L <<< "${FL[k + 2]:-}"
            for line in "${L[@]}"; do [[ -n $line ]] && printf '%*s%s\n' "$iw" '' "$line"; done
            echo
        done
        news_rule
        printf 'Page %d of %d\n' "$pageno" "$pages"
        keys=("[1-$((last - first))] Open" "[N] Next page" "[P] Prev page" "[J/K] Move" "[Enter] Open" "[Q] Back")
        (( last > first )) || keys=("[Q] Back")
        news_pack "${keys[@]}"
    } | safe
}

# Print the line with " ..." appended, indented by 5, shortened by whole words
# so it still fits in width $2. LC_ALL=C makes ${#line} count bytes, which is
# never below the visual width, so multi-byte text is cut a little early.
news_ellipsis() {
    local line=$1 w=$2
    local LC_ALL=C
    while (( ${#line} + 4 > w )) && [[ $line == *' '* ]]; do line=${line% *}; done
    printf '     %s ...\n' "$line"
}

# ---- Article reader -----------------------------------------------------------

# Load article $1 into NEWS_HEAD (title and meta lines) and NEWS_BODY (lines).
news_load_article() {
    local id=$1 f=${NEWS_PATH[$1]:-} meta
    local -a F=() out=()
    local line part=0
    NEWS_HEAD=() NEWS_BODY=()
    if [[ -z $f || ! -f $f || -L $f ]]; then
        NEWS_HEAD=("Article not available")
        NEWS_BODY=("This article has been removed.")
        return 0
    fi
    meta=${NEWS_DATE[$id]:-}
    [[ -n ${NEWS_SOURCE[$id]:-} ]] && meta="${NEWS_SOURCE[$id]} - $meta"
    meta="$meta - ${NEWS_CAT[$id]:-}"
    # Title and meta first, then the body without its headers, one safe() pass.
    mapfile -t F < <({
        printf '%s\n%s\n' "${NEWS_TITLE[$id]:-}" "$meta"
        sed '1,/^$/d' "$f" | head -c 16384
    } | safe)
    mapfile -t out < <(
        {
            printf '%s\n\n%s\n\n\001\n\n' "${F[0]:-(untitled)}" "${F[1]:-}"
            (( ${#F[@]} > 2 )) && printf '%s\n' "${F[@]:2}"
        } | news_wrap "$NEWS_W"
    )
    for line in "${out[@]}"; do
        if (( part == 0 )); then
            if [[ $line == $'\001' ]]; then part=1; continue; fi
            [[ -n $line ]] && NEWS_HEAD+=("$line")
        else
            NEWS_BODY+=("$line")
        fi
    done
    # Drop leading and trailing blank lines of the body.
    while (( ${#NEWS_BODY[@]} > 0 )) && [[ -z ${NEWS_BODY[0]} ]]; do NEWS_BODY=("${NEWS_BODY[@]:1}"); done
    while (( ${#NEWS_BODY[@]} > 0 )) && [[ -z ${NEWS_BODY[-1]} ]]; do unset 'NEWS_BODY[-1]'; done
    (( ${#NEWS_BODY[@]} > 0 )) || NEWS_BODY=("(no text)")
    return 0
}

# news_read CTXNAME POSITION: read the articles of a context.
# J/K next and previous article, Space/PgDn scroll and, at the end of an
# article, go on to the next one (on the last article they stay), PgUp scrolls
# back, O shows the link, Q returns. NEWS_POS holds the last position on return.
news_read() {
    local -n _rctx=$1
    local pos=${2:-0} total=${#_rctx[@]} cur=-1 off=0
    local win step maxoff pages page status hl
    local -a keys=()
    NEWS_POS=$pos
    (( total > 0 )) || return 0
    while true; do
        news_width
        if (( pos != cur )); then
            cur=$pos off=0
            NEWS_POS=$pos
            news_load_article "${_rctx[pos]}"
        fi
        keys=("[J] Next" "[K] Prev" "[Space] Read on" "[O] Link" "[Q] Back")
        mapfile -t keys < <(news_pack "${keys[@]}")
        hl=${#NEWS_HEAD[@]}
        win=$((NEWS_ROWS - hl - ${#keys[@]} - 5))
        (( win >= 3 )) || win=3
        step=$((win - 1))
        maxoff=$((${#NEWS_BODY[@]} - win))
        (( maxoff >= 0 )) || maxoff=0
        (( off <= maxoff )) || off=$maxoff
        if (( maxoff == 0 )); then
            pages=1 page=1
        else
            pages=$(( 1 + (maxoff + step - 1) / step ))
            page=$(( off == 0 ? 1 : 1 + (off + step - 1) / step ))
        fi
        status="Article $((pos + 1)) of $total"
        (( pages > 1 )) && status+="  -  Page $page of $pages"
        clear
        {
            printf '%s\n' "${NEWS_HEAD[@]}"
            news_rule
            printf '%s\n' "${NEWS_BODY[@]:off:win}"
            news_rule
            echo "$status"
            printf '%s\n' "${keys[@]}"
        } | safe
        news_getkey
        case $KEY in
            Q | EOF) return 0 ;;
            J) (( pos + 1 < total )) && pos=$((pos + 1)) ;;
            K) (( pos > 0 )) && pos=$((pos - 1)) ;;
            SPACE | PGDN)
                if (( off >= maxoff )); then
                    (( pos + 1 < total )) && pos=$((pos + 1))
                else
                    off=$((off + step)); (( off <= maxoff )) || off=$maxoff
                fi
                ;;
            PGUP) off=$((off - step)); (( off >= 0 )) || off=0 ;;
            O) news_show_link "${_rctx[pos]}" ;;
        esac
    done
}

# Show the article's link as text on its own lines, wrapped hard to W.
# The link is never opened.
news_show_link() {
    local f=${NEWS_PATH[$1]:-} line link=
    if [[ -n $f && -f $f && ! -L $f ]]; then
        while IFS= read -r line; do
            line=${line%$'\r'}
            [[ -n $line ]] || break
            [[ $line == 'Link: '* ]] && { link=${line#Link: }; break; }
        done < "$f"
    fi
    [[ $link =~ ^https?://[^[:space:]]+$ ]] || link=
    clear
    {
        echo "Link"
        news_rule
        echo
        if [[ -n $link ]]; then
            printf '%s\n' "$link" | safe | news_wrap "$NEWS_W"
        else
            echo "This article has no link."
        fi
        echo
        news_rule
        echo "[any key] Back"
    } | safe
    news_getkey
}
