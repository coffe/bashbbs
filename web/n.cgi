#!/usr/bin/env python3
# Short news links for QR codes. Runs under lighttpd as www-data.
#
#   GET /n.cgi/<id>   302 to the Link: of the news article whose Article-Id starts
#                     with <id> (8 to 64 lower-case hex), 404 otherwise.
#
# The lookup goes through state/news-index.tsv (id, category, epoch, title, path, ...),
# the file the reader uses, so an article that retention dropped is gone here too.
# Only files under boards/news/ are opened, never symlinks; the Link is checked with
# the same rule bbs-publish uses. Nothing is written. A prefix that matches more than
# one article is refused rather than guessed.
# Test hook: BASHBBS_TEST=1 lets BBS_ROOT move the tree.
import os
import re
import sys

ROOT = "/srv/bashbbs"
if os.environ.get("BASHBBS_TEST") == "1":
    ROOT = os.environ.get("BBS_ROOT", ROOT)
NEWS = os.path.join(ROOT, "boards", "news") + os.sep
ID = re.compile(r"[0-9a-f]{8,64}")
LINK = re.compile(r"https?://\S+")


def respond(status, body, extra=""):
    sys.stdout.write(f"Status: {status}\r\nContent-Type: text/plain; charset=utf-8\r\n"
                     f"Cache-Control: no-store\r\n{extra}\r\n{body}\n")


def find(prefix):
    try:
        with open(os.path.join(ROOT, "state", "news-index.tsv"), encoding="utf-8", errors="replace") as f:
            hits = [row.split("\t")[4] for row in f
                    if row.startswith(prefix) and row.count("\t") >= 4]
    except OSError:
        return None
    return hits[0] if len(set(hits)) == 1 else None


def link_of(path):
    if not path.startswith(NEWS) or ".." in path.split(os.sep) or os.path.islink(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line:
                    break
                if line.startswith("Link: "):
                    link = line[6:]
                    return link if LINK.fullmatch(link) and len(link.encode()) <= 300 else None
    except OSError:
        pass
    return None


def main():
    prefix = os.environ.get("PATH_INFO", "").lstrip("/")
    if os.environ.get("REQUEST_METHOD", "GET") not in ("GET", "HEAD"):
        return respond("405 Method Not Allowed", "Only GET.")
    path = find(prefix) if ID.fullmatch(prefix) else None
    link = link_of(path) if path else None
    if not link:
        return respond("404 Not Found", "No such news link. It may have expired.")
    respond("302 Found", link, f"Location: {link}\r\n")


main()
