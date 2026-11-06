#!/usr/bin/env python3
# File transfers from inside a BBS session. Runs under lighttpd as www-data.
#
# The menu creates a ticket, queue/xfer/<token>, and shows the user the link
# /x.cgi/<token>. The directory is mode 1733: nobody can list it, but anyone who
# knows a token can open that file. The ticket's OWNER says who it belongs to;
# its lines (dir=up|down, id=<file id>) are checked and never run as code. An area= line
# is for the sorter, and not read here. A download ticket may instead say export=callers:
# a sysop's snapshot of the callers log, kept beside the ticket as <token>.snap.
# A ticket expires by its ctime. Its owner can refresh that by changing the file
# but cannot backdate it, and it only ever carries the owner's own rights.
#
#   GET  /x.cgi/<token>            one file: send it; several: list; upload: the page
#   GET  /x.cgi/<token>?f=<n>      send file number n of the ticket
#   PUT  /x.cgi/<token>?name=<n>   upload one file as a raw body (no multipart)
#   POST /x.cgi/<token>?done=1     the browser has sent everything
#   GET  /x.cgi/<token>?results=1  what the sorter said about each file (plain text)
#
# Uploads land in webup/<token>/. sbin/bbs-upload (root) checks them and publishes
# them; this script never unpacks or runs anything. Limits come from
# lib/upload-common.sh, and without them the script refuses everything (fail closed).
# Test hook: BASHBBS_TEST=1 moves the paths, and limits may come from the environment.
import fcntl
import ipaddress
import os
import pwd
import re
import secrets
import signal
import stat
import sys
import time
import urllib.parse
from html import escape

ROOT = "/srv/bashbbs"
COMMON = "/usr/local/lib/bashbbs/upload-common.sh"
TEST = os.environ.get("BASHBBS_TEST") == "1"
if TEST:
    ROOT = os.environ.get("BBS_ROOT", ROOT)
    COMMON = os.environ.get("BBS_UPLOAD_COMMON", COMMON)

XFER = os.path.join(ROOT, "queue/xfer")
KICK = os.path.join(ROOT, "queue/kick")
TRANSFERS = os.path.join(ROOT, "queue/transfers")
PUBLISHED = os.path.join(ROOT, "published")
WEBUP = os.path.join(ROOT, "webup")
DONE = os.path.join(ROOT, "state/xfer-done")
SLOTS = os.path.join(ROOT, "state/xfer-slots")
SYSOPS = os.path.join(ROOT, "sysops")
RESULTS = os.path.join(ROOT, "state/xfer-results")

TOKEN_RE = re.compile(r"/([A-Za-z0-9_-]{22})")
ID_RE = re.compile(r"[0-9]+-[0-9a-f]{8}")
OWNER_RE = re.compile(r"bbs-[a-z][a-z0-9]{2,8}")
MAX_FILES = 20          # files per ticket
MAX_SNAP = 4 << 20      # bytes of a callers snapshot
MAX_SLOTS = 3           # transfers at the same time; the Pi Zero has one core
MAX_NAME = 100          # bytes, same as sbin/bbs-upload
MAX_SECS = 1800         # no single request runs longer than this
SYSOP_SECS = 6 * 3600   # ...except on a sysop's link, which has no size limit
CHUNK = 65536
LIMIT_NAMES = ("UPLOAD_MAX_BYTES", "UPLOAD_USER_QUOTA", "UPLOAD_GLOBAL_QUOTA",
               "UPLOAD_MIN_FREE_KB", "XFER_TTL_DOWN", "XFER_TTL_UP")


def load_limits():
    """The limits from upload-common.sh, or None if any of them is missing."""
    try:
        with open(COMMON, encoding="utf-8") as f:
            source = f.read()
    except OSError:
        return None
    limits = {}
    for name in LIMIT_NAMES:
        m = re.search(r"^%s=\$\{%s:-([0-9]+)\}" % (name, name), source, re.M)
        if not m:
            return None
        limits[name] = int(m.group(1))
        if TEST and os.environ.get(name, "").isdigit():
            limits[name] = int(os.environ[name])
    return limits


def respond(status, ctype, body=b"", extra=()):
    """Write a whole response. The security headers go on everything we send."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    write_head(status, ctype, extra)
    if os.environ.get("REQUEST_METHOD") != "HEAD":
        sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def write_head(status, ctype, extra=()):
    lines = [f"Status: {status}", f"Content-Type: {ctype}", "Cache-Control: no-store",
             "X-Content-Type-Options: nosniff", "X-Robots-Tag: noindex",
             "Referrer-Policy: no-referrer"]
    lines.extend(extra)
    sys.stdout.buffer.write(("\r\n".join(lines) + "\r\n\r\n").encode("ascii", "replace"))


def text(status, message, extra=()):
    respond(status, "text/plain; charset=utf-8", message + "\n", extra)


def page(status, title, inner, script=None):
    """An HTML page. Whatever came from outside must be escaped by the caller."""
    nonce = secrets.token_urlsafe(16)
    csp = ("default-src 'none'; style-src 'self'; img-src 'self'; connect-src 'self'; "
           "base-uri 'none'; form-action 'none'; frame-ancestors 'none'; "
           f"script-src 'nonce-{nonce}'")
    tag = f"<script nonce='{nonce}'>{script}</script>" if script else ""
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} - piewpiew BBS</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<nav aria-label="Main"><div class="wrap"><a class="brand" href="/">piewpiew BBS</a></div></nav>
<main id="main" class="wrap">
<h1>{escape(title)}</h1>
{inner}
</main>
<footer><div class="wrap"><p>Runs on a Raspberry Pi Zero W. The original one.</p></div></footer>
{tag}
</body>
</html>"""
    respond(status, "text/html; charset=utf-8", html, [f"Content-Security-Policy: {csp}"])


def gone(status, message):
    page(status, "Link not valid", f"<div class='warn' role='alert'><p>{escape(message)}</p></div>")


class Ticket:
    def __init__(self, token, owner, direction, ids, uid=-1, export=False):
        self.uid = uid
        self.export = export
        self.token = token
        self.owner = owner
        self.direction = direction
        self.ids = ids


def load_ticket(token, limits):
    """Returns a Ticket, "expired", or None when there is no usable ticket."""
    try:
        fd = os.open(os.path.join(XFER, token),
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            return None
        data = os.read(fd, 4096).decode("utf-8", "replace")
    finally:
        os.close(fd)

    owner = os.environ.get("BBS_XFER_TEST_OWNER", "") if TEST else ""
    if not owner:
        try:
            owner = pwd.getpwuid(st.st_uid).pw_name
        except KeyError:
            return None
    if not OWNER_RE.fullmatch(owner):
        return None

    direction = ""
    ids = []
    export = False
    for line in data.split("\n"):
        key, _, value = line.partition("=")
        if key == "dir" and not direction:
            direction = value
        elif key == "export" and value == "callers":
            export = True
        elif key == "id" and ID_RE.fullmatch(value) and value not in ids:
            ids.append(value)
    if direction not in ("up", "down") or len(ids) > MAX_FILES:
        return None
    if export and (direction != "down" or ids or not is_sysop(owner)):
        return None
    if direction == "down" and not ids and not export:
        return None

    ttl = limits["XFER_TTL_UP"] if direction == "up" else limits["XFER_TTL_DOWN"]
    if time.time() - st.st_ctime >= ttl:
        return "expired"
    return Ticket(token, owner, direction, ids, st.st_uid, export)


def is_sysop(owner):
    """The owner (bbs-<name>) is listed as <name> in the sysops file."""
    name = owner[4:]
    try:
        with open(SYSOPS, encoding="utf-8", errors="replace") as f:
            return name in f.read(65536).split("\n")
    except OSError:
        return False


def send_export(ticket):
    """The sysop's snapshot of the callers log. The path is built here from the token."""
    try:
        fd = os.open(os.path.join(XFER, ticket.token + ".snap"),
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return gone("404 Not Found", "That export is no longer here.")
    st = os.fstat(fd)
    if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != ticket.uid
            or st.st_size > MAX_SNAP):
        return gone("404 Not Found", "That export is no longer here.")
    name = "callers-" + time.strftime("%Y%m%d", time.gmtime(st.st_mtime)) + ".log"
    head = [f"Content-Length: {st.st_size}", f'Content-Disposition: attachment; filename="{name}"',
            "Accept-Ranges: none"]
    if os.environ.get("REQUEST_METHOD") == "HEAD":
        return respond("200 OK", "text/plain; charset=utf-8", b"", head)
    if take_slot() is None:
        return busy()
    write_head("200 OK", "text/plain; charset=utf-8", head)
    out = sys.stdout.buffer
    sent = 0
    try:
        while True:
            data = os.read(fd, CHUNK)
            if not data:
                break
            out.write(data)
            sent += len(data)
        out.flush()
    except OSError:     # the client went away
        return
    if sent == st.st_size:      # tell the session; the dir is writable but not listable
        try:
            os.close(os.open(os.path.join(XFER, ticket.token + ".sent"),
                             os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o644))
        except OSError:
            pass


def take_slot():
    """One of the transfer slots, held until the process ends, or None if all are busy."""
    try:
        os.makedirs(SLOTS, mode=0o700, exist_ok=True)
    except OSError:
        return None
    for n in range(MAX_SLOTS):
        try:
            fd = os.open(os.path.join(SLOTS, str(n)), os.O_CREAT | os.O_WRONLY | os.O_CLOEXEC, 0o600)
        except OSError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            os.close(fd)
    return None


def busy():
    text("503 Service Unavailable", "The BBS is busy with other transfers. Try again in a minute.",
         ["Retry-After: 30"])


def kick():
    """Wake the sorter (bbs-upload.path). If this fails, its timer gets there within a minute."""
    try:
        os.close(os.open(os.path.join(KICK, secrets.token_hex(8)),
                         os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o600))
    except OSError:
        pass


def clean_name(name):
    """The published name is plain ASCII, as sanitize_name in sbin/bbs-upload makes it."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def read_meta(fid):
    """The first user=, name= and size= of a published file, or None."""
    try:
        with open(os.path.join(PUBLISHED, fid + ".meta"), encoding="utf-8", errors="replace") as f:
            lines = f.read(8192).split("\n")
    except OSError:
        return None
    meta = {}
    for line in lines:
        key, _, value = line.partition("=")
        if key in ("user", "name", "size") and key not in meta:
            meta[key] = value
    return meta if "name" in meta else None


def client_ip():
    """Caddy on nuc adds the client address last. This is only used in the transfer log."""
    forwarded = os.environ.get("HTTP_X_FORWARDED_FOR", "").split(",")[-1].strip()
    for candidate in (forwarded, os.environ.get("REMOTE_ADDR", "")):
        try:
            return str(ipaddress.ip_address(candidate))
        except ValueError:
            pass
    return "-"


def log_download(ticket, fid, name, size):
    """Leave one transfer record per file and ticket, however many times it is fetched."""
    try:
        os.makedirs(DONE, mode=0o700, exist_ok=True)
        os.close(os.open(os.path.join(DONE, f"{ticket.token}.{fid}"),
                         os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o600))
    except OSError:     # already logged, or nothing we can do about it now
        return
    stem = f"{time.time_ns()}-{ticket.owner}-{secrets.token_hex(4)}"
    tmp = os.path.join(TRANSFERS, ".tmp-" + stem)
    try:
        with open(tmp, "x", encoding="utf-8") as f:
            f.write(f"user={ticket.owner}\nid={fid}\nname={name}\nsize={size}\nip={client_ip()}\n")
        os.chmod(tmp, 0o644)
        os.rename(tmp, os.path.join(TRANSFERS, stem))
    except OSError:
        pass
    kick()


def send_file(ticket, index):
    """Stream one file, and log it only once every byte has been handed over."""
    if index < 0 or index >= len(ticket.ids):
        return gone("404 Not Found", "No such file on this link.")
    fid = ticket.ids[index]
    meta = read_meta(fid)
    if meta is None:
        return gone("404 Not Found", "That file has been removed from the BBS.")
    try:
        fd = os.open(os.path.join(PUBLISHED, fid), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return gone("404 Not Found", "That file has been removed from the BBS.")
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        return gone("404 Not Found", "That file has been removed from the BBS.")
    name = clean_name(meta["name"]) or "file"
    head = [f"Content-Length: {st.st_size}", f'Content-Disposition: attachment; filename="{name}"',
            "Accept-Ranges: none"]
    if os.environ.get("REQUEST_METHOD") == "HEAD":
        return respond("200 OK", "application/octet-stream", b"", head)
    if take_slot() is None:
        return busy()
    write_head("200 OK", "application/octet-stream", head)
    out = sys.stdout.buffer
    sent = 0
    try:
        while True:
            data = os.read(fd, CHUNK)
            if not data:
                break
            out.write(data)
            sent += len(data)
        out.flush()
    except OSError:     # the client went away
        return
    if sent == st.st_size:
        log_download(ticket, fid, name, sent)


def file_list(ticket):
    """Several files on one ticket: a page of links."""
    rows = []
    for n, fid in enumerate(ticket.ids):
        meta = read_meta(fid)
        if meta is None:
            rows.append("<li>(removed)</li>")
            continue
        name = escape(clean_name(meta["name"]))
        size = meta.get("size", "")
        kb = f" ({int(size) // 1024 + 1} kB)" if size.isdigit() else ""
        rows.append(f"<li><a href='?f={n}' download='{name}'>{name}</a>{kb}</li>")
    page("200 OK", "Your files",
         "<p>Tap each file to save it. The link works for 15 minutes.</p>"
         f"<ul>{''.join(rows)}</ul>")


def quota_refusal(owner, size, limits, sysop=False):
    """The same checks as ub_check in lib/upload-common.sh, made before the body is read, so
    nobody sends 10 MB to hear no. sbin/bbs-upload checks again; this one only saves the wait."""
    try:
        vfs = os.statvfs(ROOT)
        free_kb = vfs.f_bavail * vfs.f_frsize // 1024
        if free_kb - size // 1024 < limits["UPLOAD_MIN_FREE_KB"]:
            return "The disk is nearly full."
    except OSError:
        return "The disk is nearly full."
    if sysop:
        return None     # sysops have no quota, only the free-space check
    used = mine = 0
    try:
        names = os.listdir(PUBLISHED)
    except OSError:
        names = []
    for entry in names:
        if not entry.endswith(".meta"):
            continue
        meta = read_meta(entry[:-5])
        if meta is None or not meta.get("size", "").isdigit():
            continue
        used += int(meta["size"])
        if meta.get("user") == owner:
            mine += int(meta["size"])
    if mine + size > limits["UPLOAD_USER_QUOTA"]:
        return "This would put you over your storage limit."
    if used + size > limits["UPLOAD_GLOBAL_QUOTA"]:
        return "The BBS file area is full."
    return None


def upload_name(raw):
    """The name to store under, or None if it cannot be used."""
    if not raw or raw.startswith(".") or "/" in raw or "\\" in raw:
        return None
    if any(not ch.isprintable() for ch in raw):
        return None
    if len(raw.encode("utf-8", "replace")) > MAX_NAME:
        return None
    return clean_name(raw)


def claim_upload(ticket):
    """Reserve one of the ticket's uploads. Returns the marker path, or None when all are used."""
    try:
        os.makedirs(DONE, mode=0o700, exist_ok=True)
    except OSError:
        return None
    for n in range(MAX_FILES):
        path = os.path.join(DONE, f"{ticket.token}.up.{n}")
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o600))
            return path
        except FileExistsError:
            continue
        except OSError:
            return None
    return None


def forget(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def receive(ticket, query, limits):
    """One PUT. The body goes to .part-*, locked while it is written, and gets its real
    name only when complete, so the sorter never sees half a file under a real name."""
    name = upload_name(query.get("name", [""])[0])
    if name is None:
        return text("400 Bad Request", "That file name cannot be used. Rename the file and try again.")
    raw_length = os.environ.get("CONTENT_LENGTH", "")
    if not raw_length.isdigit():
        return text("411 Length Required", "The upload did not say how big it is.")
    length = int(raw_length)
    if length == 0:
        return text("400 Bad Request", "That file is empty.")
    sysop = is_sysop(ticket.owner)
    if length > limits["UPLOAD_MAX_BYTES"] and not sysop:
        mb = limits["UPLOAD_MAX_BYTES"] // 1048576
        return text("413 Payload Too Large", f"Files can be up to {mb} MB.")
    why = quota_refusal(ticket.owner, length, limits, sysop)
    if why:
        return text("413 Payload Too Large", why)
    if take_slot() is None:
        return busy()
    claim = claim_upload(ticket)
    if claim is None:
        return text("409 Conflict", f"One link takes at most {MAX_FILES} files. Make a new link in the BBS.")

    folder = os.path.join(WEBUP, ticket.token)
    part = os.path.join(folder, f".part-{secrets.token_hex(8)}-{name}")
    final = os.path.join(folder, name)
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(part, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        forget(claim)
        return text("500 Internal Server Error", "Could not save the file. Try again later.")
    fcntl.flock(fd, fcntl.LOCK_EX)

    left = length
    try:
        while left > 0:
            data = sys.stdin.buffer.read(min(CHUNK, left))
            if not data:
                break
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            left -= len(data)
    except OSError:
        left = -1
    if left != 0:
        forget(part)
        forget(claim)
        return text("400 Bad Request", "The upload did not finish.")

    try:
        os.link(part, final)    # refuses to replace a file already waiting under this name
    except FileExistsError:
        forget(part)
        forget(claim)
        return text("409 Conflict", "A file with this name is already being handled. Try again in a minute.")
    except OSError:
        forget(part)
        forget(claim)
        return text("500 Internal Server Error", "Could not save the file. Try again later.")
    forget(part)
    kick()
    text("200 OK", "Received.")


def finish(ticket):
    """The browser has sent everything: the sorter writes "done" after the last file."""
    folder = os.path.join(WEBUP, ticket.token)
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        os.close(os.open(os.path.join(folder, ".done"), os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o600))
        kick()
    except FileExistsError:     # asked already: the sorter has not got to it yet
        pass
    except OSError:
        return text("500 Internal Server Error", "Could not save that. Try again later.")
    text("200 OK", "Done.")


def results(ticket):
    try:
        with open(os.path.join(RESULTS, ticket.token), encoding="utf-8", errors="replace") as f:
            body = f.read(65536)
    except OSError:
        body = ""
    respond("200 OK", "text/plain; charset=utf-8", body)


UPLOAD_SCRIPT = """
const MAX = %d;
const input = document.getElementById('files');
const go = document.getElementById('go');
const list = document.getElementById('list');
const state = document.getElementById('state');
function put(file, bar, note) {
  return new Promise(resolve => {
    if (file.size > MAX) { note.textContent = 'Too big.'; resolve(); return; }
    const x = new XMLHttpRequest();
    x.open('PUT', location.pathname + '?name=' + encodeURIComponent(file.name));
    x.upload.onprogress = e => { if (e.lengthComputable) bar.value = e.loaded / e.total; };
    x.onload = () => { note.textContent = x.responseText.trim(); if (x.status === 200) bar.value = 1; resolve(); };
    x.onerror = () => { note.textContent = 'Connection lost.'; resolve(); };
    x.send(file);
  });
}
async function results() {
  const r = await fetch(location.pathname + '?results=1');
  return (await r.text()).split('\\n').filter(l => l);
}
// A link can be used again, so only lines written after this round began count.
async function check(names, from) {
  for (let i = 0; i < 40; i++) {
    const lines = (await results()).slice(from).map(l => l.split('\\t'));
    for (const [row, n] of names) {
      const hit = lines.filter(l => l[1] === n).pop();
      if (hit) row.textContent = hit[0] === 'ok' ? 'Accepted. It is on the BBS now.' : 'Not accepted: ' + hit[2];
    }
    if (lines.some(l => l[0] === 'done')) { state.textContent = 'All done. You can close this page.'; return; }
    await new Promise(w => setTimeout(w, 2000));
  }
  state.textContent = 'Still checking. See the file list in the BBS.';
}
go.addEventListener('click', async () => {
  if (!input.files.length) return;
  go.disabled = true; input.disabled = true;
  const rows = [];
  for (const file of input.files) {
    const li = document.createElement('li');
    const bar = document.createElement('progress');
    const note = document.createElement('span');
    li.textContent = file.name + ' ';
    li.append(bar, ' ', note);
    bar.max = 1; bar.value = 0;
    list.append(li);
    rows.push([file, bar, note]);
  }
  state.textContent = 'Sending...';
  const from = (await results().catch(() => [])).length;
  for (const [file, bar, note] of rows) await put(file, bar, note);
  await fetch(location.pathname + '?done=1', {method: 'POST'});
  state.textContent = 'Testing...';
  const names = rows.map(([file, , note]) => [note, file.name.replace(/[^A-Za-z0-9._-]/gu, '_')]);
  check(names, from);
});
"""


def upload_page(ticket, limits):
    most = limits["UPLOAD_MAX_BYTES"]
    each = f"{most // 1048576} MB each"
    if is_sysop(ticket.owner):
        most, each = 2 ** 53 - 1, "any size"    # a sysop's link has no size limit
    inner = (f"<p>Up to {MAX_FILES} files, {each}. Keep your BBS session open and it will "
             "show the result too. The link works for 30 minutes.</p>"
             "<p><input id='files' type='file' multiple></p>"
             "<p><button id='go' type='button'>Upload</button></p>"
             "<p id='state' role='status'></p><ul id='list'></ul>")
    page("200 OK", "Upload to the BBS", inner, UPLOAD_SCRIPT % most)


def main():
    os.nice(10)
    signal.alarm(MAX_SECS)
    # lighttpd sends SIGTERM once it has the whole response, which is before the log
    # record is written. A client that goes away still ends us: stdin hits EOF, stdout
    # gets EPIPE, and the alarm above is the backstop.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    method = os.environ.get("REQUEST_METHOD", "")
    limits = load_limits()
    if limits is None:
        return text("503 Service Unavailable", "Transfers are switched off right now.")
    m = TOKEN_RE.fullmatch(os.environ.get("PATH_INFO", ""))
    if not m:
        return gone("404 Not Found", "This is not a valid link. Make a new one in the BBS.")
    ticket = load_ticket(m.group(1), limits)
    if ticket is None:
        return gone("404 Not Found", "This is not a valid link. Make a new one in the BBS.")
    if ticket == "expired":
        return gone("410 Gone", "This link has expired. Make a new one in the BBS.")
    if is_sysop(ticket.owner):
        signal.alarm(SYSOP_SECS)    # big files over the Zero's wifi take a while
    try:
        query = urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""), max_num_fields=4)
    except ValueError:
        return text("400 Bad Request", "That request is not understood.")

    if ticket.direction == "down":
        if method not in ("GET", "HEAD"):
            return text("405 Method Not Allowed", "This link is for downloads.", ["Allow: GET, HEAD"])
        if ticket.export:
            return send_export(ticket)
        wanted = query.get("f", [""])[0]
        if wanted:
            return send_file(ticket, int(wanted) if re.fullmatch(r"[0-9]{1,3}", wanted) else -1)
        return send_file(ticket, 0) if len(ticket.ids) == 1 else file_list(ticket)

    if method == "PUT":
        return receive(ticket, query, limits)
    if method == "POST" and "done" in query:
        return finish(ticket)
    if method in ("GET", "HEAD"):
        return results(ticket) if "results" in query else upload_page(ticket, limits)
    return text("405 Method Not Allowed", "This link is for uploads.", ["Allow: GET, HEAD, PUT, POST"])


if __name__ == "__main__":
    main()
