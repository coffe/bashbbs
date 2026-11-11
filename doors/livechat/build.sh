#!/bin/bash
# Builds the LiveChat68 door for BashBBS, natively on the machine that will run it.
# Usage: build.sh <unpacked LiveChat68/src> <output binary>
# LIVECHAT_CFG sets where the door keeps its settings.
# Without libssl-dev installed, point OPENSSL_ROOT at an unpacked libssl-dev .deb.
set -euo pipefail
src=$1
out=$2
cfg=${LIVECHAT_CFG:-/var/lib/livechat/LIVECHAT.cfg}
here=$(cd "$(dirname "$0")" && pwd)
multiarch=$(gcc -print-multiarch)

ssl_cflags=() ssl_libs=(-lssl -lcrypto)
if [[ -n ${OPENSSL_ROOT:-} ]]; then
    ssl_cflags=(-I"$OPENSSL_ROOT/usr/include" -I"$OPENSSL_ROOT/usr/include/$multiarch")
    ssl_libs=("/usr/lib/$multiarch/libssl.so.3" "/usr/lib/$multiarch/libcrypto.so.3")
fi

objs=(ae_host ui_cells ae_chat ae_request ae_http ae_net ae_net_tls json_lite ae_dos
      ae_session ae_session_bbs ae_board_screen ae_usernote ae_chatprefs ui_ansi ui_chrome
      ui_key ui_input ui_list ui_profile ui_screen ui_theme ae_dos_native)
sources=("${objs[@]/#/$src/src/}")
sources=("${sources[@]/%/.c}")

# The door puts Latin-1 bytes straight into its JSON, which is not valid UTF-8, so
# the hub turns them into '?'. Send them as \u00XX escapes instead.
patched=$(mktemp -d)
trap 'rm -rf "$patched"' EXIT
sed '/ae_req_put_json_string(char/,/^}/ s/if (\*p < 0x20) {/if (*p < 0x20 || *p >= 0x80) {/' \
    "$src/src/ae_request.c" > "$patched/ae_request.c"
grep -q '\*p >= 0x80' "$patched/ae_request.c"
sources=("${sources[@]/#$src\/src\/ae_request.c/$patched/ae_request.c}")

gcc -std=c99 -O2 -D_DEFAULT_SOURCE -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -DLIVECHAT_CFG_PATH="\"$cfg\"" \
    -I"$src/include" -I"$src/src" -I"$src/examples/livechat" "${ssl_cflags[@]}" \
    "$here/ae_transport_bashbbs.c" "${sources[@]}" \
    "$src/examples/livechat/livechat.c" "$src/examples/livechat/livechat_ui.c" \
    "${ssl_libs[@]}" -o "$out"
strip "$out"
