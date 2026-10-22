#!/usr/bin/env bash
# End to end: uedev's local transport against the real DevBridge mod running in a fake game
# (tests/fake_game.lua). Exercises the file protocol exactly as a game box sees it.
#   LUA=/path/to/lua5.4 bash tests/test_uedev_local.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LUA="${LUA:?set LUA to a Lua 5.4 binary}"

T="$(mktemp -d "${TMPDIR:-/tmp}/uedev-e2e.XXXXXX")"
U="$T/Game/Project/Binaries/Win64/ue4ss"
mkdir -p "$U/Mods"
: > "$T/Game/Project/Binaries/Win64/FakeGame-Win64-Shipping.exe"
printf 'EnableHotReloadSystem = 0\r\n' > "$U/UE4SS-settings.ini"   # CRLF, as on Windows
game=""
cleanup() { : > "$U/STOP"; [[ -n "$game" ]] && wait "$game" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

export UEDEV_CONFIG=/nonexistent UEDEV_TRANSPORT=local UEDEV_UE4SS="$U" UEDEV_TIMEOUT=5
unset UEDEV_HOST UEDEV_PROCESS UEDEV_SHOTS
uedev() { ./bin/uedev "$@"; }

passed=0; failed=0
check() {   # name, condition (bash), shown on failure
    if eval "$2"; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL %s\n  got: %s\n' "$1" "${3:-}"; fi
}

out="$(uedev push DevBridge)"
check "push installs the bridge" '[[ -f "$U/Mods/DevBridge/Scripts/main.lua" && "$out" == "pushed DevBridge -> "* ]]' "$out"

"$LUA" tests/fake_game.lua "$U" 60 FakeGame-Win64-Shipping >/dev/null 2>&1 &
game=$!
for _ in $(seq 1 40); do grep -q 'DevBridge\] v' "$U/UE4SS.log" 2>/dev/null && break; sleep 0.05; done

out="$(uedev -e 'return 1')"
check "disarmed bridge answers DISARMED and runs nothing" '[[ "$out" == DISARMED* ]]' "$out"
out="$(uedev arm)";   check "arm" '[[ "$out" == "armed: True" ]]' "$out"

out="$(uedev -e 'return 1 + 1')"
check "a request runs on the game thread and returns" '[[ "$out" == *"=> 2"*OK* ]]' "$out"
out="$(uedev -e 'print("hi"); return find("Nothing")')"
check "print is captured; find() on no match is nil" '[[ "$out" == *hi*"=> nil"* ]]' "$out"
out="$(printf 'X = 41\nreturn X + 1' | uedev run -)"
check "run - reads stdin; globals persist" '[[ "$out" == *"=> 42"* ]] && [[ "$(uedev -e "return X")" == *"=> 41"* ]]' "$out"
out="$(uedev -e 'error("boom")')"
check "errors come back as ERROR" '[[ "$out" == *ERROR:*boom* ]]' "$out"
check "no request or answer files left behind" '[[ -z "$(ls "$U/Mods/DevBridge/io" | grep -v -E "^(ARMED|\.keep)$")" ]]' "$(ls -A "$U/Mods/DevBridge/io")"

out="$(uedev status)"
check "status: game found by its exe name" '[[ "$out" == *"game: running (FakeGame-Win64-Shipping, pid "* ]]' "$out"
check "status: bridge installed, armed, hot reload read (CRLF ini)" '[[ "$out" == *"bridge installed: True"* && "$out" == *"armed (io/ARMED): True"* && "$out" == *"hot reload: EnableHotReloadSystem = 0"* ]]' "$out"
check "status: bridge handshake" '[[ "$out" == *"bridge: answering (v0.3.0, protocol 1)"* ]]' "$out"
check "status: load line from the log" '[[ "$out" == *"[DevBridge] v0.3.0"* ]]' "$out"

out="$(uedev log 3 'devbridge.*polling')"
check "log REGEX (case-insensitive) finds the load line" '[[ "$out" == *"[DevBridge] v0.3.0 (protocol 1) loaded — polling"* ]]' "$out"
out="$(uedev log 2)"
check "log N without a pattern: the last N lines" '[[ $(wc -l <<<"$out") == 2 ]]' "$out"
out="$(uedev clean)"
check "clean" '[[ "$out" == *"cleanup: 0 hooks unregistered"* ]]' "$out"

( timeout 3 ./bin/uedev follow 'served' > "$T/follow.txt" 2>&1 ) &
fpid=$!
sleep 0.7
uedev -e 'return 3' >/dev/null
wait "$fpid" 2>/dev/null
check "follow streams new log lines" 'grep -q "served" "$T/follow.txt"' "$(cat "$T/follow.txt")"

mkdir -p "$T/src/FakeShell/Scripts" "$T/src/NotAShell"
echo 'return {}' > "$T/src/FakeShell/Scripts/main.lua"; : > "$T/src/NotAShell/enabled.txt"
mkdir -p "$T/src/FakeShell/hotswap" && : > "$T/src/FakeShell/hotswap/junk"
out="$(uedev swap "$T/src/FakeShell")"; rc=$?
check "swap: files pushed, shell answers OK, exit 0" '[[ $rc == 0 && "$out" == "OK fake 1.0 -> 1.1"*"ms round trip)"* && -f "$U/Mods/FakeShell/Scripts/main.lua" ]]' "$rc $out"
check "swap: a local hotswap/ folder is never pushed" '[[ ! -e "$U/Mods/FakeShell/hotswap/junk" ]]' "$(ls -A "$U/Mods/FakeShell/hotswap")"
out="$(UEDEV_TIMEOUT=1 uedev swap "$T/src/NotAShell")"; rc=$?
check "swap: a mod without a shell times out, exit 1, request withdrawn" '[[ $rc == 1 && "$out" == TIMEOUT*"not a hot-swap shell"* && ! -e "$U/Mods/NotAShell/hotswap/req" ]]' "$rc $out"

out="$(uedev disarm)"; check "disarm" '[[ "$out" == "armed: False" ]]' "$out"
out="$(uedev -e 'return 1')"; check "disarmed again: nothing runs" '[[ "$out" == DISARMED* ]]' "$out"

printf 'EnableHotReloadSystem = 1\r\n' > "$U/UE4SS-settings.ini"
out="$(uedev status)"; check "status flags hot reload ON as unsafe" '[[ "$out" == *"EnableHotReloadSystem = 1  <- UNSAFE"* ]]' "$out"

: > "$U/STOP"; wait "$game" 2>/dev/null; game=""
out="$(UEDEV_TIMEOUT=1 uedev -e 'return 1')"
check "game gone: TIMEOUT says the game is not running" '[[ "$out" == "TIMEOUT after 1s — game running: False"* ]]' "$out"

out="$(uedev ps </dev/null 2>&1)"; rc=$?
check "ps needs the ssh transport" '[[ $rc == 2 && "$out" == *"needs the ssh transport"* ]]' "$rc $out"
out="$(UEDEV_UE4SS="$T/nope" uedev status 2>&1)"; rc=$?
check "a missing ue4ss folder is refused" '[[ $rc == 2 && "$out" == *"not a folder on this machine"* ]]' "$rc $out"
out="$(UEDEV_TRANSPORT=carrier-pigeon uedev status 2>&1)"; rc=$?
check "an unknown transport is refused and the known ones listed" '[[ $rc == 2 && "$out" == *"have: local ssh"* ]]' "$rc $out"
out="$(env -u UEDEV_UE4SS ./bin/uedev status 2>&1)"; rc=$?
check "no UEDEV_UE4SS: refused with a pointer to help" '[[ $rc == 2 && "$out" == *"UEDEV_UE4SS is not set"* ]]' "$rc $out"

echo "uedev local e2e: $passed passed, $failed failed"
[[ $failed == 0 ]]
