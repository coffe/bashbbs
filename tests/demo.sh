#!/bin/bash
# Interactive demo of the working-tree menu (lib/menu.sh) in a throw-away sandbox.
# Nothing outside the sandbox is touched: no /srv, no Zero, no real mail. The sandbox is
# left in place on exit (no deletes in this project); its path is printed.
# Usage: tests/demo.sh [--plain] [--help]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
color=1
for a in "$@"; do
    case $a in
        --plain) color=0 ;;
        -h|--help)
            cat <<USAGE
Usage: tests/demo.sh [--plain]
Runs lib/menu.sh interactively as bbs-coffe against a fresh sandbox in
\${TMPDIR:-/tmp}/bashbbs-demo.XXXX, filled with sample boards, a thread with a new
reply, news, mail and wall lines. --plain starts with colour off (color=0).
Keys: Enter, B (boards), N/M (mail), W (wall), Q (back), G (log out). The sandbox
path is printed on exit and not deleted.
USAGE
            exit 0 ;;
        *) echo "Unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }

sb=$(mktemp -d "${TMPDIR:-/tmp}/bashbbs-demo.XXXX") || exit 1
root=$sb/root
home=$sb/home
mkdir -p "$root"/{boards/general,boards/retro,boards/news,meta,queue/incoming,state,wall,users,lib} \
         "$home"/Maildir/{tmp,new,cur}
chmod 700 "$home" "$home/Maildir"
now=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00; }

# post <board> <age-seconds> <id> <author> <parent|-> <subject> <body>
post() {
    local t=$((now - $2))
    {
        printf 'Msgid: %s\nAuthor: %s\nNode: demo\nDate: %s\nSubject: %s\n' "$3" "$4" "$(iso "$t")" "$6"
        [[ $5 != - ]] && printf 'Parent: %s\n' "$5"
        printf '\n%s\n' "$7"
    } > "$root/boards/$1/$t-$3.msg"
}
post general 259200 g1 alice - "Welcome to the demo board" "First post. Say hello."
post general 172800 g2 bob   g1 "Re: Welcome to the demo board" "Hello from bob."
post general 90000  g3 carol - "Anyone still using a modem?" "I found my old 14.4k."
post general 600    g4 bob   g3 "Re: Anyone still using a modem?" "Yes! 2400 baud forever. (new reply)"
post retro   400000 r1 alice - "Amiga 500 recap" "Kickstart 1.3 memories."
post retro   300000 r2 dave  - "Best tracker for MOD files?" "ProTracker or OctaMED?"

# News: two categories, one article with a very long title to show wrapping.
news() { # news <cat> <age> <n> <title> <body>
    local t=$((now - $2)) id
    id=$(printf '%s%s' "$1" "$3" | sha256sum | cut -d' ' -f1)
    mkdir -p "$root/boards/news/$1"
    {
        printf 'Board: news\nSubject: %s\nMsgid: 00000000-0000-4000-8000-%012d\nAuthor: news\nNode: demo\n' "$4" "$3"
        printf 'Date: %s\nCategory: %s\nArticle-Id: %s\nSource: Demo Wire\nPublished: %s\n\n%s\n' \
            "$(iso "$t")" "$1" "$id" "$(iso "$t")" "$5"
    } > "$root/boards/news/$1/$t-00000000-0000-4000-8000-$(printf %012d "$3").msg"
}
news ai 3600 1 "A small language model now runs on a phone" "Researchers say it matches larger systems on everyday tasks.

Second paragraph with a little more text."
news ai 7200 2 "An unreasonably long headline that keeps going well past the edge of an eighty column terminal so the wrapping can be inspected" "Short body."
news security 1800 3 "Patch Tuesday fixes a handful of bugs" "Update when you can."
: > "$root/meta/news.sections"
: > "$root/meta/news.readonly"
printf 'owner=alice\n' > "$root/meta/general.meta"

# Mail: two unread (new), one read (cur, flag S).
mail() { # mail <dir> <name> <from> <subject> <body>
    printf 'From: %s@bbs.localdomain\nTo: coffe@bbs.localdomain\nDate: %s\nSubject: %s\n\n%s\n' \
        "$3" "$(date -R)" "$4" "$5" > "$home/Maildir/$1/$2"
}
mail new "$((now - 500)).d1.demo"      bob   "Fresh mail"      "This one is unread."
mail new "$((now - 400)).d2.demo"      carol "Another unread"  "So is this."
mail cur "$((now - 90000)).d3.demo:2,S" alice "Old news"       "Already read."

# Wall greetings (newest 100 are kept by the real publisher; here just two files).
wall() { # wall <age> <id> <author> <text>
    local t=$((now - $1))
    printf 'Msgid: %s\nAuthor: %s\nNode: demo\nDate: %s\n\n%s\n' "$2" "$3" "$(iso "$t")" "$4" > "$root/wall/${t}123456789-$2.msg"
}
wall 7200 w1 alice "Hello from the wall!"
wall 300  w2 bob   "Greetings from 2400 baud."

# Preferences, previous login one hour ago (so the g4 reply and mail show as new),
# and a sendmail stub that only records what would have been sent.
printf 'color=%s\nreplymail=1\n' "$color" > "$home/.bashbbs-prefs"
printf 'login=%s\n' "$((now - 3600))" > "$home/.bashbbs-seen"
printf '#!/bin/bash\ncat >> "%s/sent-mail.txt"\n' "$sb" > "$sb/sendmail-stub"
chmod +x "$sb/sendmail-stub"

# News index (the reader only reads state/news-index.tsv).
BBS_ROOT=$root HOME=$home BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coffe \
    bash -c 'source "$1"; news_rebuild_index "$BBS_ROOT"' bash "$here/lib/menu.sh" >/dev/null 2>&1

# Driver: the start loop of lib/menu.sh, taken from the file itself (as tests/nav_test.sh).
cat > "$sb/drv.sh" <<DRV
#!/bin/bash
export BASHBBS_TEST=1
source "$here/lib/menu.sh"
eval "\$(sed -n '/^if \\[\\[ -z \\\${BASHBBS_TEST/,\$p' "$here/lib/menu.sh" | sed '1d;\$d')"
DRV

echo "Sandbox: $sb (colour=$color). Log out with G."
BBS_ROOT=$root HOME=$home BASHBBS_TEST=1 BASHBBS_TEST_ID=bbs-coffe BBS_SENDMAIL=$sb/sendmail-stub \
    bash "$sb/drv.sh"
rc=$?
echo
echo "Sandbox left in place: $sb"
exit $rc
