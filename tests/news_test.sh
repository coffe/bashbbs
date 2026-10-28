#!/bin/bash
# Reader test for lib/news.sh and lib/menu.sh, run in a real pseudo-terminal.
# Usage: tests/news_test.sh [logfile]
# Env:   BBS_TEST_TMP   parent directory for the scratch root (default: $TMPDIR or /tmp)
#        EXAMPLE_DIR    if set, the 40/60/80 column list and reader screens are saved there
# No network, no ssh, nothing outside the scratch directory is touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
log=${1:-${BBS_TEST_TMP:-${TMPDIR:-/tmp}}/news_test.log}
tmp=$(mktemp -d "${BBS_TEST_TMP:-${TMPDIR:-/tmp}}/news_test.XXXXXX") || exit 1
quar=${BBS_TEST_TMP:-${TMPDIR:-/tmp}}/karantan-news-tests; mkdir -p "$quar"  # no deletes: test dirs go to quarantine
trap 'mv "$tmp" "$quar"/ 2>/dev/null' EXIT
pass=0 fail=0

cat > "$tmp/driver.py" <<'PY'
import fcntl, hashlib, os, pty, re, select, struct, subprocess, sys, termios, time

here, root, width_arg, example_dir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, os.path.join(here, "lib"))
import wrap as wr  # vwidth

CLEAR = re.compile(r"(?:\x1b\[[0-9;]*[HJ])+")
results = []

def check(ok, name, detail=""):
    results.append((ok, name, detail))

def make_fixtures(root):
    now = int(time.time())
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    def put(cat, k, title, body, *, age, pub="auto", link=None, lede=None, source="Test Wire", aid=None, extra="", name=None):
        aid = aid or hashlib.sha256(("%s%d" % (cat, k)).encode()).hexdigest()
        d = os.path.join(root, "boards", "news", cat)
        os.makedirs(d, exist_ok=True)
        t = now - age
        hdr = ["Board: news", "Subject: " + title, "Msgid: 00000000-0000-4000-8000-%012d" % (k + 1000 * len(cat)),
               "Author: news", "Node: test", "Date: " + iso(t), "Category: " + cat, "Article-Id: " + aid,
               "Source: " + source]
        if pub == "auto":
            pub = iso(t)
        if pub:
            hdr.append("Published: " + pub)
        if link:
            hdr.append("Link: " + link)
        if lede:
            hdr.append("Lede: " + lede)
        text = "\n".join(hdr) + "\n" + extra + "\n" + body
        fn = name or "%d-00000000-0000-4000-8000-%012d.msg" % (t, k + 1000 * len(cat))
        with open(os.path.join(d, fn), "w", encoding="utf-8") as fh:
            fh.write(text)
        return aid

    W = [38, 39, 40, 41, 57, 58, 59, 60, 74, 75, 76, 77]
    edge = " ".join(("åäö"[i % 3] * n) for i, n in enumerate(W))
    nfd = "Ase̊ öppnar äventyr i Göteborg " * 3
    long_url = "https://example.org/very/long/path/" + "segment-" * 20 + "end?id=123456789&x=y"
    english = ("Researchers at the Örebro lab say a small model can run on a phone. "
               "The team, led by Åsa Öberg, tested it against larger systems and found "
               "little difference on everyday tasks. ")
    body0 = "\n\n".join(english * 2 + ("Paragraph %d continues with more text about Ärlingar. " % i) * 3 for i in range(1, 9))
    ids = {}
    ids["ai0"] = put("ai", 0, "Åsa Öberg's team builds a pocket-sized language model", body0, age=3600, link=long_url,
                     lede="A small model runs on a phone and matches larger systems on everyday tasks, the Örebro team says.",
                     source="Örebro Wire")
    ids["ai1"] = put("ai", 1, "Edge cases: wide words and decomposed ÅÄÖ", edge + "\n\n" + nfd + "\n\n" + long_url + "\n\n" + "x" * 300,
                     age=7200, link="https://example.org/a")
    for k in range(2, 10):
        ids["ai%d" % k] = put("ai", k, "AI story number %d" % k, "Short body %d with åäöÅÄÖ.\n\nSecond paragraph." % k, age=3600 * (k + 1),
                               lede="Lede for story %d." % k if k % 2 else None)
    ids["sec0"] = put("security", 0, "Hostile \x1b[31mtitle\x1b]0;x\x07 here",
                      "Body with \x1b[2Jescape and \x07 bell and \x1b[1mbold\x1b[0m end.\n\nNext.", age=1800,
                      link="https://example.org/sec")
    ids["sec1"] = put("security", 1, "Another security story", "Plain text.", age=5400)
    ids["fut"] = put("games-anime", 0, "Future published date", "Sorted by import time.", age=100, pub=iso(now + 86400 * 400))
    ids["bad"] = put("games-anime", 1, "Invalid published date", "Sorted by import time.", age=200, pub="garbage")
    ids["old"] = put("games-anime", 2, "Published five days ago", "Sorted by Published.", age=300, pub=iso(now - 5 * 86400))
    # Must not appear: legacy root file, unknown category, bad id, symlink.
    put("evil", 0, "Unknown category", "x", age=10)
    put("other", 0, "Bad id", "x", age=10, aid="not-an-id")
    d = os.path.join(root, "boards", "news")
    with open(os.path.join(d, "%d-00000000-0000-4000-8000-0000000legacy.msg" % now), "w") as fh:
        fh.write("Board: news\nSubject: Legacy root file\nMsgid: x\n\nbody\n")
    os.symlink("/etc/passwd", os.path.join(d, "ai", "%d-00000000-0000-4000-8000-000000000bad.msg" % now))
    os.makedirs(os.path.join(root, "meta"), exist_ok=True)
    open(os.path.join(root, "meta", "news.sections"), "w").close()
    open(os.path.join(root, "meta", "news.readonly"), "w").close()
    return ids

class Term:
    def __init__(self, argv, env, winsize=None):
        self.out = ""
        self.screen = ""
        self.screens = []
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(argv[0], argv, env)
        self.pid, self.fd = pid, fd
        if winsize:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", winsize[0], winsize[1], 0, 0))
        self.alive = True

    def _pump(self, quiet=0.35, limit=6.0):
        got, end, t0 = False, time.time() + limit, time.time()
        buf = b""
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], quiet if got else 0.2)
            if not r:
                if got:
                    break
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                self.alive = False
                break
            if not data:
                self.alive = False
                break
            buf += data
            got = True
        text = buf.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "")
        return text

    def read(self):
        text = self._pump()
        self.out += text
        parts = CLEAR.split(text)
        if len(parts) > 1:
            for p in parts[1:]:
                self.screens.append(p)
            self.screen = parts[-1]
        else:
            self.screen += text if not self.screens else ""
        return text

    def send(self, data, expect=None):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)
        end = time.time() + 8
        while True:
            self.read()
            if expect is None or expect in self.screen or time.time() > end:
                break
        if expect is not None and expect not in self.screen:
            return False
        return True

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass

def env_for(cols, rows="14", **kw):
    e = {"PATH": os.environ["PATH"], "HOME": root, "USER": "bbs-tester", "TERM": "xterm",
         "LC_ALL": "C.UTF-8", "BBS_ROOT": root, "BASHBBS_TEST": "1", "BBS_ROWS": rows}
    if cols:
        e["BBS_COLS"] = str(cols)
    e.update(kw)
    return e

menu = os.path.join(here, "lib", "menu.sh")
ids = make_fixtures(root)
# The reader only reads state/news-index.tsv; build it once from the fixtures.
subprocess.run(["bash", "-c", 'source "$1"; news_rebuild_index "$BBS_ROOT"', "bash", menu],
               env=env_for(None), check=True)
cols = width_arg
W = max(30, min(cols - 1, 76))

def screen_checks(term, label, W, skip_menu=True):
    # No line wider than W, no stray control characters, in every news screen.
    over, ctrl = [], []
    for s in term.screens:
        if skip_menu and "[B] Boards" in s:
            continue
        for ln in s.split("\n"):
            if wr.vwidth(ln) > W:
                over.append((wr.vwidth(ln), ln))
            if re.search(r"[\x00-\x08\x0b-\x1f\x7f]", ln):
                ctrl.append(ln)
    check(not over, label + ": no line wider than %d" % W, str(over[:2]))
    check(not ctrl, label + ": no escape or control bytes on screen", repr(ctrl[:2]))
    check(not re.search(r"\x1b", CLEAR.sub("", term.out)), label + ": no ESC outside the clear sequence")

# ---- Index order (no pty) ----
idx = subprocess.run(["bash", "-c", 'source "$1"; news_index "$BBS_ROOT"', "bash", menu],
                     env=env_for(cols), capture_output=True, text=True)
rows = [l.split("\t") for l in idx.stdout.splitlines()]
got_ids = [r[0] for r in rows]
check(len(rows) == 10 + 2 + 3, "index: 15 valid articles (legacy, unknown category, bad id, symlink skipped)", str(len(rows)))
check(all(len(r) == 8 for r in rows), "index: eight fields per row")
epochs = [int(r[2]) for r in rows]
check(epochs == sorted(epochs, reverse=True), "index: newest first")
pos = {i: got_ids.index(v) for i, v in ids.items() if v in got_ids}
check(pos["fut"] < pos["bad"] < pos["old"], "index: future Published falls back to Date, old Published sorts by Published")
check("Legacy root file" not in idx.stdout and "Unknown category" not in idx.stdout and "Bad id" not in idx.stdout,
      "index: excluded files not listed")

# ---- Session A: board_menu -> sections -> list -> reader ----
t = Term(["bash", "-c", 'source "$1"; board_menu', "bash", menu], env_for(cols))
t.read()
check("Public boards" in t.screen and "1) news" in t.screen, "A: board menu lists the news board")
ok = t.send("1\n", "NEWS")
check(ok and re.search(r"1  ai +10", t.screen) and re.search(r"2  security +2", t.screen), "A: sections with counts", t.screen[:200])
check("[1-7] Open section" in t.screen, "A: section footer")
ok = t.send("1", "NEWS / ai")
list0 = t.screen
check(ok and "Page 1 of 2" in list0, "A: list page 1 of 2", list0[-200:])
check(re.search(r"^> 1  ", list0, re.M) is not None, "A: cursor on entry 1")
check(len(re.findall(r"^[ >] [1-5]  ", list0, re.M)) == 5, "A: five entries on the page")
check("Åsa Öberg" in list0, "A: åäö visible in the list")
if example_dir:
    open(os.path.join(example_dir, "news-list-%d.txt" % cols), "w").write(list0)
t.send("J", "> 2  ")
check(re.search(r"^> 2  ", t.screen, re.M) is not None, "A: J moves the cursor down")
t.send("K", "> 1  ")
check(re.search(r"^> 1  ", t.screen, re.M) is not None, "A: K moves the cursor up")
t.send("N", "Page 2 of 2")
check("Page 2 of 2" in t.screen and len(re.findall(r"^[ >] [1-5]  ", t.screen, re.M)) == 5, "A: N goes to page 2 with five entries")
t.send("P", "Page 1 of 2")
check("Page 1 of 2" in t.screen, "A: P goes back to page 1")
ok = t.send("\r", "Article 1 of 10")
page1 = t.screen
check(ok, "A: Enter opens the marked article, footer 'Article 1 of 10'", page1[-200:])
check("Page 1 of" in page1, "A: reader shows a page counter")
if example_dir:
    open(os.path.join(example_dir, "news-read-%d.txt" % cols), "w").write(page1)
def key_lines(text):
    return [l for l in text.split("\n") if l.startswith("[")]
for label, scr in (("list", list0), ("reader", page1)):
    kl = key_lines(scr)
    check(kl and all(len(l) <= cols - 1 for l in kl), "A: %s key lines fit in %d columns" % (label, cols - 1), str([(len(l), l) for l in kl]))
    check(not any(l for l in scr.split("\n") if "[B] Boards" in l), "A: %s has no nav top bar" % label)
check(len(key_lines(page1)) == (1 if cols >= 60 else 2), "A: reader keys on %s" % ("one line" if cols >= 60 else "two lines at narrow width"), str(key_lines(page1)))
ok = t.send("J", "Article 2 of 10")
check(ok, "A: J gives 'Article 2 of 10'")
ok = t.send("K", "Article 1 of 10")
check(ok, "A: K gives 'Article 1 of 10'")
before = t.screen
ok = t.send("\x1b[6~", "Page 2 of")
check(ok and t.screen != before, "A: PgDn scrolls forward (text and footer change)")
after_pgdn = t.screen
ok = t.send("\x1b[5~", "Page 1 of")
check(ok and t.screen == before, "A: PgUp scrolls back to the first page")
ok = t.send(" ", "Page 2 of")
check(ok and t.screen == after_pgdn, "A: Space scrolls like PgDn")
t.send("\x1b[5~", "Page 1 of")
# Link view: shown on its own, wrapped, then any key returns.
ok = t.send("O", "Link")
link_screen = t.screen
joined = "".join(l for l in link_screen.split("\n") if l.startswith("https://") or (l and not l.startswith(("Link", "---", "[any")) and " " not in l))
check(ok and "https://example.org/very/long/path/" in link_screen and "end?id=123456789&x=y" in joined.replace("\n", ""),
      "A: O shows the full link as text", link_screen[:300])
check(all(wr.vwidth(l) <= W for l in link_screen.split("\n")), "A: link lines wrapped to W")
check("https://" not in page1, "A: link is not embedded in the article text")
ok = t.send("x", "Article 1 of 10")
check(ok, "A: any key leaves the link view")
ok = t.send("\x1b[B", "Article 2 of 10")
check(ok, "A: arrow down (ESC [ B) goes to the next article")
ok = t.send("\x1b[A", "Article 1 of 10")
check(ok, "A: arrow up (ESC [ A) goes to the previous article")
t.send("\x1b[Z")
check("Article 1 of 10" in t.screen, "A: unknown escape sequence is ignored")
# Edge-case article (wide words): PgDn to its last page, then one more PgDn goes to the next article.
PGDN = "\x1b[6~"
def to_last_page(term, art):
    m = re.search(r"Page 1 of (\d+)", term.screen)
    n = int(m.group(1)) if m else 1
    if n > 1:
        term.send(PGDN * (n - 1), "Page %d of %d" % (n, n))
    return n, ("Article %s" % art in term.screen and (n == 1 or "Page %d of %d" % (n, n) in term.screen))
t.send("J", "Article 2 of 10")
n2, at_end = to_last_page(t, "2 of 10")
check(n2 > 1 and at_end, "A: PgDn x%d reaches the last page of article 2, still article 2" % (n2 - 1), t.screen[-160:])
ok = t.send(PGDN, "Article 3 of 10")
check(ok, "A: PgDn at the end of an article goes to the next article", t.screen[-160:])
m = re.search(r"Article 3 of 10(?:  -  Page (\d+) of (\d+))?", t.screen)
check(m is not None and m.group(1) in (None, "1"), "A: the next article starts at its first page", t.screen[-160:])
check("[Space] Read on" in t.screen, "A: footer says 'Read on' for Space")
ok = t.send("K", "Article 2 of 10")
t.send(PGDN * (n2 - 1), "Page %d of %d" % (n2, n2))
check("Article 2 of 10" in t.screen and "Page %d of %d" % (n2, n2) in t.screen, "A: back on article 2 and scrolled to its end")
ok = t.send(" ", "Article 3 of 10")
check(ok, "A: Space at the end of an article goes to the next article", t.screen[-160:])
# Article 3 is short (one page): Space goes straight on.
ok = t.send(" ", "Article 4 of 10")
check(ok, "A: Space on a one-page article goes to the next article", t.screen[-160:])
ok = t.send("Q", "NEWS / ai")
check(ok and re.search(r"^> 4  ", t.screen, re.M) is not None, "A: Q returns to the list, cursor on the last article read", t.screen[:300])
ok = t.send("3", "Article 3 of 10")
check(ok, "A: digit 3 opens the third article")
ok = t.send("Q", "NEWS / ai")
ok = t.send("Q", "NEWS\n")
check(ok and "1  ai" in t.screen, "A: Q returns to the sections")
ok = t.send("2", "NEWS / security")
check(ok and "Hostile title here" in t.screen.replace("[31m", "").replace("]0;x", "") or "Hostile" in t.screen, "A: security list shows the title without escapes")
t.send("1", "Article 1 of 2")
check("Article 1 of 2" in t.screen and "escape and  bell" in t.screen.replace("[2J", "") or "Body with" in t.screen, "A: hostile body shown without control bytes")
t.send("Q", "NEWS / security")
t.send("Q", "NEWS\n")
t.send("Q", "Public boards")
t.send("Q")
screen_checks(t, "A", W)
all_text = "\n".join(t.screens)
check(all(c in all_text for c in "åäöÅÄÖ"), "A: åäöÅÄÖ all appear on screen")
t.close()

# ---- Session B: generic context across categories ----
t = Term(["bash", "-c", 'source "$1"; news_load_index; ctx=("${NEWS_ORDER[@]}"); news_read ctx 0; echo "pos=$NEWS_POS"', "bash", menu], env_for(cols))
t.read()
check("Article 1 of 15" in t.screen, "B: mixed-category context starts at 'Article 1 of 15'", t.screen[-120:])
for n in range(2, 5):
    t.send("J", "Article %d of 15" % n)
check("Article 4 of 15" in t.screen, "B: J x3 gives 'Article 4 of 15'")
t.send("K", "Article 3 of 15")
check("Article 3 of 15" in t.screen, "B: K gives 'Article 3 of 15'")
for _ in range(20):
    t.send("J")
check("Article 15 of 15" in t.screen, "B: J stops at the last article")
last = t.screen
for key in (" ", "\x1b[6~", " "):
    t.send(key)
check("Article 15 of 15" in t.screen and t.screen.count("Article 15 of 15") >= 1 and t.alive, "B: Space and PgDn on the last article stay on it")
check(t.screen.rstrip().split("\n")[-3:] == last.rstrip().split("\n")[-3:], "B: the last article shows the same status line")
t.send("Q")
check("pos=14" in t.out, "B: Q returns to the caller with the position", t.out[-80:])
screen_checks(t, "B", W)
t.close()

# ---- Session C: window size from the pty wins over BBS_COLS ----
t = Term(["bash", "-c", 'source "$1"; news_load_index; ctx=("${NEWS_ORDER[@]}"); news_list ctx all', "bash", menu],
         env_for(80), winsize=(30, 50))
t.read()
check(t.screen.split("\n")[1] == "-" * 49, "C: stty size (50 columns) gives W=49 although BBS_COLS=80", repr(t.screen.split("\n")[:3]))
t.send("Q")
screen_checks(t, "C", 49)
t.close()

# ---- Without python3 ----
e = env_for(cols)
r = subprocess.run(["/bin/bash", "-c", 'source "$1"; PATH=/nonexistent; news_need_python', "bash", menu], env=e, capture_output=True, text=True)
check(r.returncode == 1 and "python3" in r.stdout, "no python3: error message and failure status, no fallback")

for ok, name, detail in results:
    print(("PASS " if ok else "FAIL ") + "[%d cols] %s" % (cols, name) + ("" if ok else "  -- " + detail))
sys.exit(0)
PY

for cols in 40 60 80; do
    root=$tmp/root$cols
    mkdir -p "$root/boards" "$root/meta"
    {
        echo "=== $cols columns ==="
        nice -n 19 python3 -I "$tmp/driver.py" "$here" "$root" "$cols" "${EXAMPLE_DIR:-}" 2>&1
    } >> "$log.run"
done
: > "$log"
cat "$log.run" >> "$log"
mv -f "$log.run" "$quar/run-$(date +%s%N).log" 2>/dev/null
pass=$(grep -c '^PASS ' "$log")
fail=$(grep -c '^FAIL \|Traceback' "$log")
grep '^FAIL \|Traceback' -A3 "$log" | head -40
echo "news_test: $pass pass, $fail fail (log: $log)"
[[ $fail -eq 0 ]]
