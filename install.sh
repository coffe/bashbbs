#!/bin/bash
# Install BashBBS on this host. Run as root from the checkout directory.
# Usage: sudo ./install.sh [--install-deps]
#   --install-deps  apt-get installs the missing Debian packages. Without it, the
#                   installer only lists them. A normal re-run never installs packages.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
src=$(dirname "$(readlink -f "$0")")
source "$src/lib/install-helpers.sh"

install_deps=no
for arg in "$@"; do
    case $arg in
        --install-deps) install_deps=yes ;;
        *) echo "usage: install.sh [--install-deps]" >&2; exit 2 ;;
    esac
done

# Required packages stop the install. Optional ones skip their part, which is reported below.
req=$(bashbbs_missing_deps required)
opt=$(bashbbs_missing_deps optional)
if [[ -n "$req$opt" ]]; then
    read -ra pkgs <<<"$req $opt"
    if [[ $install_deps == yes ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${pkgs[@]}"
        req=$(bashbbs_missing_deps required)
    else
        echo "missing packages: ${pkgs[*]}" >&2
        echo "install them with: apt-get install ${pkgs[*]}   (or run install.sh --install-deps)" >&2
    fi
fi
[[ -z $req ]] || { echo "required packages missing, install stopped: $req" >&2; exit 1; }

install -d -m 0755 /usr/local/lib/bashbbs
install -m 0755 "$src/lib/menu.sh" /usr/local/lib/bashbbs/menu.sh
install -m 0755 "$src/bin/bbs-shell" /usr/local/sbin/bbs-shell
install -m 0755 "$src/sbin/bbs-provision" /usr/local/sbin/bbs-provision
install -m 0755 "$src/sbin/bbs-publish" /usr/local/sbin/bbs-publish
install -m 0755 "$src/bin/bbs-ingest" /usr/local/sbin/bbs-ingest
install -m 0755 "$src/sbin/bbs-drop" /usr/local/sbin/bbs-drop
install -m 0755 "$src/sbin/bbs-approve" /usr/local/sbin/bbs-approve
install -m 0755 "$src/bin/bbs-news-status" /usr/local/sbin/bbs-news-status
install -m 0755 "$src/sbin/bbs-news-index" /usr/local/sbin/bbs-news-index
install -m 0755 "$src/sbin/bbs-history-expire" /usr/local/sbin/bbs-history-expire
install -m 0755 "$src/sbin/bbs-maildir" /usr/local/sbin/bbs-maildir
install -m 0644 "$src/lib/news-categories.conf" /usr/local/lib/bashbbs/news-categories.conf
install -m 0755 "$src/lib/wrap.py" /usr/local/lib/bashbbs/wrap.py
install -m 0755 "$src/lib/news.sh" /usr/local/lib/bashbbs/news.sh
# SSH keys: validator (run by users and root), root handler, shared root code.
install -m 0755 "$src/sbin/bbs-keycheck" /usr/local/sbin/bbs-keycheck
install -m 0755 "$src/sbin/bbs-keys-apply" /usr/local/sbin/bbs-keys-apply
install -m 0755 "$src/sbin/bbs-keys" /usr/local/sbin/bbs-keys
install -m 0644 "$src/lib/keys-common.sh" /usr/local/lib/bashbbs/keys-common.sh

# Data layout. Users never write into boards/ or keys/ directly.
install -d -m 0755 /srv/bashbbs /srv/bashbbs/home /srv/bashbbs/keys /srv/bashbbs/users
install -d -m 0755 /srv/bashbbs/boards/general

# Maildir folders for every existing account. Only accounts that already have a
# profile and a home get folders; install.sh never creates accounts or messages.
for profile in /srv/bashbbs/users/*/profile; do
    [[ -f $profile && ! -L $profile ]] || continue
    name=$(sed -n 's/^name=//p' "$profile")
    [[ $name =~ ^[a-z][a-z0-9]{2,8}$ ]] || continue
    id "bbs-$name" >/dev/null 2>&1 || continue
    /usr/local/sbin/bbs-maildir "/srv/bashbbs/home/$name" "bbs-$name:bbs-$name" || [[ ! -d /srv/bashbbs/home/$name ]]
done
install -d -m 0755 /srv/bashbbs/queue

# One-line greetings (the wall). The publisher writes them as root and keeps the newest 100.
install -d -m 0755 /srv/bashbbs/wall

# News ledger and scratch space (state/tmp is on the same filesystem as boards/,
# so the publisher can mv into place atomically). The category allowlist is read
# by bbs-publish and bbs-drop from /srv/bashbbs/lib.
install -d -m 0755 /srv/bashbbs/state /srv/bashbbs/state/tmp /srv/bashbbs/lib
# The sysop may edit this file, so it is copied only when missing. A re-run keeps the edits.
[[ -e /srv/bashbbs/lib/news-categories.conf ]] || install -m 0644 "$src/lib/news-categories.conf" /srv/bashbbs/lib/news-categories.conf
install -d -m 1733 /srv/bashbbs/queue/incoming

# Protected history (old versions of edited posts) and admin backups, written by
# bbs-publish. Root only. install -d sets the mode only on the last level, so each is listed.
install -d -m 0700 /srv/bashbbs/state/history /srv/bashbbs/state/admin-backup

# SSH key requests: users drop .keys files into queue/keys (write only, sticky),
# bbs-keys-apply (root) installs them. History of key files is root only; results
# are readable by the menu. Optional sysop config in etc/keys.conf.
install -d -m 1733 /srv/bashbbs/queue/keys
install -d -m 0700 /srv/bashbbs/state/keys-history
install -d -m 0755 /srv/bashbbs/state/keys-results /srv/bashbbs/etc

# Private boards: one meta file per board (owner, created). Sysops are listed
# one name per line, without the bbs- prefix, and are added to every private board.
install -d -m 0755 /srv/bashbbs/meta
[[ -e /srv/bashbbs/sysops ]] || install -m 0644 /dev/null /srv/bashbbs/sysops

# News board: public to read, posted to only by the news account (.readonly marker).
install -d -m 0755 /srv/bashbbs/boards/news
[[ -e /srv/bashbbs/meta/news.readonly ]] || install -m 0644 /dev/null /srv/bashbbs/meta/news.readonly

# Drop folder: members of group bbsdrop add .txt files for the news board.
# Rejected files go to drop/rejected. News older than 14 days is removed by bbs-drop.
getent group bbsdrop >/dev/null || groupadd bbsdrop
install -d -m 2775 -o root -g bbsdrop /srv/bashbbs/drop/news
install -d -m 0750 -o root -g root /srv/bashbbs/drop/rejected

# Timers: the publisher and the key handler every minute, the drop folder every
# 5 minutes, history retention daily at 04:10.
for u in bbs-publish.service bbs-publish.timer bbs-drop.service bbs-drop.timer bbs-history-expire.service bbs-history-expire.timer bbs-keys.service bbs-keys.timer; do
    install -m 0644 "$src/systemd/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now bbs-publish.timer bbs-drop.timer bbs-history-expire.timer bbs-keys.timer

# Application form. www-data writes new applications into incoming/ (write only,
# no listing). The sysop moves them to done/ or rejected/ with bbs-approve.
getent group www-data >/dev/null || { echo "www-data missing" >&2; exit 1; }
install -d -m 0300 -o www-data -g www-data /srv/bashbbs/applications/incoming
install -d -m 0700 -o root -g root /srv/bashbbs/applications/done
install -d -m 0700 -o root -g root /srv/bashbbs/applications/rejected

# Web front page and CGI, served by lighttpd only if it is installed.
# Config is a separate file, so the stock /etc/lighttpd/lighttpd.conf is left alone.
install -d -m 0755 /var/www/bbs
install -m 0644 "$src/web/index.html" /var/www/bbs/index.html
install -m 0755 "$src/web/apply.cgi" /var/www/bbs/apply.cgi
if command -v lighttpd >/dev/null; then
    install -d -m 0755 /var/log/lighttpd
    keep_or_note "$src/etc/lighttpd-bashbbs.conf" /etc/lighttpd/bashbbs.conf
    # Drop-in: lighttpd's own unit starts the stock config, so override ExecStart.
    install -d -m 0755 /etc/systemd/system/lighttpd.service.d
    install -m 0644 "$src/systemd/lighttpd.service.d/bashbbs.conf" /etc/systemd/system/lighttpd.service.d/bashbbs.conf
    systemctl daemon-reload
    lighttpd -tf /etc/lighttpd/bashbbs.conf
    systemctl enable lighttpd
    # Restart, not reload: on a fresh install the stock unit may already run, and
    # a reload keeps the old ExecStart (stock config) instead of the drop-in.
    systemctl restart lighttpd
else
    echo "lighttpd not installed: web part skipped"
fi

# fail2ban on sshd. The systemd backend needs python3-systemd (see the dependency check).
if command -v fail2ban-client >/dev/null && command -v nft >/dev/null && python3 -c 'import systemd.journal' 2>/dev/null; then
    keep_or_note "$src/etc/fail2ban-jail.local" /etc/fail2ban/jail.local
    systemctl enable --now fail2ban
    systemctl restart fail2ban
else
    echo "fail2ban, nftables or python3-systemd not installed: sshd jail skipped"
fi

# sshd: append the Match block once. It must stay at the end of the file.
if ! grep -q '^Match User bbs-' /etc/ssh/sshd_config; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.pre-bashbbs.$(date +%Y%m%d)"
    cat "$src/etc/sshd-bashbbs.conf" >> /etc/ssh/sshd_config
fi
sshd -t
systemctl reload ssh

# Private messages need local Postfix delivery into Maildir. Warn only: this never edits /etc/postfix.
if command -v postconf >/dev/null; then
    mailbox=$(postconf -h home_mailbox 2>/dev/null || true)
    [[ $mailbox == Maildir/ ]] ||
        echo "WARNING: Postfix home_mailbox is '${mailbox:-unset}', must be 'Maildir/'. Private messages will not arrive. Not changed by install.sh. To set it: postconf -e 'home_mailbox = Maildir/' && systemctl reload postfix" >&2
    postconf -h mydestination 2>/dev/null | grep -q 'myhostname' ||
        echo "WARNING: Postfix mydestination does not include \$myhostname. Check it before using private messages." >&2
else
    echo "WARNING: Postfix not installed. Private messages cannot be delivered." >&2
fi
[[ -x /usr/sbin/sendmail ]] || echo "WARNING: /usr/sbin/sendmail not found. Private messages cannot be sent." >&2
echo "installed"
