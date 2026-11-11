#!/bin/bash
# Sets up the LiveChat door host. Run once with sudo; safe to run again.
# Usage: sudo setup-jelly.sh <bbs host> <prepared dir> <login user> <ssh alias for the bbs>
# The prepared dir holds: livechat68 (native build), door.pub (the BBS's door key)
# and bbs-host-key (the BBS's "type key" SSH host key).
set -euo pipefail
bbs=$1 dir=$2 owner=$3 alias=$4
here=$(cd "$(dirname "$0")" && pwd)
home=/var/lib/livechat lib=/usr/local/lib/livechat

id livechat >/dev/null 2>&1 ||
    useradd --system --create-home --home-dir "$home" --shell /bin/bash livechat
usermod -p '*' livechat # no password, but not a locked account: sshd must accept the key

install -d -m 755 "$lib"
install -m 755 "$dir/livechat68" "$lib/livechat68"
install -m 755 "$here/jelly-door.sh" "$lib/door"

install -d -m 700 -o livechat -g livechat "$home/.ssh"
{ printf 'restrict,pty,from="127.0.0.1,::1",command="%s/door" ' "$lib"; cat "$dir/door.pub"; } |
    install -m 600 -o livechat -g livechat /dev/stdin "$home/.ssh/authorized_keys"
{ printf '%s ' "$bbs"; cat "$dir/bbs-host-key"; } |
    install -m 600 -o livechat -g livechat /dev/stdin "$home/.ssh/known_hosts"

key=$(getent passwd "$owner" | cut -d: -f6)/.ssh/livechat_tunnel
if [[ -e $key ]]; then
    mv "$key" "$home/.ssh/tunnel"
    chown livechat:livechat "$home/.ssh/tunnel"
    chmod 600 "$home/.ssh/tunnel"
fi
[[ -s $home/.ssh/tunnel ]]

# The settings hold the board's key: copied without ever being shown or logged.
cfg=$home/LIVECHAT.cfg
if [[ ! -s $cfg ]]; then
    install -m 600 -o livechat -g livechat /dev/null "$cfg"
    sudo -u "$owner" ssh -T "$alias" 'sudo -n cat /srv/bashbbs/livechat/LIVECHAT.cfg' > "$cfg"
    [[ -s $cfg ]]
fi

echo "LIVECHAT_BBS_HOST=$bbs" > /etc/livechat-tunnel.env
install -m 644 "$here/livechat-tunnel.service" /etc/systemd/system/livechat-tunnel.service
systemctl daemon-reload
systemctl enable --now livechat-tunnel.service
sleep 3
systemctl is-active livechat-tunnel.service
