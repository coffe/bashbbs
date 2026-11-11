#!/bin/bash
# Forced command for the livechat account on the door host. The BBS logs in over the
# tunnel and asks for "<user> <level>"; nothing else gets through.
set -u
re='^([A-Za-z0-9_-]{1,32}) ([0-9]{1,3})$'
[[ ${SSH_ORIGINAL_COMMAND:-} =~ $re ]] || exit 64
cd /var/lib/livechat || exit 1
BBS_DOOR_USER=${BASH_REMATCH[1]} BBS_DOOR_LEVEL=${BASH_REMATCH[2]} \
    exec /usr/local/lib/livechat/livechat68 1 2>/dev/null
