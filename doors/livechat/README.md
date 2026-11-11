# LiveChat door

Runs spotUP's [LiveChat68](https://doors.uprough.net) door (MIT) on BashBBS.
The door's own source is not kept here. `ae_transport_bashbbs.c` replaces its
Amiga transport with one that talks to the caller's terminal.

For now it is only reachable from the sysop menu.

The door polls its hub over HTTPS, which is too heavy for a Pi Zero, so it runs on
another machine. That machine opens a reverse SSH tunnel to the BBS, and the BBS
logs in through it. The BBS never connects out to the LAN.

## Build

Build on the machine that will run the door:

    doors/livechat/build.sh <unpacked LiveChat68/src> <prepared dir>/livechat68

## Door host

`setup-jelly.sh` (run with sudo) creates the `livechat` account, installs the door
and the forced command `jelly-door.sh`, and starts `livechat-tunnel.service`. The
prepared directory also holds `door.pub`, the public half of
`/srv/bashbbs/livechat/id_ed25519` on the BBS, and `bbs-host-key`, the BBS's SSH
host key.

On the BBS, the tunnel's key goes in the login user's `authorized_keys`, limited to
this one forward:

    restrict,port-forwarding,permitlisten="127.0.0.1:2277",from="<door host>",command="/bin/false" <key>

`/srv/bashbbs/livechat/known_hosts` pins the door host's key as `[127.0.0.1]:2277`.
That directory must be mode 0700 and belong to the sysop, because the door key lets
its holder start the door.

## Settings

The door keeps its settings in `/var/lib/livechat/LIVECHAT.cfg` on the door host.
It holds the board's key, so it must never be shared or committed.
