#!/bin/bash
# Builds spotUP's Partyline door for BashBBS, natively on the machine that will run it.
# Usage: build.sh <unpacked partyline archive>/source/sdk-c <output binary>
# PARTYLINE_CFG sets where the door keeps its settings.
# Without libssl-dev installed, point OPENSSL_ROOT at an unpacked libssl-dev .deb.
set -euo pipefail
src=$1
out=$2
cfg=${PARTYLINE_CFG:-/var/lib/livechat/PARTYLINE.cfg}
here=$(cd "$(dirname "$0")" && pwd)
multiarch=$(gcc -print-multiarch)

ssl_cflags=() ssl_libs=(-lssl -lcrypto)
if [[ -n ${OPENSSL_ROOT:-} ]]; then
    ssl_cflags=(-I"$OPENSSL_ROOT/usr/include" -I"$OPENSSL_ROOT/usr/include/$multiarch")
    ssl_libs=("/usr/lib/$multiarch/libssl.so.3" "/usr/lib/$multiarch/libcrypto.so.3")
fi

objs=(ae_host ae_session ae_session_bbs ae_net ae_net_tls ae_plp ae_dos ae_dos_native
      ae_http json_lite ui_profile ui_cells ui_ansi)
sources=("${objs[@]/#/$src/src/}")
sources=("${sources[@]/%/.c}")

# The door hard-codes an AmigaDOS path for its settings.
patched=$(mktemp -d)
trap 'rm -rf "$patched"' EXIT
sed "s|^#define CFG_PATH \"PROGDIR:PARTYLINE.cfg\"|#define CFG_PATH \"$cfg\"|" \
    "$src/examples/partyline/partyline.c" > "$patched/partyline.c"
grep -qF "#define CFG_PATH \"$cfg\"" "$patched/partyline.c"

gcc -std=c99 -O2 -D_DEFAULT_SOURCE -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -I"$src/include" -I"$src/src" "${ssl_cflags[@]}" \
    "$here/ae_transport_bashbbs.c" "${sources[@]}" "$patched/partyline.c" \
    "${ssl_libs[@]}" -o "$out"
strip "$out"
