#!/bin/bash
# BashBBS 1.4 navigation: single keys, jump keys, help, the input buffer, text
# input, UTF-8, destructive questions. Everything runs in a real pty whose size is set
# (TIOCSWINSZ) to 40, 60 and 80 columns, against a temporary BBS_ROOT. The driver sends
# keys when the prompt text has appeared (expect style); the only delays are the ones a
# test sends on purpose (delayed delivery, split escape sequence) and none hides a race.
# Nothing outside the temp root is read or written: no Maildir, no Zero.
# Usage: tests/nav_test.sh [logfile]   (full log in the file; the screen shows only
# failures and the summary)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-/tmp/claude-1000/-home-coffe-ai/b81958b1-d888-4669-a367-89842baf6a52/scratchpad}
[[ -d $scratch ]] || scratch=${TMPDIR:-/tmp}
log=${1:-$scratch/nav_test.log}
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }
work=$(mktemp -d "$scratch/nav.XXXXXX")
py=$work/nav_driver.py

cat > "$py" <<'PYEOF'
import codecs, fcntl, os, pty, re, select, shutil, struct, subprocess, sys, termios, time, unicodedata

HERE, WORK, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
WIDTHS = [int(x) for x in sys.argv[4].split(",")]
ONLY = sys.argv[5] if len(sys.argv) > 5 else ""
HOST = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
DRV = os.path.join(WORK, "drv.sh")
open(DRV, "w").write('''#!/bin/bash
# The start loop of lib/menu.sh, taken from the file itself (no copy that can drift).
export BASHBBS_TEST=1
source "%s/lib/menu.sh"
eval "$(sed -n '/^if \\[\\[ -z \\${BASHBBS_TEST/,$p' "%s/lib/menu.sh" | sed '1d;$d')"
''' % (HERE, HERE))

ANSI = re.compile(r"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|[()][A-Z0-9]|O[@-~])")
CLR = re.compile(r"\x1b\[H\x1b\[2J(?:\x1b\[3J)?")
PROMPT = r"\r\n> $"
PAUSE = r"\[Any key\] $"
MAIN = r"== BashBBS ==.*Q\) Log out\r\n> $"
ESC = b"\x1b"
ARROWS = b"\x1b[A\x1b[B\x1bOA"

results = []      # (width, name, ok, detail)
logf = open(LOG, "w")
CUR = [0]


def chk(name, ok, detail=""):
    results.append((CUR[0], name, bool(ok), detail))
    if ok:
        logf.write("ok   [%d] %s\n" % (CUR[0], name))
    else:
        line = "FAIL [%d] %s%s" % (CUR[0], name, (" :: " + detail[:300].replace("\n", "|")) if detail else "")
        logf.write(line + "\n")
        print(line)
    logf.flush()


class Timeout(Exception):
    pass


def cellw(s):
    n = 0
    for c in s:
        if unicodedata.combining(c):
            continue
        n += 2 if unicodedata.east_asian_width(c) in "WF" else 1
    return n


def lines_of(scr):
    return ANSI.sub("", scr).replace("\r", "").split("\n")


def last_screen(t):
    return CLR.split(t)[-1]


class Sess:
    def __init__(self, cols, root, home, rows=24, lc="C.UTF-8"):
        self.cols, self.screens, self.raw = cols, [], b""
        self.pending = ""
        self.dec = codecs.getincrementaldecoder("utf-8")("replace")
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            env = {"PATH": os.environ["PATH"], "BBS_ROOT": root, "HOME": home, "USER": "bbs-alice",
                   "BASHBBS_TEST_ID": "bbs-alice", "BBS_SENDMAIL": root + "/t/sendmail",
                   "TERM": "xterm", "LC_ALL": lc}
            os.execvpe("bash", ["bash", DRV], env)
        self.pid, self.fd, self.eof = pid, fd, False

    def _pump(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return
        try:
            d = os.read(self.fd, 65536)
        except OSError:
            d = b""
        if not d:
            self.eof = True
            return
        self.raw += d
        self.pending += self.dec.decode(d)

    def send(self, b):
        os.write(self.fd, b if isinstance(b, bytes) else b.encode())

    def expect(self, pat, timeout=10):
        rx = re.compile(pat, re.S)
        end = time.time() + timeout
        while True:
            m = rx.search(self.pending)
            if m:
                t = self.pending[:m.end()]
                self.pending = self.pending[m.end():]
                self.screens.append(last_screen(t))
                return t
            if self.eof or time.time() > end:
                raise Timeout("waiting for %r; got tail %r" % (pat, self.pending[-160:]))
            self._pump(0.05)

    def k(self, keys, pat):
        self.send(keys)
        return self.expect(pat)

    def start(self):
        return self.expect(r"== Welcome, alice ==.*?" + PROMPT)

    def main(self):
        self.start()
        return self.k("x", MAIN)

    def wait_exit(self, timeout=10):
        end = time.time() + timeout
        while not self.eof and time.time() < end:
            self._pump(0.05)
        return self.eof

    def close(self):
        try:
            os.kill(self.pid, 9)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def rows_ok(self):
        """No screen has a line wider than the terminal; returns offending lines."""
        bad = []
        for sc in self.screens:
            for l in lines_of(sc):
                if cellw(l) > self.cols:
                    bad.append(l)
        return bad


def title_pat(title, extra=""):
    return r"== %s ==.*?%s.*?%s" % (re.escape(title), extra, PROMPT)


GEN = lambda: r"== general ==.*N\) New post.*" + PROMPT      # thread list
POST = lambda: r"== general ==.*Reply.*" + PROMPT           # open post (R) Reply)
BOARDS = r"== Public boards ==.*K\) New private board.*" + PROMPT
MAILM = r"== Private messages ==.*" + PROMPT
WALL = r"== Wall ==.*\[Space\] Next.*" + PROMPT
USERS = r"== Users ==.*" + PAUSE
ACCT = r"== My account ==.*" + PAUSE
CONF = r"Log out\? \[y/N\] $"


def layout(name, scr, kind, w):
    L = lines_of(scr)
    idx = next((i for i, l in enumerate(L) if re.fullmatch(r"== .+ ==", l)), None)
    if idx is None:
        chk("1 layout %s: has == Title ==" % name, False, repr(scr[:200]))
        return
    if kind == "jump":
        bar = idx in (2, 3) and L[0].startswith("[B] Boards") and L[idx - 1] == "" \
            and "[G] Goodbye" in " ".join(L[:idx - 1]) and "[?] Help" in " ".join(L[:idx - 1])
    else:
        bar = idx == 2 and L[0].startswith("[?] Help") and L[1] == ""
    after = idx + 2 < len(L) and L[idx + 1] == "" and L[idx + 2] != ""
    wide = [l for l in L if cellw(l) > w]
    chk("1 layout %s: top bar, title, one blank line" % name, bar and after,
        "idx=%s L=%r" % (idx, L[:idx + 3]))
    chk("1 layout %s: no row wider than %d" % (name, w), not wide, repr(wide[:2]))


# ---------------------------------------------------------------- fixtures
def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w", encoding="utf-8").write(text)


def post(root, board, n, mid, author, subject, body):
    put("%s/boards/%s/%d-%s.msg" % (root, board, 1500000000 + n, mid),
        "Board: %s\nMsgid: %s\nSubject: %s\nAuthor: %s\nDate: 2026-10-0%dT10:00:00Z\n\n%s\n"
        % (board, mid, subject, author, n, body))


LONGSUB = "日本語のタイトル with ÅÄÖ and a very long title that must wrap on narrow terminals nicely"


def mkmail(home):
    shutil.rmtree(home + "/Maildir", ignore_errors=True)
    def msg(folder, sub, name, subj, mid):
        put("%s/Maildir%s/%s/%s" % (home, folder, sub, name),
            "From: bob@%s\nTo: alice@%s\nSubject: %s\nDate: Thu, 01 Oct 2026 10:00:00 +0000\n"
            "Message-ID: <%s@%s>\n\nHej alice\nandra raden åäö 日本\n" % (HOST, HOST, subj, mid, HOST))
    msg("", "new", "1.n1.h", "Ny post åäö 日本語 and a rather long subject to cut at forty", "i1")
    msg("", "cur", "2.c2.h:2,S", "Läst brev", "i2")
    msg("/.Sent", "cur", "3.s3.h:2,S", "Skickat åäö", "s3")
    msg("/.Trash", "cur", "4.t4.h:2,S", "Raderat", "t4")


def mkroot(tag, w, boards=None):
    root = "%s/r-%s-%d" % (WORK, tag, w)
    home = root + "/home/bbs-alice"
    shutil.rmtree(root, ignore_errors=True)
    for d in ("queue/incoming", "meta", "wall", "t", "state"):
        os.makedirs(root + "/" + d)
    for u in ("alice", "bob", "carol"):
        put("%s/users/%s/profile" % (root, u), "name=%s\nuuid=11111111-2222-3333-4444-5555666677%02d\n" % (u, ord(u[0])))
    put(root + "/users/bob/profile", "name=Böb 日本\nuuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n")
    put(root + "/sysops", "carol\n")
    put(root + "/t/sendmail",
        "#!/bin/bash\nd=$(dirname \"$0\")/delivered\nmkdir -p \"$d\"\nprintf '%s\\n' \"$*\" >> \"$d/args\"\ncat > \"$(mktemp \"$d/msg.XXXXXX\")\"\n")
    os.chmod(root + "/t/sendmail", 0o755)
    if boards:
        for b in boards:
            os.makedirs("%s/boards/%s" % (root, b))
    else:
        post(root, "general", 1, "m1", "alice", "Välkommen till brädet åäö", "Hej alla\n\nandra stycket")
        post(root, "general", 2, "m2", "bob", LONGSUB, "Text 日本語\nrad två åäö")
        post(root, "general", 3, "m3", "bob", "Short", "kort")
        post(root, "hobby", 4, "m4", "bob", "Hobbypost", "x")
        os.makedirs(root + "/boards/priv")
        put(root + "/meta/priv.meta", "owner=alice\n")
        for i in range(12):
            put("%s/wall/%d%09d-w%d.msg" % (root, 1500000000 + i, i, i),
                "Author: bob\nDate: 2026-10-01T10:%02d:00Z\n\nHälsning %d åäö 日本語 lite längre text för att brytas" % (i, i))
    mkmail(home)
    return root, home


def files(root, pat):
    import glob
    return sorted(glob.glob(root + "/queue/incoming/" + pat))


def rd(path):
    return open(path, encoding="utf-8").read()


def delivered(root):
    import glob
    return sorted(glob.glob(root + "/t/delivered/msg.*"))


def inbox_names(home, sub):
    import glob
    return sorted(os.path.basename(p) for p in glob.glob("%s/Maildir%s/*/*" % (home, sub)) if os.path.isfile(p))


def sess(w, tag="std", boards=None):
    root, home = mkroot(tag, w, boards)
    return Sess(w, root, home), root, home


SCEN = []


def scenario(f):
    SCEN.append(f)
    return f


def inert(s, stray, probe, probe_pat, name, forbid=("Log out?",)):
    """Stray keys do nothing: only the probe's redraw follows, nothing in between."""
    t = s.k(stray + probe, probe_pat)
    pre = CLR.split(t)
    echo = set((stray + probe).decode("latin-1")) | set(" \r\n^\x1b[]OAB")      # the tty echoes what was typed
    left = "".join(c for c in ANSI.sub("", pre[0]) if c not in echo)
    chk(name + ": nothing redrawn or asked", len(pre) == 2 and not any(f in t for f in forbid) and left == "",
        repr(t[:200]))
    return t


# ---------------------------------------------------------------- 1. layout
@scenario
def s_layout(w):
    s, root, home = sess(w)
    try:
        layout("welcome", last_screen(s.start()), "jump", w)
        layout("main", last_screen(s.k("x", MAIN)), "jump", w)
        layout("boards", last_screen(s.k("1", BOARDS)), "jump", w)
        layout("thread list (board view)", last_screen(s.k("1", GEN())), "jump", w)
        layout("post view", last_screen(s.k("1", POST())), "local", w)
        s.k("q", GEN()); s.k("q", BOARDS)
        layout("thread list, private board with members key", last_screen(s.k("3", title_pat("priv", r"S\) Members"))), "jump", w)
        layout("members", last_screen(s.k("s", title_pat("Members", r"A\) Add"))), "local", w)
        s.k("q", title_pat("priv")); s.k("q", BOARDS); s.k("q", MAIN)
        layout("mail menu", last_screen(s.k("5", MAILM)), "jump", w)
        layout("inbox", last_screen(s.k("1", title_pat("Inbox", r"Number: open"))), "local", w)
        layout("mail_view (open message)", last_screen(s.k("1", title_pat("Inbox", r"R\) Reply"))), "local", w)
        s.k("q", title_pat("Inbox", r"Number: open")); s.k("q", MAILM)
        layout("sent", last_screen(s.k("3", title_pat("Sent", r"Number: open"))), "local", w)
        s.k("q", MAILM)
        layout("trash", last_screen(s.k("4", title_pat("Trash", r"Number: open"))), "local", w)
        s.k("q", MAILM); s.k("q", MAIN)
        layout("users", last_screen(s.k("3", USERS)), "local", w)
        s.k("x", MAIN)
        layout("my account", last_screen(s.k("4", ACCT)), "local", w)
        s.k("x", MAIN)
        layout("wall", last_screen(s.k("2", WALL)), "jump", w)
        bad = s.rows_ok()
        chk("1 layout: no row wider than %d on any screen of the walk" % w, not bad, repr(bad[:2]))
    finally:
        s.close()


# ---------------------------------------------------------------- 2. single key
@scenario
def s_single(w):
    s, root, home = sess(w)
    try:
        s.main()
        for key, pat, nm in (("1", BOARDS, "1 Boards"), ("2", WALL, "2 Wall"), ("3", USERS, "3 Users"),
                             ("4", ACCT, "4 My account"), ("5", MAILM, "5 Private messages")):
            s.send(key)
            t = s.expect(pat)
            chk("2 single key: %s acts without Enter" % nm, True)
            if key in "12":
                s.k("q", MAIN)
            elif key == "5":
                s.k("q", MAIN)
            else:
                s.k("x", MAIN)
        # case: letters
        for key, pat, nm in (("b", BOARDS, "B"), ("m", MAIN, "M"), ("p", MAILM, "P"), ("w", WALL, "W")):
            for kk in (key, key.upper()):
                t = s.k(kk, pat)
                chk("2 case: main menu jump %s acts the same" % kk, True)
                s.k("m", MAIN)
        for kk in ("q", "Q", "g", "G"):
            s.send(kk)
            s.expect(CONF)
            s.k("n", MAIN)
            chk("2 case: main menu %s asks Log out?" % kk, True)
        # Enter alone / unknown keys
        inert(s, b"\n\r\n", b"4", ACCT, "2 main menu: Enter alone")
        s.k("x", MAIN)
        inert(s, b"x z ! 9 0 6 7 8 /", b"4", ACCT, "2 main menu: unknown keys")
        s.k("x", MAIN)
        s.k("1", BOARDS)
        inert(s, b"\n\nx!", b"1", GEN(), "2 boards list: Enter and unknown key")
        inert(s, b"\nx", b"1", POST(), "2 thread list: Enter and unknown key")
        inert(s, b"\nx", b"q", GEN(), "2 open post: Enter and unknown key")
        s.k("q", BOARDS); s.k("q", MAIN)
        s.k("5", MAILM)
        inert(s, b"\nx", b"1", title_pat("Inbox", r"Number: open"), "2 mail menu: Enter and unknown key")
        inert(s, b"\nx", b"1", title_pat("Inbox", r"R\) Reply"), "2 inbox: Enter and unknown key")
        inert(s, b"\nx", b"q", title_pat("Inbox", r"Number: open"), "2 message: Enter and unknown key")
        s.k("q", MAILM); s.k("q", MAIN)
        s.k("2", WALL)
        inert(s, b"\n\nx", b"q", MAIN, "2 wall: Enter and unknown key")
    finally:
        s.close()


# ---------------------------------------------------------------- 3. logout
@scenario
def s_logout(w):
    s, root, home = sess(w)
    try:
        s.main()
        for kk in ("q", "g"):
            for ans, nm in ((b"n", "n"), (b"\n", "Enter"), (ESC, "Esc"), (b"\x1b[A", "arrow"), (b"x", "other key"), (b" ", "space")):
                s.k(kk, CONF)
                if ans == ESC:
                    # a lone ESC: the key reader waits 0.2 s for a continuation, then it is "no"
                    s.send(ans)
                    t = s.expect(MAIN)
                else:
                    t = s.k(ans, MAIN)
                chk("3 main %s then %s: stays (no logout)" % (kk, nm), "Bye." not in t)
        # after all that, the input is clean: a probe still works
        inert(s, b"", b"4", ACCT, "3 main: nothing left over from the cancelled questions")
        s.k("x", MAIN)
        s.k("q", CONF)
        s.send("y")
        t = s.expect(r"Bye\.")
        chk("3 main Q then y: goodbye art", "bye bye" in t)
        chk("3 main Q then y: the session ends", s.wait_exit())
    finally:
        s.close()
    s, root, home = sess(w)
    try:
        s.main()
        s.k("G", CONF); s.send("Y"); s.expect(r"Bye\.")
        chk("3 main G then Y: logs out and exits", s.wait_exit())
    finally:
        s.close()
    # submenus: Q = back one level
    s, root, home = sess(w)
    try:
        s.main()
        s.k("1", BOARDS); t = s.k("q", MAIN)
        chk("3 boards list: Q is back to main", True)
        s.k("1", BOARDS); s.k("1", GEN()); s.k("q", BOARDS); s.k("q", MAIN)
        chk("3 thread list: Q is back to boards list", True)
        s.k("5", MAILM); s.k("q", MAIN)
        chk("3 mail menu: Q is back to main", True)
        s.k("2", WALL); s.k("q", MAIN)
        chk("3 wall: Q is back to main", True)
    finally:
        s.close()
    # G outside the main menu
    for scr, setup, pat in (("welcome", lambda s: s.start(), r"== Welcome, alice ==.*?" + PROMPT),
                            ("boards list", lambda s: (s.main(), s.k("1", BOARDS)), BOARDS),
                            ("thread list", lambda s: (s.main(), s.k("1", BOARDS), s.k("1", GEN())), GEN()),
                            ("mail menu", lambda s: (s.main(), s.k("5", MAILM)), MAILM),
                            ("wall", lambda s: (s.main(), s.k("2", WALL)), WALL)):
        s, root, home = sess(w)
        try:
            setup(s)
            s.k("g", CONF)
            s.k("n", pat)
            chk("3 G on %s: Log out? [y/N], n stays on the same screen" % scr, True)
            s.k("g", CONF)
            s.k("q", pat)
            chk("3 G on %s: answering q does not act as Back (the answer is not a command)" % scr, True)
            s.k("G", CONF); s.send("y"); s.expect(r"Bye\.")
            chk("3 G on %s, then y: logs out" % scr, s.wait_exit())
        finally:
            s.close()
    # nothing in open posts, folders, open messages, edit_post, members
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN()); s.k("1", POST())
        inert(s, b"gG", b"q", GEN(), "3 G in an open post")
        s.k("1", POST())
        s.send("e"); s.expect(r"New subject \(\[Enter\] keeps\): $")
        s.k("\n", r"K\) Keep text.*" + PROMPT)
        inert(s, b"gG", b"q", GEN(), "3 G in edit_post (K/N/Q menu)")
        s.k("q", BOARDS); s.k("3", title_pat("priv", r"S\) Members"))
        s.k("s", title_pat("Members", r"A\) Add"))
        inert(s, b"gG", b"q", title_pat("priv", r"S\) Members"), "3 G in members")
        s.k("q", BOARDS); s.k("q", MAIN)
        s.k("5", MAILM)
        s.k("1", title_pat("Inbox", r"Number: open"))
        inert(s, b"gG", b"1", title_pat("Inbox", r"R\) Reply"), "3 G in a mail folder")
        inert(s, b"gG", b"q", title_pat("Inbox", r"Number: open"), "3 G in an open message")
        s.k("q", MAILM); s.k("q", MAIN)
        s.k("2", WALL)
        s.send("n"); s.expect(r"Back\.\r\n> $")
        s.send("gG\n")           # text input: G is text, nothing asked
        t = s.expect(PAUSE)
        chk("3 G in text input is text (no Log out?)", "Log out?" not in t)
        chk("3 G in text input is stored", any(rd(f).strip() == "gG" for f in files(root, "*.wall")))
    finally:
        s.close()


# ---------------------------------------------------------------- 4. jump keys
JUMP = {"b": ("Public boards", BOARDS), "m": ("BashBBS", MAIN), "p": ("Private messages", MAILM), "w": ("Wall", WALL)}


@scenario
def s_jump(w):
    origins = (
        ("welcome", lambda s: s.start(), None),
        ("boards list", lambda s: (s.main(), s.k("1", BOARDS)), lambda s: s.k("1", BOARDS)),
        ("thread list", lambda s: (s.main(), s.k("1", BOARDS), s.k("1", GEN())), lambda s: (s.k("1", BOARDS), s.k("1", GEN()))),
        ("mail menu", lambda s: (s.main(), s.k("5", MAILM)), lambda s: s.k("5", MAILM)),
        ("wall", lambda s: (s.main(), s.k("2", WALL)), lambda s: s.k("2", WALL)),
    )
    for nm, setup, back in origins:
        s, root, home = sess(w)
        try:
            setup(s)
            ok_all = True
            for key in "bmpw":
                for kk in (key, key.upper()):
                    if nm == "welcome" and kk != key and key != "w":
                        pass
                    t = s.k(kk, JUMP[key][1])
                    chk("4 jump %s on %s: goes to %s" % (kk, nm, JUMP[key][0]), True)
                    if nm == "welcome":
                        # welcome is a one-shot screen: restart a session for the next key
                        break
                    # back to the origin
                    if key != "m":
                        s.k("q", MAIN)
                    back(s)
                if nm == "welcome":
                    s.close()
                    s, root, home = sess(w)
                    s.start()
        finally:
            s.close()
    # ignored where the origin is a folder / open item / text input
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN()); s.k("1", POST())
        inert(s, b"bmpwBMPW", b"q", GEN(), "4 open post ignores B M P W")
        s.k("q", BOARDS); s.k("q", MAIN)
        s.k("5", MAILM)
        s.k("1", title_pat("Inbox", r"Number: open"))
        inert(s, b"bmpwBMPW", b"1", title_pat("Inbox", r"R\) Reply"), "4 mail folder ignores B M P W")
        inert(s, b"bmpwBMPW", b"q", title_pat("Inbox", r"Number: open"), "4 open message ignores B M P W")
        # Q steps back one level at a time
        s.k("q", MAILM)
        chk("4 Q: message -> folder -> mail menu", True)
        s.k("q", MAIN)
        chk("4 Q: mail menu -> main", True)
        s.k("1", BOARDS); s.k("1", GEN())
        # text input: bmpw are letters
        s.send("n"); s.expect(r"Subject: $")
        s.send("bmpwBMPWgG\n")
        s.expect(r"Write text\. End with a single dot \(\.\)\.\r\n")
        s.send(".\n")
        s.expect(PAUSE)
        chk("4 text input: B M P W G typed as text are in the subject",
            any("Subject: bmpwBMPWgG\n" in rd(f) for f in files(root, "*.post")))
    finally:
        s.close()


# ---------------------------------------------------------------- 5. help
@scenario
def s_help(w):
    s, root, home = sess(w)

    def helpcheck(nm, pat, danger, tail=False):
        before = s.screens[-1]
        s.send("?")
        t = s.expect(r"== Help ==.*\[Any key\] Back\r\n$")
        sc = last_screen(t)
        L = lines_of(sc)
        i = next(i for i, l in enumerate(L) if l == "== Help ==")
        j = next(j for j, l in enumerate(L) if l == "[Any key] Back")
        body = [l for l in L[i + 2:j]]
        chk("5 help %s: at most 4 lines (title + body)" % nm, 1 + len(body) <= 4 and len(body) >= 1, repr(body))
        chk("5 help %s: every line at most 40 columns" % nm, all(cellw(l) <= min(40, w) for l in L), repr([l for l in L if cellw(l) > 40]))
        t2 = s.k(danger, pat)
        sc2 = last_screen(t2)
        if tail:      # edit_post redraws only its question after the help (see the report)
            same = lines_of(sc2)[-2:] == lines_of(before)[-2:]
        else:
            same = lines_of(sc2) == lines_of(before)
        chk("5 help %s: any key returns to the same screen" % nm, same, repr(sc2[:120]))
        chk("5 help %s: the dismissing key %r is not executed" % (nm, danger.decode()),
            len(CLR.split(t2)) == 2 and "Log out?" not in t2 and "Move to Trash" not in t2 and "DELETE" not in t2, repr(t2[:150]))
    try:
        t0 = s.start()
        s.screens.append(last_screen(t0))
        helpcheck("welcome", r"== Welcome, alice ==.*?" + PROMPT, b"g")
        s.k("x", MAIN); helpcheck("main", MAIN, b"q")
        s.k("1", BOARDS); helpcheck("boards", BOARDS, b"q")
        s.k("1", GEN()); helpcheck("thread list", GEN(), b"q")
        s.k("1", POST()); helpcheck("post", POST(), b"d")
        s.send("e"); s.expect(r"New subject \(\[Enter\] keeps\): $")
        s.k("\n", r"K\) Keep text.*" + PROMPT); helpcheck("edit_post", r"K\) Keep text.*" + PROMPT, b"q", True)
        s.k("q", GEN()); s.k("q", BOARDS)
        s.k("3", title_pat("priv", r"S\) Members"))
        s.k("s", title_pat("Members", r"A\) Add")); helpcheck("members", title_pat("Members", r"A\) Add"), b"q")
        s.k("q", title_pat("priv")); s.k("q", BOARDS); s.k("q", MAIN)
        s.k("5", MAILM); helpcheck("mail menu", MAILM, b"q")
        s.k("1", title_pat("Inbox", r"Number: open")); helpcheck("inbox", title_pat("Inbox", r"Number: open"), b"q")
        s.k("1", title_pat("Inbox", r"R\) Reply")); helpcheck("mail_view (message)", title_pat("Inbox", r"R\) Reply"), b"d")
        s.k("q", title_pat("Inbox", r"Number: open")); s.k("q", MAILM)
        s.k("3", title_pat("Sent", r"Number: open")); helpcheck("sent", title_pat("Sent", r"Number: open"), b"q")
        s.k("q", MAILM)
        s.k("4", title_pat("Trash", r"Number: open")); helpcheck("trash", title_pat("Trash", r"Number: open"), b"q")
        s.k("q", MAILM); s.k("q", MAIN)
        s.k("2", WALL); helpcheck("wall", WALL, b"q")
        s.k("q", MAIN)
        # users / my account have no help: any key (including ?) simply returns
        s.k("3", USERS); t = s.k("?", MAIN)
        chk("5 users: any key (even ?) returns to main, no help screen", "== Help ==" not in t)
        s.k("4", ACCT); t = s.k("?", MAIN)
        chk("5 my account: any key (even ?) returns to main, no help screen", "== Help ==" not in t)
        bad = s.rows_ok()
        chk("5 help walk: no row wider than %d" % w, not bad, repr(bad[:2]))
    finally:
        s.close()


# ---------------------------------------------------------------- 6. wall
@scenario
def s_wall(w):
    s, root, home = sess(w)
    try:
        s.main()
        t = s.k("2", WALL)
        L = lines_of(last_screen(t))
        foot = [l for l in L if "[Space] Next" in l]
        chk("6 wall footer shows [Space] Next", len(foot) == 1, repr(L[-4:]))
        chk("6 wall footer fits %d columns" % w, bool(foot) and cellw(foot[0]) <= w, repr(foot))
        chk("6 wall starts on page 1 of 2", "Page 1 of 2" in t)
        inert(s, b"\n\n", b" ", r"Page 2 of 2.*" + PROMPT, "6 wall: Enter does not turn the page")
        chk("6 wall: Space turns the page", True)
        t = s.k(" ", r"Page 1 of 2.*" + PROMPT)
        chk("6 wall: Space after the last page wraps to page 1", True)
    finally:
        s.close()


# ---------------------------------------------------------------- 7. buffer
@scenario
def s_buffer(w):
    s, root, home = sess(w)
    try:
        s.main()
        # (a) B followed by four Enters in one write: only B acts
        t = s.k("b\n\n\n\n", BOARDS)
        chk("7a B + 4 Enters: only B acts (one redraw)", len(CLR.split(t)) == 2, repr(t[:100]))
        inert(s, b"", b"q", MAIN, "7a ... and nothing is left over")
        # 3 + Enters: Enters must not dismiss the [Any key] screen
        t = s.k("3\n\n\n\n", USERS)
        chk("7a 3 + 4 Enters: the Users screen stays up", len(CLR.split(t)) == 2)
        t = s.k("z", MAIN)
        chk("7a ... the next key dismisses it, one redraw of main", len(CLR.split(t)) == 2)
        inert(s, b"", b"4", ACCT, "7a ... nothing left over")
        s.k("x", MAIN)
        # (d) arrow keys do nothing in menus
        for scr, setup, back, pat, probe, ppat in (
                ("main", None, None, MAIN, b"4", ACCT),):
            inert(s, ARROWS, probe, ppat, "7d arrows in the %s menu" % scr)
            s.k("x", MAIN)
        s.k("1", BOARDS); inert(s, ARROWS, b"1", GEN(), "7d arrows in the boards list")
        inert(s, ARROWS, b"1", POST(), "7d arrows in the thread list")
        inert(s, ARROWS, b"q", GEN(), "7d arrows in an open post")
        s.k("q", BOARDS); s.k("q", MAIN)
        s.k("5", MAILM); inert(s, ARROWS, b"1", title_pat("Inbox", r"Number: open"), "7d arrows in the mail menu")
        inert(s, ARROWS, b"1", title_pat("Inbox", r"R\) Reply"), "7d arrows in a mail folder")
        inert(s, ARROWS, b"q", title_pat("Inbox", r"Number: open"), "7d arrows in an open message")
        s.k("q", MAILM); s.k("q", MAIN)
        s.k("2", WALL); inert(s, ARROWS, b" ", r"Page 2 of 2.*" + PROMPT, "7d arrows in the wall")
        s.k("q", MAIN)
        # arrows at confirm prompts: = no, and nothing leaks
        for arrow in (b"\x1b[A", b"\x1b[B", b"\x1bOA"):
            s.k("q", CONF); t = s.k(arrow, MAIN)
            chk("7d %r at Log out?: no, stays" % arrow, "Bye." not in t)
        inert(s, b"", b"4", ACCT, "7d ... no leftover bytes after the arrows at the confirm")
        s.k("x", MAIN)
        # (e) split escape sequence: ESC, 100 ms, [A
        s.send(ESC); time.sleep(0.1); s.send(b"[A")
        inert(s, b"", b"4", ACCT, "7e ESC + 100 ms + [A in the main menu")
        s.k("x", MAIN)
        s.k("1", BOARDS); s.k("3", title_pat("priv", r"S\) Members")); s.k("s", title_pat("Members", r"A\) Add"))
        s.send(ESC); time.sleep(0.1); s.send(b"[A")
        # in members A is Add: an escaped A must not open the User: prompt
        t = s.k("q", title_pat("priv", r"S\) Members"))
        chk("7e ESC + 100 ms + [A in members: A is not executed (no User: prompt)", "User:" not in t, repr(t[:150]))
    finally:
        s.close()
    # (b) pasted dddd / dyyy at the delete question in an open message
    for paste, nm in ((b"dddd\n", "dddd+Enter"), (b"dyyyy\n", "d+yyyy+Enter"), (b"d\n\n\n", "d+Enters")):
        s, root, home = sess(w)
        try:
            s.main(); s.k("5", MAILM); s.k("1", title_pat("Inbox", r"Number: open"))
            s.k("1", title_pat("Inbox", r"R\) Reply"))
            t = s.k(paste, r"Move to Trash\? \[y/N\] $")
            chk("7b pasted %s: the question waits, nothing confirmed" % nm,
                not inbox_names(home, "/.Trash")[1:] and len(inbox_names(home, "/.Trash")) == 1, repr(inbox_names(home, "/.Trash")))
            s.send("n"); s.expect(PAUSE)
            chk("7b pasted %s: after the wait, n answers no (nothing moved)" % nm, len(inbox_names(home, "/.Trash")) == 1)
        finally:
            s.close()
    # (c) compose text, then Enters right behind it
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN())
        s.send("n"); s.expect(r"Subject: $")
        s.send("Rubrik\n"); s.expect(r"Write text\. End with a single dot \(\.\)\.\r\n")
        s.send("rad\n.\n\n\n\n")
        t = s.expect(PAUSE)
        chk("7c Enters behind the finished text: the [Any key] screen waits", True)
        t = s.k("z", GEN())
        chk("7c ... then one redraw of the thread list, no menu action", len(CLR.split(t)) == 2)
        chk("7c the post was queued once", len(files(root, "*.post")) == 1)
        # wall: text + Enters
        s.k("q", BOARDS); s.k("q", MAIN); s.k("2", WALL)
        s.send("n"); s.expect(r"Back\.\r\n> $")
        s.send("hej\n\n\n\n"); s.expect(PAUSE)
        t = s.k("z", WALL)
        chk("7c wall text + Enters: no menu action, one redraw", len(CLR.split(t)) == 2)
    finally:
        s.close()
    # (f) a key sent the moment the prompt appears is never lost: 50 repetitions
    s, root, home = sess(w)
    try:
        s.main()
        for i in range(50):
            s.send(b"3"); s.expect(USERS)
            s.send(b"x"); s.expect(MAIN)
        chk("7f main menu + [Any key]: 50 keys sent at the prompt, none lost", True)
        for i in range(50):
            s.send(b"q"); s.expect(CONF)
            s.send(b"n"); s.expect(MAIN)
        chk("7f Log out? confirm: 50 keys sent at the prompt, none lost", True)
    except Timeout as e:
        chk("7f key sent at the prompt was lost (repetition %d)" % i, False, str(e))
    finally:
        s.close()
    s, root, home = sess(w)
    try:
        s.main(); s.k("5", MAILM); s.k("1", title_pat("Inbox", r"Number: open")); s.k("1", title_pat("Inbox", r"R\) Reply"))
        for i in range(50):
            s.send(b"d"); s.expect(r"Move to Trash\? \[y/N\] $")
            s.send(b"n"); s.expect(PAUSE)
            s.send(b"x"); s.expect(title_pat("Inbox", r"Number: open"))
            s.send(b"1"); s.expect(title_pat("Inbox", r"R\) Reply"))
        chk("7f Move to Trash? confirm + pause: 50 keys sent at the prompt, none lost", True)
    except Timeout as e:
        chk("7f key sent at the prompt was lost (trash repetition %d)" % i, False, str(e))
    finally:
        s.close()
    # (g) delayed delivery
    for d in (0.03, 0.15, 0.3):
        ms = int(d * 1000)
        s, root, home = sess(w)
        try:
            s.main()
            s.send(b"x"); time.sleep(d); s.send(b"z"); time.sleep(d); s.send(b"4")
            s.expect(ACCT)
            chk("7g %d ms: ignored keys then 4 arrive in order" % ms, True)
            s.k("x", MAIN)
            s.send(b"2"); s.expect(WALL)
            s.send(b"n"); s.expect(r"Back\.\r\n> $")
            for ch in b"abcdef":
                s.send(bytes([ch])); time.sleep(d)
            s.send(b"\n"); s.expect(PAUSE)
            chk("7g %d ms: text typed with delays arrives in order" % ms,
                any(rd(f).strip() == "abcdef" for f in files(root, "*.wall")))
            s.k("x", WALL)
            s.k("q", MAIN)
            s.k("1", BOARDS); s.k("3", title_pat("priv", r"S\) Members")); s.k("s", title_pat("Members", r"A\) Add"))
            if d < 0.2:
                s.send(ESC); time.sleep(d); s.send(b"[A")
                t = s.k("q", title_pat("priv", r"S\) Members"))
                chk("7g %d ms: arrow with a slow second part is still swallowed" % ms, "User:" not in t)
        except Timeout as e:
            chk("7g %d ms delayed delivery completed" % ms, False, str(e))
        finally:
            s.close()
        s, root, home = sess(w, "many", ["b%02d" % i for i in range(1, 13)])
        try:
            s.main(); s.k("1", BOARDS.replace("K\\) New private board", "b12") if False else r"== Public boards ==.*b12.*" + PROMPT)
            s.send(b"1"); time.sleep(d); s.send(b"2")
            t = s.expect(r"== b12 ==.*" + PROMPT)
            chk("7g %d ms: two-digit board number 12 arrives in order" % ms, True)
        except Timeout as e:
            chk("7g %d ms two-digit number" % ms, False, str(e))
        finally:
            s.close()


# ---------------------------------------------------------------- 8. text input
BODY = ["Första stycket åäö", "", "Andra stycket 日本語 – q är bara text", "", "", "Q", "sista"]


@scenario
def s_text(w):
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN())
        s.send("n"); s.expect(r"Subject: $")
        s.send("Ämne åäö 日本\n"); s.expect(r"Write text\. End with a single dot \(\.\)\.\r\n")
        s.send("\n".join(BODY) + "\n.\n")
        s.expect(PAUSE)
        f = files(root, "*.post")
        want = "Board: general\nSubject: Ämne åäö 日本\n\n" + "\n".join(BODY) + "\n"
        chk("8 post: multi-paragraph text with blank lines, å ä ö and CJK stored intact, Q is text",
            len(f) == 1 and rd(f[0]) == want, repr(rd(f[0]) if f else None))
        s.k("x", GEN())
        # empty subject cancels the post (as in 1.3)
        n0 = len(files(root, "*.post"))
        s.send("n"); s.expect(r"Subject: $")
        t = s.k("\n", GEN())
        chk("8 post: empty subject cancels, nothing queued (as in 1.3)", len(files(root, "*.post")) == n0 and "Write text" not in t)
        # Reply carries the parent
        s.k("1", POST()); s.send("r"); s.expect(r"Subject: $")
        s.send("Svar\n"); s.expect(r"single dot \(\.\)\.\r\n"); s.send("ja\n.\n"); s.expect(PAUSE)
        chk("11 reply: queued with Parent: m1", any("Parent: m1\n" in rd(x) and "Subject: Svar" in rd(x) for x in files(root, "*.post")))
        s.k("x", GEN()); s.k("q", BOARDS); s.k("q", MAIN)
        # wall
        s.k("2", WALL)
        txt = "q är text bmpwg åäö 日本 end"
        s.send("n"); s.expect(r"Back\.\r\n> $"); s.send(txt + "\n"); s.expect(PAUSE)
        chk("11 wall write: queued, text intact (Q, B M P W G and CJK are text)", any(rd(x).strip() == txt for x in files(root, "*.wall")))
        s.k("x", WALL)
        n0 = len(files(root, "*.wall"))
        t = s.k("n", r"Back\.\r\n> $"); t = s.k("\n", WALL)
        chk("8 wall: empty line cancels, nothing saved (as in 1.3)", len(files(root, "*.wall")) == n0 and "Sent." not in t)
        s.k("q", MAIN)
        # mail
        s.k("5", MAILM); s.send("2"); s.expect(r"To \(/cancel stops\): $")
        s.send("bob\n"); s.expect(r"Subject \(/cancel stops\): $"); s.send("Hej åäö 日本\n")
        s.expect(r"single dot \(\.\)\.\r\n"); s.send("\n".join(BODY) + "\n.\n")
        s.expect(r"Send\? \[y/N\] $"); s.send("y"); s.expect(PAUSE)
        dm = delivered(root)
        want = "\n".join(BODY) + "\n"
        got = rd(dm[0]).split("\n\n", 1)[1] if dm else None
        chk("8 mail: multi-paragraph body intact (blank lines, åäö, CJK, Q is text)", len(dm) == 1 and got == want, repr(got))
        chk("11 mail write: Subject header intact", len(dm) == 1 and "Subject: Hej åäö 日本\n" in rd(dm[0]))
        s.k("x", MAILM)
        # empty lines in mail, as in 1.3
        s.send("2"); s.expect(r"To \(/cancel stops\): $")
        s.k("\n", PAUSE)       # 1.3: empty To = Unknown user + [Any key]
        t = s.k("x", MAILM)
        chk("8 mail: empty To is 'Unknown user' + pause, as in 1.3 (not a cancel)", len(delivered(root)) == 1)
        s.send("2"); s.expect(r"To \(/cancel stops\): $")
        s.k("/cancel\n", MAILM)
        chk("8 mail: /cancel at To returns at once", len(delivered(root)) == 1)
        s.send("2"); s.expect(r"To \(/cancel stops\): $"); s.send("bob\n"); s.expect(r"Subject \(/cancel stops\): $")
        s.send("x\n"); s.expect(r"single dot \(\.\)\.\r\n"); s.send("text\n/cancel\n"); s.expect(PAUSE)
        chk("8 mail: /cancel in the body sends nothing", len(delivered(root)) == 1)
        s.k("x", MAILM)
        s.send("2"); s.expect(r"To \(/cancel stops\): $"); s.send("bob\n"); s.expect(r"Subject \(/cancel stops\): $")
        s.send("\n"); s.expect(r"single dot \(\.\)\.\r\n"); s.send("body\n.\n"); s.expect(r"Send\? \[y/N\] $"); s.send("y"); s.expect(PAUSE)
        chk("8 mail: empty subject becomes (no subject), as in 1.3", any("Subject: (no subject)" in rd(x) for x in delivered(root)))
        s.k("x", MAILM)
        # reply from the inbox
        s.k("1", title_pat("Inbox", r"Number: open")); s.k("1", title_pat("Inbox", r"R\) Reply"))
        s.send("r"); t = s.expect(r"Subject \[(Re: .*?)\] \(/cancel stops\): $")
        chk("11 mail reply: To is the sender and Subject gets Re:", "Re: Ny" in t)
        s.send("\n"); s.expect(r"single dot \(\.\)\.\r\n"); s.send("svar\n.\n"); s.expect(r"Send\? \[y/N\] $"); s.send("y"); s.expect(PAUSE)
        chk("11 mail reply: delivered with In-Reply-To", any("In-Reply-To: <i1@" in rd(x) for x in delivered(root)))
        s.k("x", title_pat("Inbox", r"Number: open")); s.k("q", MAILM)
        t = s.k("3", title_pat("Sent", r"Number: open"))
        chk("11 mail sent: the sent copy is listed", "Skickat" in t and "Re: Ny" in t)
        s.k("q", MAILM); t = s.k("4", title_pat("Trash", r"Number: open"))
        chk("11 mail trash: list opens", "Raderat" in t)
        s.k("q", MAILM); s.k("q", MAIN)
        t = s.k("4", ACCT)
        chk("11 my account: shows the name", "Name:  alice" in t)
    finally:
        s.close()


# ---------------------------------------------------------------- 9. UTF-8
@scenario
def s_utf8(w):
    s, root, home = sess(w)
    try:
        s.main()
        s.k("1", BOARDS); s.k("1", GEN())
        t = s.k("1", POST())
        s.k("q", GEN())
        t = s.k("2", POST() if False else r"== general ==.*日本語.*" + PROMPT)
        s.k("q", GEN())
        s.k("q", BOARDS); s.k("q", MAIN)
        s.k("3", USERS); s.k("x", MAIN)
        s.k("2", WALL); s.k("q", MAIN)
        s.k("5", MAILM); s.k("1", title_pat("Inbox", r"Number: open")); s.k("1", title_pat("Inbox", r"R\) Reply"))
        s.k("q", title_pat("Inbox", r"Number: open")); s.k("q", MAILM); s.k("3", title_pat("Sent", r"Number: open"))
        s.k("q", MAILM); s.k("q", MAIN)
        s.send("q"); s.expect(CONF); s.send("y"); s.expect(r"Bye\.")
        s.wait_exit()
        try:
            txt = s.raw.decode("utf-8")
            chk("9 utf-8: the whole session output decodes as valid UTF-8", True)
            chk("9 utf-8: no replacement character in the output", "\ufffd" not in txt)
            chk("9 utf-8: å ä ö and CJK appear (board, wall, mail, users)", all(c in txt for c in ("åäö", "日本語", "Böb")))
        except UnicodeDecodeError as e:
            chk("9 utf-8: the whole session output decodes as valid UTF-8", False, str(e))
        bad = s.rows_ok()
        chk("9 utf-8: board view, post, wall, users, mail lists: no row wider than %d" % w, not bad, repr(bad[:3]))
        # iconv agrees
        p = subprocess.run(["iconv", "-f", "UTF-8", "-t", "UTF-8"], input=s.raw, capture_output=True)
        chk("9 utf-8: iconv accepts the output", p.returncode == 0)
    finally:
        s.close()


# ---------------------------------------------------------------- 10. destructive
@scenario
def s_destructive(w):
    for ans, nm, moved in ((b"\n", "Enter", False), (b"n", "n", False), (b"x", "other key", False),
                           (b"\x1b[A", "arrow", False), (b"y", "y", True), (b"Y", "Y", True)):
        s, root, home = sess(w)
        try:
            s.main(); s.k("5", MAILM); s.k("1", title_pat("Inbox", r"Number: open")); s.k("1", title_pat("Inbox", r"R\) Reply"))
            s.k("d", r"Move to Trash\? \[y/N\] $")
            s.send(ans); s.expect(PAUSE)
            tr = inbox_names(home, "/.Trash")
            chk("10 mail: D then %s %s" % (nm, "moves to Trash" if moved else "does nothing"),
                (len(tr) == 2) == moved, repr(tr))
            chk("10 mail: D then %s: the message %s the Inbox" % (nm, "left" if moved else "stays in"),
                (len([n for n in inbox_names(home, "") if n.startswith("1.")]) == 0) == moved)
        finally:
            s.close()
    # sent folder
    s, root, home = sess(w)
    try:
        s.main(); s.k("5", MAILM); s.k("3", title_pat("Sent", r"Number: open")); s.k("1", title_pat("Sent", r"D\) Delete"))
        s.k("d", r"Move to Trash\? \[y/N\] $"); s.send("\n"); s.expect(PAUSE)
        chk("10 sent: D then Enter does nothing", len(inbox_names(home, "/.Trash")) == 1)
    finally:
        s.close()
    # public post: typed DELETE
    for text, nm, sent in ((b"\n", "Enter", False), (b"delete\n", "lowercase delete", False), (b"y\n", "y", False),
                           (b"DELET\n", "DELET", False), (b"DELETE\n", "DELETE", True)):
        s, root, home = sess(w)
        try:
            s.main(); s.k("1", BOARDS); s.k("1", GEN()); s.k("1", POST())
            s.k("d", r"Type DELETE \(\[Enter\] Back\): $")
            s.send(text)
            if sent:
                s.expect(PAUSE)
            else:
                s.expect(GEN())       # a cancelled delete returns to the thread list
            rq = files(root, "*.req")
            chk("10 public post: D then %r %s" % (nm, "queues the delete" if sent else "does not delete"),
                (len(rq) == 1 and "Action: delete-post" in rd(rq[0]) and "Msgid: m1" in rd(rq[0])) if sent else not rq, repr(rq))
        finally:
            s.close()
    # a post of somebody else: no D offered
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN())
        t = s.k("3", POST())
        chk("10 public post by others: no Delete or Edit offered to an ordinary user", "D) Delete" not in t and "E) Edit" not in t)
    finally:
        s.close()


# ---------------------------------------------------------------- 11. commands reachable
@scenario
def s_commands(w):
    s, root, home = sess(w)
    try:
        s.main(); s.k("1", BOARDS); s.k("1", GEN()); s.k("1", POST())
        # edit: new subject, new text
        s.send("e"); s.expect(r"New subject \(\[Enter\] keeps\): $"); s.send("Nytt ämne\n")
        s.expect(r"K\) Keep text.*" + PROMPT); s.send("n"); s.expect(r"single dot \(\.\)\.\r\n")
        s.send("ny text\n\nmer\n.\n"); s.expect(PAUSE)
        rq = files(root, "*.req")
        chk("11 edit: edit-post request queued with the new subject and text",
            len(rq) == 1 and "Action: edit-post" in rd(rq[0]) and "Subject: Nytt ämne" in rd(rq[0]) and rd(rq[0]).endswith("\n\nny text\n\nmer\n"), repr(rd(rq[0]) if rq else None))
        s.k("x", GEN())
        # edit, keep text
        s.k("1", POST())
        s.send("e"); s.expect(r"New subject \(\[Enter\] keeps\): $"); s.send("\n")
        s.k("k", PAUSE)
        chk("11 edit: keep text queues a second request", len(files(root, "*.req")) == 2)
        s.k("x", GEN())
        s.k("1", POST())
        s.send("e"); s.expect(r"New subject \(\[Enter\] keeps\): $"); s.send("\n")
        s.k("q", GEN())
        chk("11 edit: Q cancels the edit (nothing queued)", len(files(root, "*.req")) == 2)
        s.k("q", BOARDS)
        # members
        s.k("3", title_pat("priv", r"S\) Members")); s.k("s", title_pat("Members", r"A\) Add"))
        s.send("a"); s.expect(r"User: $"); s.send("bob\n"); s.expect(PAUSE)
        chk("11 members: add queued", any("Action: invite" in rd(x) and "User: bob" in rd(x) for x in files(root, "*.req")))
        s.k("x", title_pat("priv", r"S\) Members"))
        s.k("s", title_pat("Members", r"A\) Add")); s.send("R"); s.expect(r"User: $"); s.send("bob\n"); s.expect(PAUSE)
        chk("11 members: remove queued (capital R)", any("Action: remove" in rd(x) for x in files(root, "*.req")))
        s.k("x", title_pat("priv", r"S\) Members"))
        # new private board
        s.k("q", BOARDS); s.send("k"); s.expect(r"Name \(a-z.*\): $"); s.send("nyttbrade\n"); s.expect(PAUSE)
        chk("11 new private board: create-board queued", any("Action: create-board" in rd(x) and "Board: nyttbrade" in rd(x) for x in files(root, "*.req")))
        s.k("x", BOARDS)
        t = s.k("2", r"== hobby ==.*" + PROMPT)
        chk("11 second board opens", "Hobbypost" in t)
        bad = s.rows_ok()
        chk("11 command walk: no row wider than %d" % w, not bad, repr(bad[:2]))
    finally:
        s.close()


def main():
    for w in WIDTHS:
        CUR[0] = w
        for f in SCEN:
            if ONLY and ONLY not in f.__name__:
                continue
            t0 = time.time()
            try:
                f(w)
            except Timeout as e:
                chk("%s: scenario completed" % f.__name__, False, str(e))
            except Exception as e:
                chk("%s: scenario completed (exception)" % f.__name__, False, repr(e))
            logf.write("--- %s [%d] %.1fs\n" % (f.__name__, w, time.time() - t0))
            logf.flush()
    p = sum(1 for r in results if r[2])
    f = len(results) - p
    print("nav_test: %d passed, %d failed (log: %s)" % (p, f, LOG))
    return 1 if f else 0


sys.exit(main())
PYEOF

ps -Ao pid,command | grep -E '[_]test\.sh|[p]ty_drive|[v]itest' | grep -v "nav_test" >/dev/null && echo "note: another test runner may be active" >&2
nice -n 19 python3 "$py" "$here" "$work" "$log" "${NAV_WIDTHS:-40,60,80}" "${NAV_ONLY:-}"
rc=$?
[[ $rc -eq 0 ]] && rm -rf "$work"
exit $rc
