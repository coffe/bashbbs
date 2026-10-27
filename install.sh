#!/bin/bash
# Install BashBBS on this host. Run as root from the checkout directory.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
src=$(dirname "$(readlink -f "$0")")

install -d -m 0755 /usr/local/lib/bashbbs
install -m 0755 "$src/lib/menu.sh" /usr/local/lib/bashbbs/menu.sh
install -m 0755 "$src/bin/bbs-shell" /usr/local/sbin/bbs-shell
install -m 0755 "$src/sbin/bbs-provision" /usr/local/sbin/bbs-provision
install -m 0755 "$src/sbin/bbs-publish" /usr/local/sbin/bbs-publish
install -m 0755 "$src/bin/bbs-ingest" /usr/local/sbin/bbs-ingest
install -m 0755 "$src/sbin/bbs-drop" /usr/local/sbin/bbs-drop
install -m 0755 "$src/sbin/bbs-approve" /usr/local/sbin/bbs-approve

# Data layout. Users never write into boards/ or keys/ directly.
install -d -m 0755 /srv/bashbbs /srv/bashbbs/home /srv/bashbbs/keys /srv/bashbbs/users
install -d -m 0755 /srv/bashbbs/boards/general
install -d -m 0755 /srv/bashbbs/queue
install -d -m 1733 /srv/bashbbs/queue/incoming

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

# Timers: the publisher every minute, the drop folder every 5 minutes.
for u in bbs-publish.service bbs-publish.timer bbs-drop.service bbs-drop.timer; do
    install -m 0644 "$src/systemd/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now bbs-publish.timer bbs-drop.timer

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
    install -m 0644 "$src/etc/lighttpd-bashbbs.conf" /etc/lighttpd/bashbbs.conf
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

# fail2ban on sshd. The systemd backend needs python3-systemd on Debian.
if command -v fail2ban-client >/dev/null; then
    dpkg -s python3-systemd >/dev/null 2>&1 || apt-get install -y -q --no-install-recommends python3-systemd
    install -m 0644 "$src/etc/fail2ban-jail.local" /etc/fail2ban/jail.local
    systemctl enable --now fail2ban
    systemctl restart fail2ban
else
    echo "fail2ban not installed: sshd jail skipped"
fi

# sshd: append the Match block once. It must stay at the end of the file.
if ! grep -q '^Match User bbs-' /etc/ssh/sshd_config; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.pre-bashbbs.$(date +%Y%m%d)"
    cat "$src/etc/sshd-bashbbs.conf" >> /etc/ssh/sshd_config
fi
sshd -t
systemctl reload ssh
echo "installed"
