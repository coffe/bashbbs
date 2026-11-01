#!/usr/bin/env python3
# Application form for BashBBS. Runs under lighttpd as www-data.
# It only writes one file into applications/incoming. It never creates
# accounts; the sysop does that with bbs-approve.
import grp
import os
import pwd
import re
import sys
import time
import urllib.parse
import uuid
from html import escape

APP_DIR = "/srv/bashbbs/applications/incoming"
USERS = "/srv/bashbbs/users"
MAX_BODY = 4096
NAME_RE = re.compile(r"^[a-z][a-z0-9]{2,8}$")
KEY_TYPES = {"ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
             "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com"}
KEY_BODY_RE = re.compile(r"^[A-Za-z0-9+/=]+$")
# Reserved short names (same file as bbs-alias). Test hook: BASHBBS_TEST=1 moves the paths.
RESERVED = "/usr/local/lib/bashbbs/reserved-names.conf"
if os.environ.get("BASHBBS_TEST") == "1":
    APP_DIR = os.environ.get("BBS_APP_DIR", APP_DIR)
    USERS = os.environ.get("BBS_USERS", USERS)
    RESERVED = os.environ.get("BBS_RESERVED", RESERVED)


def reserved(name):
    """True if the name is on the blocklist or already a system user or group.
    A missing list refuses everything (fail closed)."""
    try:
        with open(RESERVED, encoding="utf-8") as f:
            listed = {ln.split("#")[0].strip() for ln in f}
    except OSError:
        return True
    if name in listed:
        return True
    for lookup in (pwd.getpwnam, grp.getgrnam):
        try:
            lookup(name)
            return True
        except KeyError:
            pass
    return False


PAGE_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - piewpiew BBS</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<nav aria-label="Main"><div class="wrap"><a class="brand" href="/">piewpiew BBS</a><ul><li><a href="/#join">Join</a></li><li><a href="/#connect">Connect</a></li><li><a href="/devlog/">Devlog</a></li></ul></div></nav>
<main id="main" class="wrap">
"""
PAGE_FOOT = """</main>
<footer><div class="wrap"><p>Runs on a Raspberry Pi Zero W. The original one.</p></div></footer>
</body>
</html>"""


def page(status, text, name=None):
    """Print the response page. Errors get a way back to the form; success shows the
    login command. Everything that came from the request is escaped."""
    print(f"Status: {status}")
    print("Content-Type: text/html; charset=utf-8")
    print()
    ok = status.startswith("200")
    print(PAGE_HEAD.format(title="Application received" if ok else "Application not sent"))
    if ok:
        print("<h1 style='margin-top:2.5rem'>Thanks! Your application is in.</h1>")
        print(f"<div class='receipt'><p>{escape(text)}</p></div>")
        if name:
            print("<p>When you're approved, log in with:</p>")
            print(f"<pre class='cmd'>ssh -p 6464 {escape(name)}@bbs.piewpiew.se</pre>")
        print("<p><a href='/#connect'>What to expect on your first login</a> · <a href='/'>Front page</a></p>")
    else:
        print("<h1 style='margin-top:2.5rem'>Not sent yet</h1>")
        print(f"<div class='warn' role='alert'><p>{escape(text)}</p></div>")
        print("<p>Nothing was saved. Use your browser's back button to keep what you typed, "
              "or <a href='/#join'>go back to the form</a>.</p>")
    print(PAGE_FOOT)


def read_form():
    try:
        length = int(os.environ.get("CONTENT_LENGTH") or 0)
    except ValueError:
        return None
    if length <= 0 or length > MAX_BODY:
        return None
    data = sys.stdin.buffer.read(length).decode("utf-8", "replace")
    return urllib.parse.parse_qs(data, keep_blank_values=True, max_num_fields=10)


def field(form, name, limit):
    value = form.get(name, [""])[0]
    # Keep printable characters only: no newlines, no terminal escapes.
    kept = "".join(ch for ch in value if ch.isprintable())
    return kept.strip()[:limit]


def main():
    if os.environ.get("REQUEST_METHOD") != "POST":
        return page("405 Method Not Allowed", "Use the form on the front page.")

    form = read_form()
    if form is None:
        return page("400 Bad Request", "The form is empty or too large.")

    name = field(form, "name", 9)
    key = field(form, "key", 2048)
    note = field(form, "note", 300)
    contact = field(form, "contact", 100)

    if not NAME_RE.match(name):
        return page("400 Bad Request",
                    "Name: 3-9 characters, lowercase letters and digits, starting with a letter.")
    if reserved(name):
        return page("409 Conflict", "That name is reserved. Pick another one.")
    if os.path.exists(os.path.join(USERS, name)):
        return page("409 Conflict", "That name is taken or was used before.")

    if "PRIVATE KEY" in key:
        return page("400 Bad Request",
                    "That was your private key. Nothing was saved. Keep that file to yourself "
                    "and paste the line from the file that ends in .pub instead.")

    parts = key.split()
    if len(parts) < 2 or parts[0] not in KEY_TYPES or not KEY_BODY_RE.match(parts[1]):
        return page("400 Bad Request",
                    "Paste one public key line, the one from your .pub file.")

    ident = f"{int(time.time())}-{uuid.uuid4()}"
    tmp = os.path.join(APP_DIR, ".tmp-" + ident)
    final = os.path.join(APP_DIR, ident + ".app")
    os.umask(0o077)
    try:
        with open(tmp, "x", encoding="utf-8") as f:
            f.write(f"name={name}\nkey={parts[0]} {parts[1]}\nnote={note}\ncontact={contact}\n")
        os.rename(tmp, final)
    except OSError:
        return page("500 Internal Server Error",
                    "Could not save the application. Try again later.")

    page("200 OK",
         "A human (the sysop) reads every application by hand, usually within a day or so.",
         name=name)


if __name__ == "__main__":
    main()
