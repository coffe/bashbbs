#!/usr/bin/env python3
"""Wrap UTF-8 text to a visual width (terminal columns).

Usage: python3 wrap.py [--keep-lines] WIDTH < text > wrapped

Visual width: East Asian Wide/Fullwidth = 2, combining and other
zero-width characters = 0, everything else = 1. Words break at spaces; a
word longer than WIDTH is split hard between characters so no line is ever
wider than WIDTH. Combining marks always stay with their base character.
Consecutive non-empty input lines form one paragraph (they are re-flowed);
empty lines are kept as they are.

--keep-lines: every input line stays a line of its own, with its spacing.
Only a line wider than WIDTH is broken, at its spaces. Used where the
author's line breaks matter (board posts, mail).
"""
import re
import sys
import unicodedata

MIN_WIDTH = 10


def cwidth(ch):
    """Visual width of one character."""
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf", "Cc"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def vwidth(s):
    """Visual width of a string."""
    return sum(cwidth(c) for c in s)


def clusters(word):
    """Split a word into base characters with their zero-width followers."""
    out = []
    for ch in word:
        if cwidth(ch) == 0 and out:
            out[-1] += ch
        else:
            out.append(ch)
    return out


def split_hard(word, width):
    """Cut a word into pieces no wider than width; the last piece may be short."""
    pieces, cur, curw = [], "", 0
    for cl in clusters(word):
        w = vwidth(cl)
        if curw + w > width:
            pieces.append(cur)
            cur, curw = "", 0
        cur += cl
        curw += w
    if cur:
        pieces.append(cur)
    return pieces


def wrap_paragraph(words, width):
    lines, cur, curw = [], "", 0
    for word in words:
        ww = vwidth(word)
        if cur and curw + 1 + ww <= width:
            cur += " " + word
            curw += 1 + ww
            continue
        if cur:
            lines.append(cur)
            cur, curw = "", 0
        if ww <= width:
            cur, curw = word, ww
        else:
            pieces = split_hard(word, width)
            lines.extend(pieces[:-1])
            cur, curw = pieces[-1], vwidth(pieces[-1])
    if cur:
        lines.append(cur)
    return lines


def wrap(text, width):
    """Wrap text to width visual columns. Returns a list of lines."""
    out, para = [], []
    for line in text.splitlines():
        words = [w for w in re.split(r"[ \t]+", line) if w]
        if words:
            para.extend(words)
        else:
            if para:
                out.extend(wrap_paragraph(para, width))
                para = []
            out.append("")
    if para:
        out.extend(wrap_paragraph(para, width))
    return out


def wrap_keep_lines(text, width):
    """Like wrap, but every input line stays a line; only too-wide lines are broken."""
    out = []
    for line in text.splitlines():
        if vwidth(line) <= width:
            out.append(line)
        else:
            out.extend(wrap_paragraph([w for w in re.split(r"[ \t]+", line) if w], width))
    return out


def main(argv):
    args = argv[1:]
    keep_lines = "--keep-lines" in args
    args = [a for a in args if a != "--keep-lines"]
    if len(args) != 1:
        print("usage: wrap.py [--keep-lines] WIDTH", file=sys.stderr)
        return 2
    try:
        width = int(args[0])
    except ValueError:
        print("wrap.py: width must be an integer", file=sys.stderr)
        return 2
    if width < MIN_WIDTH:
        print("wrap.py: width must be at least %d" % MIN_WIDTH, file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    lines = wrap_keep_lines(text, width) if keep_lines else wrap(text, width)
    out = "\n".join(lines)
    if out or text:
        out += "\n"
    sys.stdout.buffer.write(out.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
