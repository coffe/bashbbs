#!/usr/bin/env python3
"""Drive a command in a pty, expect-style: wait for text, then send keys.

    pty_drive.py --cols 40 --out FILE [--timeout 30] [--paste 'bytes']
                 [--step 'MARKER=>KEYS' ...] -- command args...

--paste is sent at once, before the command has printed anything (input that
arrived before the first screen). Each --step waits until MARKER has appeared in
the output, then sends KEYS (\\n, \\e, \\xNN are decoded). The marker is searched
only in output that came after the previous step, so "> " can be used again.
There is no fixed delay: a key is sent the moment its prompt text is visible.
All output goes to FILE. Exit 0 when every marker appeared and the command ended,
3 when a marker did not appear in time, 4 when the command did not end in time.
"""
import argparse
import codecs
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time


def decode(s):
    return codecs.decode(s, "unicode_escape").encode("latin-1")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--paste", default="")
    ap.add_argument("--step", action="append", default=[])
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))
    if a.paste:
        os.write(fd, decode(a.paste))

    steps = []
    for st in a.step:
        marker, _, keys = st.partition("=>")
        steps.append((decode(marker), decode(keys)))

    out = b""
    pending = b""      # output since the previous step
    deadline = time.time() + a.timeout
    status = 0
    eof = False
    while not eof:
        if time.time() > deadline:
            status = 3 if steps else 4
            break
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if not data:
                eof = True
            else:
                out += data
                pending += data
        while steps and steps[0][0] in pending:
            marker, keys = steps.pop(0)
            pending = pending.split(marker, 1)[1]
            os.write(fd, keys)
    if steps and status == 0:
        status = 3
    if status == 3:
        sys.stderr.write("pty_drive: marker not seen: %r\n" % steps[0][0])
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    with open(a.out, "wb") as f:
        f.write(out)
    return status


sys.exit(main())
