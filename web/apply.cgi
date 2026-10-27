#!/usr/bin/env python3
# Application form for BashBBS. Runs under lighttpd as www-data.
# It only writes one file into applications/incoming. It never creates
# accounts; the sysop does that with bbs-approve.
import os
import re
import sys
import time
import urllib.parse
import uuid
from html import escape

APP_DIR = "/srv/bashbbs/applications/incoming"
USERS = "/srv/bashbbs/users"
MAX_BODY = 4096
NAME_RE = re.compile(r"^[a-z][a-z0-9]{2,15}$")
KEY_TYPES = {"ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
             "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com"}
KEY_BODY_RE = re.compile(r"^[A-Za-z0-9+/=]+$")


def page(status, text):
    print(f"Status: {status}")
    print("Content-Type: text/html; charset=utf-8")
    print()
    print("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>")
    print("<title>BashBBS application</title>")
    print(f"<p>{escape(text)}</p>")
    print("<p><a href='/'>Back</a></p>")


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

    name = field(form, "name", 16)
    key = field(form, "key", 2048)
    note = field(form, "note", 300)

    if not NAME_RE.match(name):
        return page("400 Bad Request",
                    "Name: 3-16 characters, lowercase letters and digits, starting with a letter.")
    if os.path.exists(os.path.join(USERS, name)):
        return page("409 Conflict", "That name is taken or was used before.")

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
            f.write(f"name={name}\nkey={parts[0]} {parts[1]}\nnote={note}\n")
        os.rename(tmp, final)
    except OSError:
        return page("500 Internal Server Error",
                    "Could not save the application. Try again later.")

    page("200 OK",
         "Thanks. Your application is in the queue. The sysop reviews applications by hand.")


if __name__ == "__main__":
    main()
