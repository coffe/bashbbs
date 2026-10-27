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

# sshd: append the Match block once. It must stay at the end of the file.
if ! grep -q '^Match User bbs-' /etc/ssh/sshd_config; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.pre-bashbbs.$(date +%Y%m%d)"
    cat "$src/etc/sshd-bashbbs.conf" >> /etc/ssh/sshd_config
fi
sshd -t
systemctl reload ssh
echo "installed"
