"""Plays ANSI art (colour codes, cursor moves) on a small virtual terminal and reads
the screen back. render() gives plain text: bbs-fido toss uses it so ANSI ads from
the echoes are readable in the board reader, which strips ESC. render_ansi() keeps
the colours as one SGR + text line per screen row, with no cursor moves, so the
A) ANSI view can print it under the menu without the art jumping around.

CLI: python3 -I ansirender.py --ansi <file.ans>  (CP437 in, UTF-8 out, reads SAUCE)
"""
import re
import struct
import sys

WIDTH, MAX_ROWS = 80, 500  # a hostile ESC[9999B cannot grow the screen without bound
TOK = re.compile(r"\x1b\[([0-9;?]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b.?|[\r\n]|[^\x1b\r\n]", re.S)
PLAIN = (False, False, False, "", "")  # bold, blink, reverse, fg, bg (SGR parameter strings)


def _sgr(params, a):
    bold, blink, rev, fg, bg = a
    p = params.split(";") if params else ["0"]
    i = 0
    while i < len(p):
        x = p[i]
        n = int(x) if x.isdigit() else 0
        if n == 0:
            bold, blink, rev, fg, bg = PLAIN
        elif n == 1:
            bold = True
        elif n == 22:
            bold = False
        elif n in (5, 6):
            blink = True
        elif n == 25:
            blink = False
        elif n == 7:
            rev = True
        elif n == 27:
            rev = False
        elif 30 <= n <= 37 or 90 <= n <= 97:
            fg = str(n)
        elif n == 39:
            fg = ""
        elif 40 <= n <= 47 or 100 <= n <= 107:
            bg = str(n)
        elif n == 49:
            bg = ""
        elif n in (38, 48):  # 38;5;n and 38;2;r;g;b, kept as given
            k = 3 if p[i + 1:i + 2] == ["5"] else 5 if p[i + 1:i + 2] == ["2"] else 1
            v = ";".join(q for q in p[i:i + k] if q.isdigit())
            if n == 38:
                fg = v
            else:
                bg = v
            i += k - 1
        i += 1
    return (bold, blink, rev, fg, bg)


def _play(text, width):
    """The screen as rows of (char, attr) cells."""
    text = text.split("\x1a", 1)[0]  # Ctrl-Z ends ANSI art; a SAUCE record may follow
    rows, r, c, saved, attr = [], 0, 0, (0, 0), PLAIN

    def put(ch):
        while len(rows) <= r:
            rows.append([])
        line = rows[r]
        if len(line) <= c:
            line.extend([(" ", PLAIN)] * (c + 1 - len(line)))
        line[c] = (ch, attr)

    for m in TOK.finditer(text):
        tok = m.group()
        if tok == "\n":
            r, c = min(r + 1, MAX_ROWS - 1), 0
        elif tok == "\r":
            c = 0
        elif m.group(2):  # CSI: params + final byte
            p = [int(x) if x.isdigit() else 0 for x in m.group(1).split(";")]
            n = max(p[0], 1)
            f = m.group(2)
            if f == "m":
                attr = _sgr(m.group(1), attr)
            elif f == "A":
                r = max(r - n, 0)
            elif f == "B":
                r = min(r + n, MAX_ROWS - 1)
            elif f == "C":
                c = min(c + n, width - 1)
            elif f == "D":
                c = max(min(c, width - 1) - n, 0)
            elif f in "Hf":
                r = min(n, MAX_ROWS) - 1
                c = min(max(p[1] if len(p) > 1 else 1, 1), width) - 1
            elif f == "J" and p[0] == 2:
                rows, r, c = [], 0, 0  # ANSI.SYS homes the cursor on 2J
            elif f == "K" and r < len(rows):
                del rows[r][c:]
            elif f == "s":
                saved = (r, c)
            elif f == "u":
                r, c = saved
        elif tok.startswith("\x1b") or tok < " ":
            pass  # other escapes and control characters draw nothing
        else:
            if c >= width:  # deferred wrap: an 80-char line followed by CRLF stays one line
                r, c = min(r + 1, MAX_ROWS - 1), 0
            put(tok)
            c += 1
    return rows


def _trim(lines):
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def render(text, width=WIDTH):
    """render(str) -> str: the screen as text lines, trailing blanks removed."""
    return _trim(["".join(ch for ch, _ in line).rstrip() for line in _play(text, width)])


def render_ansi(text, width=WIDTH, ice=False):
    """render_ansi(str) -> str: the screen as SGR + text lines. Each line starts and
    ends in plain colour; trailing spaces stay only where a background shows them.
    ice: SAUCE iCE colours, blink means a bright background instead."""
    def look(a):
        bold, blink, rev, fg, bg = a
        if ice and blink:
            blink, bg = False, str(int(bg) + 60) if bg in {str(n) for n in range(40, 48)} else bg or "100"
        return (bold, blink, rev, fg, bg)

    out = []
    for line in _play(text, width):
        cells = [(ch, look(a)) for ch, a in line]
        while cells and cells[-1][0] == " " and not cells[-1][1][2] and not cells[-1][1][4]:
            cells.pop()
        s, cur = [], PLAIN
        for ch, a in cells:
            if a != cur:
                bold, blink, rev, fg, bg = a
                s.append("\x1b[" + ";".join(["0"] + ["1"] * bold + ["5"] * blink + ["7"] * rev + [v for v in (fg, bg) if v]) + "m")
                cur = a
            s.append(ch)
        if cur != PLAIN:
            s.append("\x1b[0m")
        out.append("".join(s))
    return _trim(out)


def sauce(data):
    """(width, ice) from a SAUCE record on raw bytes; (80, False) without one."""
    rec = data[-128:]
    if len(rec) == 128 and rec[:5] == b"SAUCE" and rec[94] == 1 and rec[95] == 1:
        w = struct.unpack_from("<H", rec, 96)[0]
        return (w if 1 <= w <= 255 else WIDTH), bool(rec[105] & 1)
    return WIDTH, False


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--ansi":
        sys.exit("usage: ansirender.py --ansi <file>")
    with open(sys.argv[2], "rb") as fh:
        raw = fh.read(1 << 20)  # shortcut: art past 1 MB is cut, raise if a real piece needs it
    w, ice = sauce(raw)
    sys.stdout.buffer.write(render_ansi(raw.split(b"\x1a", 1)[0].decode("cp437"), w, ice).encode("utf-8") + b"\n")
