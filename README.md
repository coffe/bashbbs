# BashBBS

An SSH bulletin board for a Raspberry Pi Zero W. Users log in over SSH and get a
Bash menu with news sections, public boards, a one-line Wall, and private
messages. Each login is a real Unix account, and the menu runs as a restricted
shell. Mail is delivered to local Maildir folders through Postfix.

The board itself runs on the Pi. The daily news selection is made by a separate
producer on another host, which pushes it to the Pi over SSH. The producer lives
in a separate private repository. This repository has only the Pi side.

## Layout

| Path | Contents |
|---|---|
| `bin/bbs-shell` | Login shell for `bbs-*` accounts. Starts the menu. |
| `bin/bbs-ingest` | Receives news batches from the producer (forced command). |
| `bin/bbs-news-status` | Prints the news ledger status (forced command for the status channel). |
| `sbin/bbs-provision` | Creates and removes BBS accounts. |
| `sbin/bbs-publish` | Publishes queued posts, news and Wall lines. Runs every 60 s. |
| `sbin/bbs-drop` | Processes the drop folder and rejected items. Runs every 300 s. |
| `sbin/bbs-approve` | Sysop tool: accept or reject applications. |
| `sbin/bbs-news-index` | Rebuilds the news index. |
| `sbin/bbs-history-expire` | Expires old history files. Not scheduled by default. |
| `lib/menu.sh` | The menu UI (Swedish strings). |
| `lib/news.sh` | News section helpers. |
| `lib/wrap.py` | Text wrapping for the terminal (Python 3). |
| `lib/news-categories.conf` | News categories. |
| `lib/goodbye-art.txt` | Logout banner. Not used by the current code. |
| `web/index.html`, `web/apply.cgi` | Public web page and application form (served by lighttpd). |
| `etc/` | Config fragments: fail2ban jail, sshd `Match` block, lighttpd site. |
| `systemd/` | `bbs-publish` and `bbs-drop` service and timer units, lighttpd drop-in. |
| `install.sh` | Installer, run as root. |
| `tests/` | Shell and Python tests (see below). |

Runtime data lives outside the repo, under `BBS_ROOT` (default `/srv/bashbbs`):
`queue/`, `boards/`, `wall`, `state/`, `meta/`, `drop/`, `applications/`, `keys/`
and `users/`. None of it belongs in git.

## Install

Run on a Debian host as root, from a checkout:

```sh
sudo ./install.sh
```

The installer needs `python3` and `flock`. It installs the scripts under
`/usr/local/lib/bashbbs` and `/usr/local/sbin`, and creates `/srv/bashbbs`.

Before you run it, read these gotchas:

- **It overwrites files without a backup.** `/etc/fail2ban/jail.local` and
  `/srv/bashbbs/lib/news-categories.conf` are replaced on every run. Do not run it
  on a system where you have edited either file.
- **The sshd `Match` block is appended once** and must stay at the end of
  `sshd_config`. The installer copies the original to
  `/etc/ssh/sshd_config.pre-bashbbs.<date>` first.
- **fail2ban needs `python3-systemd`** on Debian, because the jail uses the
  systemd backend. The jail matches `ssh.service`, not `sshd.service`.
- **Not set up by the installer:** Postfix and Maildir delivery, the `bbs-news`
  account and its SSH key, and the port forward (the public SSH port is 6464 on
  the router, forwarded to port 22 on the Pi). Set these up by hand.
- **Only the core parts are installed.** News timers and the status channel are
  not part of `install.sh` yet.

## Tests

Every test is a standalone script:

```sh
bash tests/wall_test.sh [logfile]        # prints PASS/FAIL lines and a summary
python3 tests/test_wrap.py               # wrapping
```

Shell tests write their scratch files under `$SCRATCH` (default: a directory in the
session scratchpad). Set `SCRATCH` to choose another location. The `stage-*` and
`test-*` scripts need a live Pi and are not run by default.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BBS_ROOT` | `/srv/bashbbs` | Root of all runtime data. Tests point this at a temp tree. |
| `BBS_LOCK_WAIT` | `20` | Seconds to wait for a lock before giving up. |
| `BBS_SENDMAIL` | system `sendmail` | Mail command used for notifications. |
| `BBS_NOW` | current time | Fixed epoch time, for tests. |
| `BBS_COLS`, `BBS_ROWS` | terminal size | Terminal size, used for wrapping and Wall layout. |
| `BASHBBS_TEST=1` | unset | Enables test-only hooks. |

## Hardcoded values to change before reuse

This code was written for one installation. These values are hardcoded:

- `web/index.html` line 43: the public host `bbs.piewpiew.se` and port 6464.
- `web/index.html` lines 47 and 75: the sysop's name in the footer.
- `etc/fail2ban-jail.local` line 4: the LAN subnet in `ignoreip`.
- Swedish UI strings in `lib/menu.sh`.
- Some tests default their scratch directory to a session-specific path.

## Status

- Version 1.2 is released (Wall). Version 1.3 (private messages) is planned.
- There are no TODO or FIXME comments in the code.
- `bbs-history-expire` exists but is not scheduled.
