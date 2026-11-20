# Partyline door

Runs spotUP's [Partyline](https://doors.uprough.net) door (MIT) on BashBBS. It
replaced the older LiveChat68 door; the account, tunnel and paths kept the
livechat name.
The door's own source is not kept here. `ae_transport_bashbbs.c` replaces its
Amiga transport with one that talks to the caller's terminal.

For now it is only reachable from the sysop menu.

The door keeps a TLS connection to its hub, which is too heavy for a Pi Zero, so it runs on
another machine. That machine opens a reverse SSH tunnel to the BBS, and the BBS
logs in through it. The BBS never connects out to the LAN.

## Build

Build on the machine that will run the door:

    doors/livechat/build.sh <unpacked partyline archive>/source/sdk-c <prepared dir>/partyline

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

The door keeps its settings in `/var/lib/livechat/PARTYLINE.cfg` on the door host.
Chat goes to the hub on `Port=6400` with `Tls=1`. Port 443 only serves HTTPS, which
includes the registration, so a 1.0.0 build needs the port set explicitly.
The sysop's first run (the BBS always starts it at level 255) registers the board
with the hub and writes the board's key into that file, so it must never be shared
or committed.
