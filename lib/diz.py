#!/usr/bin/env python3
"""Prints the FILE_ID.DIZ of an archive given on stdin: diz.py zip|lha
Or cleans description text given on stdin: diz.py clean <max lines>

bbs-upload runs this as nobody, with the archive already open as stdin, so it can
read that one file and nothing else in the upload area. Nothing is written to disk:
only the one entry is read, cut at 1 kB whatever size the archive claims, and sent
to stdout.

Only an entry named exactly FILE_ID.DIZ in the root of the archive counts, in any
case. Several such entries count as none. No check sums are tested, because that
would mean unpacking everything.

Exit status: 0 the archive opens (the output may be empty), 3 it does not open.
Anything else means nothing is known, and the upload is not held against it.

The sorter cleans again with "clean" as root, because the output of a process that
has just read a hostile archive is not to be trusted.
"""
import os
import re
import subprocess
import sys
import unicodedata
import zipfile

LIMIT = 1024
MAX_LINES = 10
MAX_COLS = 60
BROKEN = 3
DROP = ("Cc", "Cf", "Zl", "Zp")  # control and format characters, line separators
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b.")


def from_zip():
    try:
        archive = zipfile.ZipFile(sys.stdin.buffer)
    except zipfile.BadZipFile:
        sys.exit(BROKEN)
    entries = [e for e in archive.infolist() if e.filename.lower() == "file_id.diz"]
    if len(entries) != 1:
        return b""
    try:
        with archive.open(entries[0]) as entry:
            return entry.read(LIMIT + 1)[:LIMIT]
    except Exception:  # encrypted, unknown method, damaged data: no description
        return b""


def lha(args, limit):
    """Runs lha on the same open file, from its start, and returns its output."""
    os.lseek(0, 0, os.SEEK_SET)
    run = subprocess.Popen(["lha"] + args, stdin=0, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
    try:
        out = run.stdout.read(limit)
    finally:
        run.kill()
        run.wait()
    return out


def from_lha():
    # lha selects by the name as it lists it and is picky about case, so list first.
    # A whole-line match on the name column leaves out sub directories and the
    # "name -> target" form of a symbolic link.
    lines = lha(["l", "-"], 4 * 1024 * 1024).decode("latin-1").split("\n")
    head = next((i for i, l in enumerate(lines) if l.rstrip().endswith("NAME")), None)
    if head is None or head + 1 >= len(lines):
        sys.exit(BROKEN)
    # The heading is not aligned with the names, the dashes below it are.
    col = lines[head + 1].rindex(" ") + 1
    rows = []
    for line in lines[head + 2:]:
        if line.startswith("-----"):
            break
        rows.append(line)
    if not rows:
        sys.exit(BROKEN)
    names = [r[col:] for r in rows if r[col:].lower() == "file_id.diz"]
    if len(names) != 1:
        return b""
    return lha(["pq", "-", names[0].encode("latin-1")], LIMIT)


def tidy(raw, max_lines=MAX_LINES):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("cp437")
    text = ANSI.sub("", text).replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for line in text.split("\n"):
        line = "".join(c for c in line if unicodedata.category(c) not in DROP)
        out.append(line.rstrip()[:MAX_COLS])
    while out and not out[0]:
        out.pop(0)
    out = out[:max_lines]
    while out and not out[-1]:
        out.pop()
    return "\n".join(out)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "clean" and sys.argv[2].isdigit():
        text = tidy(sys.stdin.buffer.read(4 * LIMIT), int(sys.argv[2]))
    elif len(sys.argv) == 2 and sys.argv[1] == "zip":
        text = tidy(from_zip())
    elif len(sys.argv) == 2 and sys.argv[1] == "lha":
        text = tidy(from_lha())
    else:
        return 2
    if text:
        sys.stdout.buffer.write(text.encode("utf-8") + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
