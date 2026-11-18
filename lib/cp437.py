#!/usr/bin/env python3
"""Runs a program on its own pty and speaks CP437 to the caller.

SyncTERM and other classic BBS clients show every byte as a CP437 glyph, so the
BBS's UTF-8 turns into three junk characters per block or å. Output from the
program is decoded as UTF-8 and sent as CP437; a character CP437 lacks becomes its
closest ASCII form (é is in CP437, ő becomes o, – becomes -), else ?. Keys from the
caller are decoded as CP437 and passed on as UTF-8, so å typed in SyncTERM is
stored as å. Line editing (backspace, Enter) stays with the inner pty.

Usage: cp437.py <program> [args...]   Exit status: the program's.
Self-check: cp437.py --selftest
"""
import codecs
import fcntl
import os
import pty
import select
import signal
import sys
import termios
import tty
import unicodedata

# Common characters with no CP437 glyph and no NFKD base letter.
_MAP = {"–": "-", "—": "-", "‘": "'", "’": "'", "‚": ",", "“": '"', "”": '"',
        "„": '"', "…": "...", "•": "*", "€": "EUR", "™": "TM", "©": "(c)",
        "®": "(R)", "\u00a0": " ", "\u200b": "", "\ufeff": ""}


def _fallback(err):
    out = []
    for ch in err.object[err.start:err.end]:
        if ch in _MAP:
            out.append(_MAP[ch])
            continue
        base = "".join(c for c in unicodedata.normalize("NFKD", ch) if not unicodedata.combining(c))
        try:
            base.encode("cp437")
            out.append(base or "?")
        except UnicodeEncodeError:
            out.append("?")
    return "".join(out), err.end


codecs.register_error("bbs_cp437", _fallback)


def to_cp437(dec, data, final=False):
    return dec.decode(data, final).encode("cp437", "bbs_cp437")


def _copy_size(fd_from, fd_to):
    try:
        fcntl.ioctl(fd_to, termios.TIOCSWINSZ, fcntl.ioctl(fd_from, termios.TIOCGWINSZ, b"\0" * 8))
    except OSError:
        pass


def main(argv):
    pid, master = pty.fork()
    if pid == 0:
        os.environ["BBS_CHARSET"] = "cp437"
        os.execvp(argv[0], argv)
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    _copy_size(stdin, master)
    signal.signal(signal.SIGWINCH, lambda *_: _copy_size(stdin, master))
    saved = termios.tcgetattr(stdin)
    tty.setraw(stdin)
    dec = codecs.getincrementaldecoder("utf-8")("replace")
    try:
        while True:
            try:
                r, _, _ = select.select([master, stdin], [], [])
            except InterruptedError:
                continue
            if master in r:
                try:
                    data = os.read(master, 4096)
                except OSError:  # EIO: the program closed the pty
                    data = b""
                if not data:
                    break
                os.write(stdout, to_cp437(dec, data))
            if stdin in r:
                data = os.read(stdin, 1024)
                if not data:  # the caller hung up
                    os.kill(pid, signal.SIGHUP)
                    break
                os.write(master, data.decode("cp437").encode("utf-8"))
    finally:
        termios.tcsetattr(stdin, termios.TCSADRAIN, saved)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status) & 0xFF


def _selftest():
    d = codecs.getincrementaldecoder("utf-8")("replace")
    assert to_cp437(d, "█å".encode()) == b"\xdb\x86"
    # A character split between two reads is still one glyph.
    raw = "▀Ä".encode()
    assert to_cp437(d, raw[:2]) + to_cp437(d, raw[2:]) == b"\xdf\x8e"
    assert to_cp437(d, "ő–’…€".encode()) == b"o-'...EUR"
    assert to_cp437(d, "\x1b[1;35m漢".encode()) == b"\x1b[1;35m?"
    assert b"\x86\x84\x94\x1b[A\x7f".decode("cp437").encode() == "åäö\x1b[A\x7f".encode()
    print("cp437 selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        _selftest()
    elif len(sys.argv) < 2 or not os.isatty(0):
        sys.exit("usage: cp437.py <program> [args...] (stdin must be a terminal)")
    else:
        sys.exit(main(sys.argv[1:]))
