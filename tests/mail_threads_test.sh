#!/bin/bash
# Threading comparison: 40 seeded random Maildir fixtures; the awk mail_scan grouping must equal
# mailexport.threads() (groups that hold an Inbox message, as sets of file names without ":flags").
# Awk: AWK=mawk by default. By default lib/menu.sh is sourced (BASHBBS_TEST=1) and mail_scan called;
# MAILSCAN_AWK=<file> runs that awk file directly (-v mode=thread -v sent=<home>/Maildir/.Sent/).
# Usage: tests/mail_threads_test.sh [logfile]      Env: SEEDS=40 SEED0=1 AWK=mawk MAILSCAN_AWK=...
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-${TMPDIR:-/tmp}}
log=${1:-$scratch/mail_threads_test.log}
: > "$log"
[[ $(id -u) -ne 0 ]] || { echo "Run as a normal user, not root." >&2; exit 2; }
export AWK=${AWK:-mawk} HERE=$here SEEDS=${SEEDS:-40} SEED0=${SEED0:-1} MAILSCAN_AWK=${MAILSCAN_AWK:-}
command -v "$AWK" >/dev/null || { echo "no $AWK" >&2; exit 2; }
root=$(mktemp -d "$scratch/mthr.XXXXXX"); trap 'rm -rf "$root"' EXIT
export ROOT=$root
python3 -I - "$here/lib" >>"$log" 2>&1 <<'PY'
import os, random, subprocess, sys, shutil
sys.path.insert(0, sys.argv[1])
import mailexport as mx

ROOT = os.environ["ROOT"]; AWK = os.environ["AWK"]; HERE = os.environ["HERE"]
AWKF = os.environ.get("MAILSCAN_AWK", "")
US = "\x1f"
ME = "alice@bbs.localdomain"
OTHERS = ["bob@bbs.localdomain", "carol@bbs.localdomain", "Dave <dave@example.org>", "Jane Doe@21:3/100"]
SUBJ = ["Plans", "Middag?", "Zebra topic", "Hello", "Status report", "Fido echo", "Ärende åäö"]
PFX = ["", "", "Re: ", "RE: ", "SV: ", "Fwd: ", "Re: Re: ", "AW: ", "sv:"]

def build(seed, home):
    r = random.Random(seed)
    mb = os.path.join(home, "Maildir")
    for d in ("cur", "new", ".Sent/cur", ".Sent/new"):
        os.makedirs(os.path.join(mb, d))
    files = []; cnt = [0]; t = [1700000000 + r.randrange(10**6)]
    def put(sent, lines, body=True, crlf=False):
        cnt[0] += 1
        flags = r.choice([":2,S", ":2,SR", "", ":2,"])
        base = ("%d.M%dP1.host" % (t[0], cnt[0])) if r.random() < .6 else "msg%d" % cnt[0]
        kind = "new" if (not sent and r.random() < .25) or (sent and r.random() < .1) else "cur"
        if kind == "new": flags = ""
        d = (".Sent/" if sent else "") + kind
        txt = "\n".join(lines) + ("\n\nbody %d\n" % cnt[0] if body else "\n")
        if crlf: txt = txt.replace("\n", "\r\n")
        p = os.path.join(mb, d, base + flags)
        with open(p, "w", newline="") as f: f.write(txt)
        files.append((p, d, lines))
        return p
    ids = []
    for c in range(r.randrange(2, 7)):
        subj = r.choice(SUBJ) + (" %d" % r.randrange(3) if r.random() < .5 else "")
        other = r.choice(OTHERS); fido = "@21:" in other
        prev = []   # message ids in conversation
        n = r.randrange(1, 5)
        for k in range(n):
            sent = r.random() < .35 and k > 0
            t[0] += r.randrange(60, 5000)
            mid = "<c%dm%d@h>" % (c + seed * 100, k) if r.random() > .12 else ""
            fid = ""
            frm, to = (ME, other) if sent else (other, ME)
            if fido and not sent: to = "alice"
            if fido and r.random() < .7:
                fid = "21:3/100 %08x" % r.randrange(2**32)
                mid = mid if r.random() < .3 else ""
            h = []
            if mid: h.append("Message-ID: " + mid)
            h.append("From: " + frm); h.append("To: " + to)
            s = (r.choice(PFX) if k else "") + subj
            if r.random() < .1: h.append("Subject: " + s[:5] + "\n " + s[5:])     # folded
            else: h.append("Subject: " + s)
            h.append("Date: %s, 0%d Nov 2026 1%d:00:00 +0%d00" % (r.choice(["Mon", "Tue", "Wed"]), r.randrange(1, 9), r.randrange(10), r.randrange(3)))
            if fid: h.append("X-Fido-Msgid: " + fid)
            if prev and r.random() < .75:
                pm = prev[-1] if r.random() < .8 else r.choice(prev)
                kind = r.random()
                if pm[0] and kind < .6:
                    h.append("In-Reply-To: " + pm[0])
                elif pm[0] and kind < .75:
                    h.append("In-Reply-To: <broken%d@nowhere>\nReferences: <x@y>\n %s" % (r.randrange(99), pm[0]))   # folded refs
                elif pm[1]:
                    h.append("X-Fido-Reply: " + pm[1])
                elif pm[0]:
                    h.append("References: " + pm[0])
            if r.random() < .06: h.append("In-Reply-To: <self%d@h>" % c)      # (circular below)
            p = put(sent, h, crlf=r.random() < .1)
            prev.append((mid, fid, p, h))
            if r.random() < .08 and mid:                        # duplicate Message-ID, other file
                put(sent, h)
        if r.random() < .3 and len(prev) >= 2 and prev[0][0] and prev[-1][0]:   # circular In-Reply-To
            for (m, f, p, h), tgt in ((prev[0], prev[-1][0]), (prev[-1], prev[0][0])):
                txt = open(p, newline="").read()
                if "In-Reply-To:" not in txt:
                    open(p, "w", newline="").write(txt.replace("From:", "In-Reply-To: %s\nFrom:" % tgt, 1))
    if r.random() < .8: open(os.path.join(mb, "cur", "empty%d" % seed), "w").close()    # empty file
    if r.random() < .5:                                                                  # same subject, different party
        put(False, ["Message-ID: <lone%d@h>" % seed, "From: Eve <eve@example.org>", "To: " + ME, "Subject: Re: Plans",
                    "Date: Tue, 03 Nov 2026 10:00:00 +0000"])
    return mb

def py_groups(home):
    out = set()
    for g in mx.threads(mx.load(home)):
        if any(m["folder"] == "Inbox" for m in g):
            out.add(frozenset(m["name"] for m in g))
    return out

def awk_groups(home):
    mb = os.path.join(home, "Maildir")
    fl = []
    for sub, kinds in (("", ("cur", "new")), (".Sent", ("cur", "new"))):
        for k in kinds:
            d = os.path.join(mb, sub, k)
            fl += sorted(os.path.join(d, n) for n in os.listdir(d))
    fl.sort(key=lambda p: 0)  # keep order (stable)
    sentdir = os.path.join(mb, ".Sent") + "/"
    if AWKF:
        cmd = [AWK, "-v", "mode=thread", "-v", "sent=" + sentdir, "-v", "me=", "-f", AWKF] + fl
        env = dict(os.environ, LC_ALL="C")
    else:
        script = 'source "$HERE/lib/menu.sh"; FL=(); mail_files FL "$HOME/Maildir" cur new; mail_files FL "$HOME/Maildir/.Sent" cur new; mail_scan thread "${FL[@]}"'
        cmd = ["bash", "-c", script]
        env = dict(os.environ, HOME=home, BASHBBS_TEST="1", BASHBBS_TEST_ID="bbs-alice", BBS_ROOT=home, TERM="dumb", LC_ALL="C")
    res = subprocess.run(cmd, capture_output=True, text=True, env=env, errors="replace")
    if res.returncode: print("awk rc", res.returncode, res.stderr[:500])
    groups, cur, left, nt = set(), None, 0, 0
    for line in res.stdout.split("\n"):
        if not line: continue
        f = line.split(US)
        if f[0] == "T":
            if left: print("T count mismatch"); 
            cur = []; left = int(f[-1]); groups.add(None); groups.discard(None)
            groups_list.append(cur); nt += 1
        elif f[0] == "F":
            cur.append(os.path.basename(f[1]).split(":")[0]); left -= 1
    return {frozenset(g) for g in groups_list}, res

bad = 0
for seed in range(int(os.environ["SEED0"]), int(os.environ["SEED0"]) + int(os.environ["SEEDS"])):
    home = os.path.join(ROOT, "h%d" % seed)
    build(seed, home)
    groups_list = []
    try:
        a, res = awk_groups(home)
    except Exception as e:
        print("seed %d: awk run failed: %r" % (seed, e)); bad += 1; continue
    p = py_groups(home)
    if a != p:
        bad += 1
        print("MISMATCH seed %d (fixture kept: SEED0=%d SEEDS=1)" % (seed, seed))
        print("  only python:", sorted(sorted(g) for g in p - a))
        print("  only awk   :", sorted(sorted(g) for g in a - p))
    else:
        print("ok seed %d (%d threads)" % (seed, len(a)))
    shutil.rmtree(home)
print("seeds with mismatch:", bad)
sys.exit(1 if bad else 0)
PY
rc=$?
tail -n 3 "$log" | grep -q 'seeds with mismatch' && grep -E 'MISMATCH|only|rc|failed|Traceback|Error' "$log" | head -40
echo "mail_threads_test: $(grep -c '^ok seed' "$log") ok seeds, rc=$rc"
exit $rc
