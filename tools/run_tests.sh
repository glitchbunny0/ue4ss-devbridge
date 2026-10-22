#!/usr/bin/env bash
# Off-game suite. Uses lua/lua5.4 if installed, else builds 5.4.7 into $TMPDIR.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LUA="$(command -v lua || command -v lua5.4 || true)"
LUAC="$(command -v luac || command -v luac5.4 || true)"
if [[ -z "$LUA" ]]; then
    CACHE="${TMPDIR:-/tmp}/lua-5.4.7"
    if [[ ! -x "$CACHE/src/lua" ]]; then
        echo "no lua found — building 5.4.7 into $CACHE"
        mkdir -p "$(dirname "$CACHE")"
        curl -sL https://www.lua.org/ftp/lua-5.4.7.tar.gz | tar xz -C "$(dirname "$CACHE")"
        make -s -C "$CACHE" linux
    fi
    LUA="$CACHE/src/lua"; LUAC="$CACHE/src/luac"
fi
"$LUAC" -p DevBridge/Scripts/*.lua tests/fake_game.lua
bash -n bin/uedev lib/uedev/*.sh tests/test_uedev_local.sh
"$LUA" tests/test_devbridge.lua
"$LUA" tests/test_main.lua
LUA="$LUA" bash tests/test_uedev_local.sh
