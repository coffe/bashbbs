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

# Data layout. Users never write into boards/ or keys/ directly.
install -d -m 0755 /srv/bashbbs /srv/bashbbs/home /srv/bashbbs/keys /srv/bashbbs/users
install -d -m 0755 /srv/bashbbs/boards/general
install -d -m 0755 /srv/bashbbs/queue
install -d -m 1733 /srv/bashbbs/queue/incoming

# Private boards: one meta file per board (owner, created). Sysops are listed
# one name per line, without the bbs- prefix, and are added to every private board.
install -d -m 0755 /srv/bashbbs/meta
[[ -e /srv/bashbbs/sysops ]] || install -m 0644 /dev/null /srv/bashbbs/sysops

# sshd: append the Match block once. It must stay at the end of the file.
if ! grep -q '^Match User bbs-' /etc/ssh/sshd_config; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.pre-bashbbs.$(date +%Y%m%d)"
    cat "$src/etc/sshd-bashbbs.conf" >> /etc/ssh/sshd_config
fi
sshd -t
systemctl reload ssh
echo "installed"
