#!/usr/bin/env python3
"""Export a BBS user's mail (Inbox, Sent, Archive; never Trash) as threaded text in a zip.

Usage: mailexport.py <out.zip> [--user NAME] [--date YYYYMMDD]   |   mailexport.py --test
Runs as the user. The zip holds mail-DATE.txt (UTF-8, LF) and mail-DATE.cp437.txt (CP437, CRLF).
"""
import datetime, email, email.policy, email.utils, os, re, sys, time, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wrap      # noqa: E402
import cp437     # noqa: E402  (registers the bbs_cp437 error handler)

W = 76
CAP = 3_500_000
FOLDERS = (("Inbox", ""), ("Sent", ".Sent"), ("Archive", ".Archive"))
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
PREFIX = re.compile(r"^\s*(re|fwd?|aw|sv)\s*:\s*", re.I)
LOGO = """       _______                      _______                 _
       ./       \\.                  ./o      \\.      _______ (_)
       !    _    |\\                /!°   _    |    _(o      )___
       °.  (_)   | \\           °  / °   (_)   |  _(·            )_
       · °    ._ |  ·        O   · o:      .  | (_________________)
       .   \\__|./·  ___     .__°____|_. \\____/   ___     .__ ______
       |    |/  \\  /o  \\.---|  \\)     |  |/  \\  /o  \\.---|  \\)     |
       |    (____)/ _   |_° \\   \\   ._|  .\\__/¡/ _   |_° \\   \\   ._|
       |    |    | (_) _| |  \\   ·  |·   |    | (_) _| |  \\   ·  | ·
       |    |    |    /   |         |    |    |    /o  |         |
       |    |    |   /°   |\\    |   |    |    |   /°   |\\    |   |
       |____|____|________| \\___|\\__|____|____|________| \\___|\\__|
                                                 Mortimer Twang""".split("\n")


def clean(s):
    return CTRL.sub("", s.replace("\r", ""))


def hdr(msg, name):
    try:
        return clean(" ".join(str(msg.get(name, "") or "").split()))
    except Exception:       # a broken header must not stop the export
        return ""


def norm_subject(s):
    s = clean(s)
    while PREFIX.match(s):
        s = PREFIX.sub("", s, 1)
    return " ".join(s.casefold().split())


def party(addr):
    """Local part for user@host, the whole lowercased address for a fido one (Name@21:3/268)."""
    a = email.utils.parseaddr(addr)[1] or addr.strip()
    a = a.lower()
    return a if re.search(r"\d+:\d+/\d+", a) else a.split("@")[0]


def ids(s):
    return re.findall(r"<[^<>\s]+>", s)


def load(home):
    msgs, seen = [], set()
    for folder, sub in FOLDERS:
        for kind in ("cur", "new"):
            d = os.path.join(home, "Maildir", sub, kind) if sub else os.path.join(home, "Maildir", kind)
            try:
                names = sorted(os.listdir(d))
            except OSError:
                continue
            for n in names:
                p = os.path.join(d, n)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                with open(p, "rb") as f:
                    raw = f.read(1 << 20)
                # the BBS writes raw UTF-8 headers and bodies; parsing bytes would garble them
                m = email.message_from_string(raw.decode("utf-8", "replace"), policy=email.policy.compat32)
                mid = hdr(m, "Message-ID")
                if mid and mid in seen:
                    continue
                seen.add(mid)
                try:
                    if m.is_multipart():
                        body = ""
                    elif m.get("Content-Transfer-Encoding", "").strip().lower() in ("base64", "quoted-printable"):
                        body = (m.get_payload(decode=True) or b"").decode(m.get_content_charset() or "utf-8", "replace")
                    else:
                        body = m.get_payload()
                except Exception:
                    body = ""
                try:
                    ts = email.utils.parsedate_to_datetime(hdr(m, "Date")).timestamp()
                except Exception:
                    ts = 0.0
                subj = hdr(m, "Subject")
                msgs.append(dict(
                    folder=folder, name=n.split(":")[0], mid=mid, ts=ts, frm=hdr(m, "From"), to=hdr(m, "To"),
                    date=hdr(m, "Date"), subj=subj, body=clean(body).strip("\n"),
                    fid=hdr(m, "X-Fido-Msgid"),
                    refs=ids(hdr(m, "In-Reply-To") + " " + hdr(m, "References")),
                    freply=hdr(m, "X-Fido-Reply"), ns=norm_subject(subj),
                    pair=frozenset((party(hdr(m, "From")), party(hdr(m, "To"))))))
    return msgs


def threads(msgs):
    parent = list(range(len(msgs)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        parent[find(i)] = find(j)

    key = {}
    for i, m in enumerate(msgs):
        for k in (m["mid"], m["fid"]):
            if k:
                key.setdefault(k, i)
    for i, m in enumerate(msgs):
        for r in m["refs"] + ([m["freply"]] if m["freply"] else []):
            if r in key:
                union(i, key[r])
    fall = {}
    for i, m in enumerate(msgs):
        if m["ns"]:
            union(i, fall.setdefault((m["ns"], m["pair"]), i))
    groups = {}
    for i in range(len(msgs)):
        groups.setdefault(find(i), []).append(msgs[i])
    out = [sorted(g, key=lambda m: m["ts"]) for g in groups.values()]
    return sorted(out, key=lambda g: g[0]["ts"])


def render(threads_, user, day):
    def head(n_t, n_m):
        lines = ["=" * W, "      I N C O M I N G   S I G N A L   //   M A I L   A R C H I V E", "=" * W]
        lines += LOGO + ["", " " * 31 + "~ PiEWPiEW ~", "", "B U L L E T I N   B O A R D   S Y S T E M".center(W).rstrip(), "-" * W,
                         "  USER   : " + user, "  EXPORT : %s-%s-%s UTC" % (day[:4], day[4:6], day[6:]),
                         "  CONTENT: %d threads, %d messages" % (n_t, n_m), "=" * W, ""]
        return "\n".join(lines) + "\n"

    parts, used, nm = [], 0, 0
    body_len = 0
    foot = "\n" + "=" * W + "\n" + "~ PiEWPiEW ~  Drop by. Say hello. Leave a little trace.".center(W).rstrip() + "\n" + "=" * W + "\n"
    cut = False
    for t in threads_:
        who = sorted({x for m in t for x in (m["frm"], m["to"]) if x})
        lines = ["=" * W, "THREAD : " + (t[0]["subj"] or "(no subject)"),
                 "WITH   : " + ", ".join(who), "COUNT  : %d" % len(t), "-" * W]
        lines = [l2 for l in lines for l2 in wrap.wrap_keep_lines(l, W)]
        for k, m in enumerate(t):
            if k:
                lines.append("-" * W)
            for l in ("From: " + m["frm"], "To: " + m["to"], "Date: %s  [%s]" % (m["date"], m["folder"]),
                      "Subject: " + m["subj"]):
                lines += wrap.wrap_keep_lines(l, W)
            lines.append("")
            lines += wrap.wrap_keep_lines(m["body"], W) if m["body"] else []
        chunk = "\n".join(lines) + "\n\n"
        if used + len(chunk.encode("utf-8")) > CAP:
            cut = True
            break
        parts.append(chunk)
        used += len(chunk.encode("utf-8"))
        nm += len(t)
    txt = head(len(parts), nm) + "".join(parts)
    if cut:
        txt += "[Truncated: size limit reached, the newest threads are not included.]\n"
    return txt + foot


def export(home, out, user, day, thread=None):
    ts = threads(load(home))
    if thread:  # Maildir names change only after the ':' (flags)
        ts = [t for t in ts if any(m["name"] == thread.split(":")[0] for m in t)]
        if not ts:
            raise ValueError("no message %s" % thread)
    txt = render(ts, user, day)
    cp = txt.replace("\n", "\r\n").encode("cp437", "bbs_cp437")
    with open(out, "xb") as fh, zipfile.ZipFile(fh, "w", zipfile.ZIP_DEFLATED) as z:  # x: never overwrite
        z.writestr("mail-%s.txt" % day, txt.encode("utf-8"))
        z.writestr("mail-%s.cp437.txt" % day, cp)


def selftest():
    import tempfile
    with tempfile.TemporaryDirectory() as home:
        def put(folder, name, **h):
            d = os.path.join(home, "Maildir", folder, "cur")
            os.makedirs(d, exist_ok=True)
            body = h.pop("body", "hello \x1b[31mred\x1b[0m")
            with open(os.path.join(d, name), "w") as f:
                f.write("".join("%s: %s\n" % (k.replace("_", "-"), v) for k, v in h.items()) + "\n" + body + "\n")
        a, b = "alice@h", "bob@h"
        put("", "1", Message_ID="<1@h>", Date="Mon, 02 Nov 2026 10:00:00 +0000", From=b, To=a, Subject="Plans", body="Smörgåsbord")
        put(".Sent", "2", Message_ID="<2@h>", In_Reply_To="<1@h>", Date="Mon, 02 Nov 2026 11:00:00 +0000", From=a, To=b, Subject="Re: Plans")
        put(".Archive", "3", Message_ID="<3@h>", In_Reply_To="<2@h>", Date="Mon, 02 Nov 2026 12:00:00 +0000", From=b, To=a, Subject="Re: Re: Plans")
        put(".Archive", "3b", Message_ID="<3@h>", Date="Mon, 02 Nov 2026 12:00:00 +0000", From=b, To=a, Subject="dupe")
        put(".Sent", "4", Message_ID="<4@h>", Date="Tue, 03 Nov 2026 09:00:00 +0000", From=a, To=b, Subject="Lunch")
        put("", "5", Message_ID="<5@h>", Date="Tue, 03 Nov 2026 10:00:00 +0000", From=b, To=a, Subject="AW: lunch")
        put("", "6", Message_ID="<6@fido>", X_Fido_Msgid="21:3/268 abc", Date="Wed, 04 Nov 2026 10:00:00 +0000", From="Sue@21:3/100", To=a, Subject="Net")
        put(".Sent", "7", Message_ID="<7@h>", X_Fido_Reply="21:3/268 abc", Date="Wed, 04 Nov 2026 11:00:00 +0000", From=a, To="Sue@21:3/100", Subject="Other topic")
        put(".Trash", "8", Message_ID="<8@h>", Date="Thu, 05 Nov 2026 10:00:00 +0000", From=b, To=a, Subject="Trashed")
        t = threads(load(home))
        assert [len(x) for x in t] == [3, 2, 2], [len(x) for x in t]
        assert [m["mid"] for m in t[0]] == ["<1@h>", "<2@h>", "<3@h>"]
        assert [m["folder"] for m in t[0]] == ["Inbox", "Sent", "Archive"]
        out = os.path.join(home, "o.zip")
        export(home, out, "alice", "20261121")
        with zipfile.ZipFile(out) as z:
            assert sorted(z.namelist()) == ["mail-20261121.cp437.txt", "mail-20261121.txt"]
            u = z.read("mail-20261121.txt").decode("utf-8")
            c = z.read("mail-20261121.cp437.txt").decode("cp437")
        assert "Trashed" not in u and "\x1b" not in u and "3 threads, 7 messages" in u and "Smörgåsbord" in u
        assert "\r\n" in c and "\r\n" not in u and "[Sent]" in u
        assert all(len(l) <= W for l in u.split("\n") if not l.startswith("      I N"))
        one = os.path.join(home, "one.zip")
        export(home, one, "alice", "20261121", thread="2:2,S")
        with zipfile.ZipFile(one) as z:
            u = z.read("mail-20261121.txt").decode("utf-8")
        assert "1 threads, 3 messages" in u and "Plans" in u, u[-600:]
        try:
            export(home, os.path.join(home, "none.zip"), "alice", "20261121", thread="nope")
            raise AssertionError("unknown message exported")
        except ValueError:
            pass
    print("mailexport selftest ok")


def main(argv):
    if argv[1:] == ["--test"]:
        return selftest()
    args, thread, user, day = [], None, os.environ.get("USER", ""), time.strftime("%Y%m%d", time.gmtime())
    it = iter(argv[1:])
    for a in it:
        if a == "--user":
            user = next(it, "")
        elif a == "--thread":
            thread = next(it, "")
        elif a == "--date":
            day = next(it, "")
        else:
            args.append(a)
    if len(args) != 1 or not re.fullmatch(r"\d{8}", day):
        sys.exit("usage: mailexport.py <out.zip> [--user NAME] [--date YYYYMMDD] [--thread MAILDIR-NAME]")
    try:
        export(os.path.expanduser("~"), args[0], clean(user), day, thread)
    except Exception as e:
        sys.exit("mailexport: %s" % e)


if __name__ == "__main__":
    main(sys.argv)
