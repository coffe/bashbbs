#!/bin/bash
# BashBBS perf measurement: wall time per screen and fork/exec counts (measurement only).
# Builds a realistic temporary BBS_ROOT (3 boards ~200 posts, a 30-reply thread, 20 mails,
# 2 file areas with 30 files with multi-line desc=, a news board), drives lib/menu.sh in a pty
# (same drv.sh pattern as tests/nav_test.sh) and walks the main screens in order.
#   timing: N runs without tracing, median ms from key press to the final prompt.
#   trace : one run with bash xtrace (BASH_XTRACEFD) - counts distinct forked PIDs and external
#           commands per screen window. strace is used instead when it exists (not on jelly).
# Usage: tests/perf_screens.sh [outdir] [runs]     Nothing outside outdir is touched.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-${TMPDIR:-/tmp}/perf.$$}
runs=${2:-5}
mkdir -p "$out"
exec nice -n 19 python3 -I - "$here" "$out" "$runs" <<'PYEOF'
import codecs, fcntl, json, os, pty, re, select, shutil, statistics, struct, subprocess, sys, termios, time, collections

HERE, OUT, RUNS = sys.argv[1], sys.argv[2], int(sys.argv[3])
DRV = os.path.join(OUT, "drv.sh")
open(DRV, "w").write('''#!/bin/bash
# Start loop of lib/menu.sh taken from the file itself (as nav_test.sh does).
if [[ -n ${PERF_TRACE:-} ]]; then
    exec 9>"$PERF_TRACE"; BASH_XTRACEFD=9
    PS4='+${BASHPID} ${EPOCHREALTIME} ${BASH_SOURCE[0]##*/}:${LINENO}:${FUNCNAME[0]} '
    set -x
fi
export BASHBBS_TEST=1
source "%s/lib/menu.sh"
board_is_private() { [[ -f $BBS_ROOT/meta/$(basename "$1").meta ]]; }
eval "$(sed -n '/^if \\[\\[ -z \\${BASHBBS_TEST/,$p' "%s/lib/menu.sh" | sed '1d;$d')"
''' % (HERE, HERE))

ANSI = re.compile(r"\x1b\[[0-9;]*m")
COL = os.environ.get("PERF_COLOR") == "1"

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w", encoding="utf-8").write(text)

def post(root, board, seq, mid, author, subject, body, parent=None):
    put("%s/boards/%s/%d-%s.msg" % (root, board, 1500000000 + seq, mid),
        "Board: %s\nMsgid: %s\nSubject: %s\nAuthor: %s\nDate: 2026-10-01T10:%02d:00Z\n%s\n%s\n"
        % (board, mid, subject, author, seq % 60, ("Parent: %s\n" % parent) if parent else "", body))

LOREM = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor. " * 3

def mkroot():
    root = OUT + "/root"; home = root + "/home/bbs-alice"
    shutil.rmtree(root, ignore_errors=True)
    for d in ("queue/incoming", "meta", "wall", "t", "state", "etc", "published"):
        os.makedirs(root + "/" + d)
    for u in ("alice", "bob", "carol", "dave", "erin"):
        put("%s/users/%s/profile" % (root, u), "name=%s\nuuid=11111111-2222-3333-4444-5555666677%02d\n" % (u, ord(u[0])))
    put(root + "/sysops", "carol\n")
    put(root + "/t/sendmail", "#!/bin/bash\ncat >/dev/null\n"); os.chmod(root + "/t/sendmail", 0o755)
    au = ["alice", "bob", "carol", "dave", "erin"]
    seq = 1
    # general: newest = a 30-reply thread root; then a lone post; then 68 more threads
    for b, cnt in (("hobby", 60), ("whatsup", 60)):
        for i in range(cnt):
            seq += 1; post(root, b, seq, "%s%d" % (b[0], i), au[i % 5], "Topic %d on %s" % (i, b), LOREM)
    for i in range(70):
        seq += 1; post(root, "general", seq, "g%d" % i, au[i % 5], "General topic %d" % i, LOREM)
    seq += 1; post(root, "general", seq, "lone", "bob", "A lone post", LOREM + "\n\nsecond paragraph\n" + LOREM)
    seq += 1; post(root, "general", seq, "troot", "alice", "The long thread", LOREM)
    for i in range(30):
        seq += 1
        post(root, "general", seq, "tr%d" % i, au[i % 5], "Re: The long thread", LOREM, parent="troot" if i % 2 else ("tr%d" % (i - 1) if i else "troot"))
    for i in range(10):
        seq += 1; post(root, "news", seq, "n%d" % i, "news", "News item %d" % i, LOREM)
    os.makedirs(root + "/boards/priv"); put(root + "/meta/priv.meta", "owner=alice\n")
    for i in range(12):
        put("%s/wall/%d%09d-w%d.msg" % (root, 1500000000 + i, i, i), "Author: bob\nDate: 2026-10-01T10:%02d:00Z\n\nHi %d" % (i, i))
    put(root + "/etc/file-areas", "general|General|Misc files\ntunes|Tunes|Modules and music\n")
    for i in range(30):
        fid = "%d-%08x" % (1790000000 + i * 1000, 0xabc00000 + i)
        put("%s/published/%s" % (root, fid), "data%d\n" % i)
        put("%s/published/%s.meta" % (root, fid),
            "user=bbs-%s\nsize=%d\ndate=2026-10-%02dT10:00:00Z\nname=file%02d_with_a_longish_name.zip\narea=%s\n"
            "desc=Line one of the description %d\ndesc=Line two with more text\ndesc=Line three\ndesc=Line four\n"
            % (au[i % 5], 1000 * (i + 1) * 37, 1 + i % 28, i, "tunes" if i % 2 else "general", i))
    for i in range(20):
        sub = "new" if i < 8 else "cur"
        put("%s/Maildir/%s/%d.m%d.h%s" % (home, sub, 1790000000 + i, i, "" if sub == "new" else ":2,S"),
            "From: bob@host\nTo: alice@host\nSubject: Mail number %d about things\nDate: Thu, 01 Oct 2026 10:%02d:00 +0000\n"
            "Message-ID: <m%d@host>\n\n%s\nsecond line\n" % (i, i, i, LOREM))
    for d in ("cur", "new", "tmp"): os.makedirs(home + "/Maildir/" + d, exist_ok=True)
    if os.environ.get("PERF_COLOR") in ("0", "1"):
        put(home + "/.bashbbs-prefs", "color=%s\nreplymail=0\n" % os.environ["PERF_COLOR"])
    return root, home

P = r"\r\n> $"
# (label, keys, pattern, measured)
STEPS = [
    ("welcome", "", r"== Welcome, alice ==.*?" + P, True),
    ("main menu", "x", r"== BashBBS ==.*Q\) Log out" + P, True),
    ("boards home", "1", r"== Boards ==.*Q\) Back" + P, False),
    ("boards list", "1", r"== Public boards ==.*Q\) Back" + P, True),
    ("thread list (general)", "1", r"N\) New post.*" + P, True),
    ("open long thread (30 replies)", "1\r", r"Reply.*" + P, True),
    ("(back)", "q", r"N\) New post.*" + P, False),
    ("read single message", "2\r", r"Reply.*" + P, True),
    ("(back)", "q", r"N\) New post.*" + P, False),
    ("compose: Subject prompt", "n", r"Subject: $", True),
    ("compose: to Write text", "Test\r", r"Write text\. End with a single dot \(\.\)\.\r\n", True),
    ("(finish)", ".\r", r"\[Any key\] $", False),
    ("(any key)", " ", r"N\) New post.*" + P, False),
    ("(back)", "q", r"== Public boards ==.*" + P, False),
    ("(back)", "q", r"== Boards ==.*Q\) Back" + P, False),
    ("(back)", "q", r"== BashBBS ==.*Q\) Log out" + P, False),
    ("mail menu", "5", r"== Mail ==.*" + P, True),
    ("mail list (inbox, 20)", "1", r"== Inbox ==.*Number: open.*" + P, True),
    ("read mail", "1\r", r"R\) Reply.*" + P, True),
    ("(back)", "q", r"Number: open.*" + P, False),
    ("(back)", "q", r"== Mail ==.*" + P, False),
    ("(back)", "q", r"== BashBBS ==.*Q\) Log out" + P, False),
    ("files: area list", "8", r"== Files ==.*Q\) Back" + P, True),
    ("files: file list (15 files)", "1", r"== Files: .*? ==.*Q\) Back" + P, True),
    ("(back)", "q", r"== Files ==.*Q\) Back" + P, False),
    ("(back)", "q", r"== BashBBS ==.*Q\) Log out" + P, False),
    ("Fame & Glory menu", "4", r"== Fame & Glory ==.*Q\) Back" + P, True),
    ("(back)", "q", r"== BashBBS ==.*Q\) Log out" + P, False),
    ("News", "3", r"== (?:[Nn]ews)[^=]*==.*" + P, True),
    ("(back)", "q", r"== BashBBS ==.*Q\) Log out" + P, False),
]

def run(root, home, trace=None):
    env = {"PATH": os.environ["PATH"], "BBS_ROOT": root, "HOME": home, "USER": "bbs-alice",
           "BASHBBS_TEST_ID": "bbs-alice", "BBS_SENDMAIL": root + "/t/sendmail", "TERM": "xterm", "LC_ALL": "C.UTF-8"}
    if trace: env["PERF_TRACE"] = trace
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.execvpe("bash", ["bash", DRV], env)
    dec = codecs.getincrementaldecoder("utf-8")("replace")
    pend = ""; res = []; shots = {}
    for label, keys, pat, meas in STEPS:
        rx = re.compile(pat, re.S)
        t0 = time.time()
        if keys: os.write(fd, keys.encode())
        end = t0 + float(os.environ.get("PERF_TIMEOUT", "60"))
        while True:
            pstrip = ANSI.sub("", pend) if COL else pend
            m = rx.search(pstrip)
            if m:
                cut = m.end()
                if COL:   # map the end back to the raw text (escapes at the end belong to it)
                    removed = 0; cut = m.end()
                    for e in ANSI.finditer(pend):
                        if e.start() - removed <= m.end(): cut += e.end() - e.start(); removed += e.end() - e.start()
                        else: break
                t1 = time.time(); shots[label] = pend[:cut][-300:]
                if os.environ.get("PERF_DUMP") and not trace:
                    os.makedirs(os.environ["PERF_DUMP"], exist_ok=True)
                    open("%s/%02d-%s.raw" % (os.environ["PERF_DUMP"], len(res), re.sub(r"\W+", "_", label)), "w", encoding="utf-8", errors="replace").write(pend[:cut])
                pend = pend[cut:]; break
            if time.time() > end:
                os.kill(pid, 9); os.waitpid(pid, 0)
                raise SystemExit("TIMEOUT at step %r (%s); tail %r" % (label, keys, pend[-200:]))
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try: d = os.read(fd, 65536)
                except OSError: d = b""
                pend += dec.decode(d)
        res.append((label, t0, t1, meas))
    os.kill(pid, 9); os.waitpid(pid, 0); os.close(fd)
    return pid, res, shots

root, home = mkroot()
times = collections.defaultdict(list)
for i in range(RUNS):
    _, res, shots = run(root, home)
    for l, a, b, m in res:
        if m: times[l].append((b - a) * 1000)
    root, home = mkroot()   # fresh state each run (read marks, seen files)
json.dump(shots, open(OUT + "/shots.json", "w"))

# trace run
tr = OUT + "/xtrace.log"
mpid, res, _ = run(root, home, trace=tr)
BUILTINS = set(subprocess.run(["bash", "-c", "compgen -b"], capture_output=True, text=True).stdout.split()) | {"for","case","select","while","until","if","then","do","done","esac","[[", "((", "local", "declare", "printf", "echo", "read", "mapfile", "eval", "source", "."}
fnames = set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)", open(HERE + "/lib/menu.sh").read(), re.M))
for f in ("lib/news.sh", "lib/upload-common.sh", "lib/keys-common.sh", "lib/xfer.sh"):
    try: fnames |= set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)", open(HERE + "/" + f).read(), re.M))
    except OSError: pass
LR = re.compile(r"^\++(\d+) (\d+\.\d+) (\S+?):(\S*) (.*)$")
lines = []
for ln in open(tr, errors="replace"):
    m = LR.match(ln)
    if m: lines.append((int(m.group(1)), float(m.group(2)), m.group(3), m.group(4), m.group(5)))
stats = {}
for l, a, b, meas in res:
    if not meas: continue
    win = [x for x in lines if a - 0.0005 <= x[1] <= b + 0.0005]
    pids = {x[0] for x in win}
    first = collections.Counter(); where = collections.Counter(); ex = 0
    for pid, ts, src, fn, cmd in win:
        w = cmd.split()[0] if cmd.split() else ""
        if not w or "=" in w.split("[")[0] or w in BUILTINS or w in fnames or w in ("{", "}", "(", ")"): continue
        if w.startswith("'") or w.startswith('"'): continue
        ex += 1; first[w] += 1; where["%s:%s" % (src, fn and ts and cmd and "")] += 0
    wc = collections.Counter()
    for pid, ts, src, fn, cmd in win:
        w = cmd.split()[0] if cmd.split() else ""
        if not w or "=" in w.split("[")[0] or w in BUILTINS or w in fnames or w.startswith(("'", '"', "{", "}")): continue
        wc[src.split(":")[0] + ":" + src.split(":")[1] if False else (src + " " + w)] += 1
    stats[l] = dict(forks=len(pids - {mpid}), execs=ex, top=first.most_common(5), where=wc.most_common(6))
rows = []
for l, a, b, m in res:
    if m:
        s = stats[l]
        rows.append(dict(screen=l, median_ms=round(statistics.median(times[l])), min_ms=round(min(times[l])), max_ms=round(max(times[l])), **s))
json.dump(rows, open(OUT + "/result.json", "w"), indent=1)
print("%-32s %7s %6s %6s  %s" % ("screen", "med ms", "forks", "execs", "top commands"))
for r in rows:
    print("%-32s %7d %6d %6d  %s" % (r["screen"], r["median_ms"], r["forks"], r["execs"], ", ".join("%s x%d" % t for t in r["top"])))
    print("      at: " + "; ".join("%s x%d" % t for t in r["where"][:4]))
PYEOF
