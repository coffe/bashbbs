"""Turns ANSI art (colour codes, cursor moves) into plain text by playing it on a
small virtual terminal and reading the screen back. Used by bbs-fido toss, so
ANSI ads from the echoes are readable in the board reader, which strips ESC.
"""
import re

WIDTH, MAX_ROWS = 80, 500  # a hostile ESC[9999B cannot grow the screen without bound
TOK = re.compile(r"\x1b\[([0-9;?]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b.?|[\r\n]|[^\x1b\r\n]", re.S)


def render(text, width=WIDTH):
    """render(str) -> str: the screen as text lines, trailing blanks removed."""
    text = text.split("\x1a", 1)[0]  # Ctrl-Z ends ANSI art; a SAUCE record may follow
    rows, r, c, saved = [], 0, 0, (0, 0)

    def put(ch):
        while len(rows) <= r:
            rows.append([])
        line = rows[r]
        if len(line) <= c:
            line.extend(" " * (c + 1 - len(line)))
        line[c] = ch

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
            if f == "A":
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
    out = ["".join(line).rstrip() for line in rows]
    while out and not out[-1]:
        out.pop()
    return "\n".join(out)
