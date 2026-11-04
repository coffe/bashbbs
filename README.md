# BashBBS

An SSH bulletin board for a Raspberry Pi Zero W. Users log in over SSH and get a
Bash menu with news sections, public boards, a one-line Wall, and private
messages. Each login is a real Unix account, and the menu runs as a restricted
shell. Private messages go through the local sendmail (Postfix) to Maildir
folders on this host only. "Queued for delivery." means Postfix accepted the
message, not that it arrived.

The board itself runs on the Pi. The daily news selection is made by a separate
producer on another host, which pushes it to the Pi over SSH. The producer lives
in a separate private repository. This repository has only the Pi side.

## Layout

| Path | Contents |
|---|---|
| `bin/bbs-shell` | Login shell for `bbs-*` accounts. Starts the menu. |
| `bin/bbs-ingest` | Receives news batches from the producer (forced command of `bbs-news`). |
| `bin/bbs-news-status` | Prints the news ledger status (forced command for the status channel). |
| `bin/bbs-health` | Read-only health summary, one `key=value` line per fact (used by `bbs-admin status`). |
| `sbin/bbs-admin` | The one sysop command allowed as root: fixed subcommands that call the tools below. |
| `sbin/bbs-provision` | Creates BBS accounts. |
| `sbin/bbs-alias` | Short login names (`ptrko` for `bbs-ptrko`) as aliases with the same uid. |
| `sbin/bbs-publish` | Publishes queued posts, news and Wall lines. Runs every 60 s. |
| `sbin/bbs-drop` | Processes the drop folder and rejected items. Runs every 300 s. |
| `sbin/bbs-approve` | Sysop tool: accept or reject applications. |
| `sbin/bbs-svara` | Resolves a short application id and accepts or rejects it via `bbs-approve`. |
| `sbin/bbs-keys` | Sysop CLI for the SSH keys of BBS accounts. |
| `sbin/bbs-keys-apply` | Root handler for SSH key requests from the menu. Runs every 60 s. |
| `sbin/bbs-keycheck` | Validates one SSH public key line read from stdin (pure filter). |
| `sbin/bbs-maildir` | Creates the Maildir folders (Inbox, Sent, Trash) for one account. |
| `sbin/bbs-news-index` | Maintains the news index (`repair` rebuilds it). |
| `sbin/bbs-history-expire` | Expires old history files and admin backups. Runs daily. |
| `lib/menu.sh` | The menu UI (English strings). |
| `lib/news.sh` | News section helpers. |
| `lib/wrap.py` | Text wrapping for the terminal (Python 3). |
| `lib/news-categories.conf` | News categories. |
| `lib/goodbye-art.txt` | Logout banner. Not used by the current code. |
| `web/index.html`, `web/apply.cgi` | Public web page and application form (served by lighttpd). |
| `etc/` | Config fragments: fail2ban jail, sshd `Match` block, lighttpd site. Also `file-areas`, the default list of file areas. |
| `systemd/` | `bbs-publish`, `bbs-drop`, `bbs-history-expire` and `bbs-keys` service and timer units, lighttpd drop-in. |
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

It installs the scripts under `/usr/local/lib/bashbbs` and `/usr/local/sbin`, and
creates `/srv/bashbbs`.

**Dependencies.** The installer checks for the packages it needs and lists the
missing ones. Required: `python3`, `util-linux` (flock), `systemd`, `openssh-server`.
Optional: `postfix` (private messages), `lighttpd` (web part), `fail2ban` with
`python3-systemd` and `nftables` (sshd jail). A missing optional package skips its
part. To install the missing packages with apt, run `sudo ./install.sh --install-deps`.
A plain re-run never installs packages.

Config the sysop may have edited is kept on a re-run. `/etc/fail2ban/jail.local`,
`/etc/lighttpd/bashbbs.conf` and `/srv/bashbbs/lib/news-categories.conf` are never
overwritten. If the repo version differs, the new one goes to `<file>.new` and a
note says so. Compare with `diff`, merge by hand, then delete the `.new` file.

Before you run it, read these gotchas:

- **Postfix is never changed by the installer.** It warns when `myorigin` is not
  `bbs.localdomain`, when `mydestination` lacks `$myhostname` or `$myorigin`, and when
  `home_mailbox` is not `Maildir/`. It prints the command to fix `home_mailbox`. `etc/nftables-egress.example.nft` and
  `etc/sshd-hardening.example.conf` are templates for the host's own firewall and
  sshd settings. They are not installed.
- **The sshd `Match` block is appended once** and must stay at the end of
  `sshd_config`. The installer copies the original to
  `/etc/ssh/sshd_config.pre-bashbbs.<date>` first.
- **Short login names.** `ssh ptrko@host` works like `ssh bbs-ptrko@host`: the alias is a
  second passwd entry with the same uid, home and shell (`sbin/bbs-alias`, group `bbsalias`),
  so `id -un` still says `bbs-ptrko` and the BBS identity does not change. Names on
  `lib/reserved-names.conf` or already used by a system user or group get no alias, and the
  web form refuses them. `bbs-provision` creates the alias, `bbs-admin users remove` removes
  it (never `userdel -r`). Existing accounts: `bbs-alias backfill` (dry run), then `--apply`.
  sshd needs `AllowGroups <admin> newsstatus bbs-* bbsalias` instead of `AllowUsers`
  (`etc/sshd-hardening.example.conf`) and the `Match Group bbsalias` block
  (`etc/sshd-bashbbs-alias.conf`, appended by `install.sh`).
- **fail2ban needs `python3-systemd` and `nftables`** on Debian. The jail uses the
  systemd backend and bans through nft. The installer sets up the jail only when all
  three are present. The jail matches `ssh.service`, not `sshd.service`.
- **Not set up by the installer:** the `bbs-news`
  account and its SSH key, the `newsstatus` account and its key (the status channel
  for the news producer, key forced to `bbs-news-status`), and the port forward (the public SSH port is 6464 on
  the router, forwarded to port 22 on the Pi). Set these up by hand. `newsstatus` and
  `bbs-news` need `/bin/bash` as login shell: sshd runs the ForceCommand through the login
  shell with `-c`, so `nologin` or `/bin/false` breaks it. The `Match User newsstatus`
  block in `etc/sshd-bashbbs.conf` already forbids a terminal, forwarding and rc files.
- **News needs no timers of its own.** `bbs-publish.timer` and `bbs-drop.timer` handle
  ingest, retention and the index. `install.sh` installs `bbs-ingest`, `bbs-news-status`,
  `bbs-news-index` and `bbs-health`; only the two accounts and their keys are manual.

## Tests

Every test is a standalone script:

```sh
bash tests/wall_test.sh [logfile]        # prints PASS/FAIL lines and a summary
bash tests/maildir_test.sh               # Maildir folders, owners, message survival
bash tests/install_helpers_test.sh       # dependency list, kept config files
bash tests/fail2ban_config_test.sh       # jail: loopback only, nftables bans, no iptables
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
| `BBS_SENDMAIL` | system `sendmail` | Sendmail for private messages. Used only when `BASHBBS_TEST=1`. |
| `BBS_NOW` | current time | Fixed epoch time, for tests. |
| `BBS_COLS`, `BBS_ROWS` | terminal size | Terminal size, used for wrapping and Wall layout. |
| `BASHBBS_TEST=1` | unset | Enables test-only hooks. |

### File areas

The areas in the Files section are listed in `$BBS_ROOT/etc/file-areas`, one per line, in menu
order: `slug|Title|Short text`. The installer never overwrites an existing list. Changes take
effect at once.

- **To add an area,** add a line.
- **To remove an area,** remove its line. No file is deleted: its files show under the first
  area, which is the default, and return if the line comes back.
- `scp -O` uploads go to the default area. In the menu, `U` uses the area you are in, and `M`
  in an open file moves it (uploader and sysops).
- With one area, or no list at all, the area menu is skipped.

## Hardcoded values to change before reuse

This code was written for one installation. These values are hardcoded:

- `web/index.html` line 43: the public host `bbs.piewpiew.se` and port 6464.
- `web/index.html` lines 47 and 75: the sysop's name in the footer.
- Some tests default their scratch directory to a session-specific path.

## Third-party assets

- The Topaz a1200 font (`web/style.css`, embedded as a data URI so the web page
  shows the ASCII art in Topaz) comes from rewtnull/amigafonts, under the GPL-FE licence (GPL with the font exception). Topaz itself is (c) AmigaInc; the TTF version is (c) dMG/t!s^dS!. The font is the only third-party binary in the repo and no separate licence file is shipped.

## Status

- **A fresh Raspberry Pi OS Trixie install (Pi Zero W, armv6l) is tested.** The installer
  exits 0, is idempotent on a second run, and its `Match` block is written once. The
  `--install-deps` apt branch ran and installed every package. Not yet tested: the
  newsstatus account (not provisioned, see above) and the PM read view as a second user.
  The fail2ban jail cannot run on the dev host, so it is checked only on the test card.
- Version 1.2 is released (Wall). Version 1.3 (private messages, English UI) is
  built on branch `bashbbs-1.3-pm` and is not rolled out.
- There are no TODO or FIXME comments in the code.
- `bbs-history-expire` runs daily at 04:10 from `bbs-history-expire.timer`.
