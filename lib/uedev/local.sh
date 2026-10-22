# uedev transport: local — the game's ue4ss folder is a path on this machine: a Linux/Proton
# install or a Steam Deck, Windows from WSL (/mnt/c/...), or any mounted share. Sourced by
# bin/uedev. Needs nothing beyond bash, coreutils and tar.
#
# Settings: UEDEV_UE4SS (the ue4ss folder as a path here), optional UEDEV_PROCESS / UEDEV_SHOTS.

t_init() {
    [[ -d "$UE4SS" ]] || { echo "uedev: UEDEV_UE4SS is not a folder on this machine: $UE4SS (local transport)" >&2; exit 2; }
}

# The game's process name: the *-Shipping.exe beside (or inside) the ue4ss folder.
l_proc() {
    if [[ -n "${UEDEV_PROCESS:-}" ]]; then printf '%s\n' "$UEDEV_PROCESS"; return; fi
    local exe
    for exe in "$UE4SS"/../*-Shipping.exe "$UE4SS"/*-Shipping.exe; do
        [[ -e "$exe" ]] && { basename "$exe" .exe; return; }
    done
}

# pid of the running game (Proton/Wine keep the exe name in the command line), or nothing.
l_pid() {
    local p; p="$(l_proc)"
    [[ -n "$p" ]] && command -v pgrep >/dev/null || return 0
    pgrep -o -f -- "$p" || true
}

l_running() {
    local p; p="$(l_proc)"
    if [[ -z "$p" ]] || ! command -v pgrep >/dev/null; then echo unknown
    elif [[ -n "$(l_pid)" ]]; then echo True
    else echo False; fi
}

# Wait up to TIMEOUT seconds for a file to appear.
l_wait() {
    local i
    for (( i = 0; i < TIMEOUT * 20; i++ )); do
        [[ -e "$1" ]] && return 0
        sleep 0.05
    done
    [[ -e "$1" ]]
}

# Write a file so the reader never sees it half-written: temp file, then rename.
l_put() { printf '%s' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

t_lua() {
    local id="$1" io="$UE4SS/Mods/DevBridge/io"
    [[ -d "$io" ]] || { echo "NO BRIDGE: $io does not exist (run: uedev push DevBridge)"; return 3; }
    l_put "$io/req.lua" "$2"
    if l_wait "$io/$id.out"; then
        cat "$io/$id.out"; rm -f "$io/$id.out"
    else
        rm -f "$io/req.lua"
        echo "TIMEOUT after ${TIMEOUT}s — game running: $(l_running). Not running, bridge not loaded (check: uedev log 200 DevBridge), or the game thread is stuck."
    fi
}

# UE4SS writes CRLF on Windows builds; patterns match case-insensitively, like the ssh transport.
t_log() {
    local n="$1" pat="$2" l="$UE4SS/UE4SS.log"
    if [[ -n "$pat" ]]; then
        tail -n 20000 "$l" | tr -d '\r' | grep -a -i -E -- "$pat" | tail -n "$n" || true
    else
        tail -n "$n" "$l" | tr -d '\r'
    fi
}

t_follow() {
    tail -n 0 -F "$UE4SS/UE4SS.log" 2>/dev/null | sed -u 's/\r$//' | grep --line-buffered -a -i -E -- "$1"
}

t_status() {
    local p pid l="$UE4SS/UE4SS.log" ini="$UE4SS/UE4SS-settings.ini" hr
    p="$(l_proc)"; pid="$(l_pid)"
    if [[ -n "$pid" ]]; then echo "game: running ($p, pid $pid, started $(ps -o lstart= -p "$pid" | awk '{print $4}'))"
    elif [[ -n "$p" ]] && command -v pgrep >/dev/null; then echo "game: not running ($p)"
    else echo "game: unknown (no *-Shipping.exe beside the ue4ss folder; set UEDEV_PROCESS)"; fi
    if [[ -f "$l" ]]; then
        echo "log: $(date -r "$l" +%H:%M:%S)"
        tr -d '\r' < "$l" | grep -a -E -- "$STATUS_LINES" | tail -n 6 || true
    fi
    echo "bridge installed: $([[ -f "$UE4SS/Mods/DevBridge/enabled.txt" ]] && echo True || echo False)"
    echo "armed (io/ARMED): $([[ -e "$UE4SS/Mods/DevBridge/io/ARMED" ]] && echo True || echo False)"
    hr="$( { tr -d '\r' < "$ini" | grep -a -E '^EnableHotReloadSystem[[:space:]]*=' | tail -n 1; } 2>/dev/null || true)"
    if [[ "$hr" =~ =[[:space:]]*1 ]]; then echo "hot reload: $hr  <- $HOT_RELOAD_WARNING"; else echo "hot reload: $hr"; fi
}

t_arm() {
    local a="$UE4SS/Mods/DevBridge/io/ARMED"
    if [[ "$1" == arm ]]; then mkdir -p "$(dirname "$a")" && : > "$a"; else rm -f "$a"; fi
    echo "armed: $([[ -e "$a" ]] && echo True || echo False)"
}

l_copy() {
    local d="$1" name; name="$(basename "$d")"
    mkdir -p "$UE4SS/Mods"
    tar -C "$(dirname "$d")" --exclude="$name/hotswap" -cf - "$name" | tar -C "$UE4SS/Mods" -xf -
}

t_push() {
    local name; name="$(basename "$1")"
    l_copy "$1"
    echo "pushed $name -> $UE4SS/Mods/$name ($(find "$UE4SS/Mods/$name" -type f | wc -l) files)"
}

t_swap() {
    local name id="$2" hs; name="$(basename "$1")"
    l_copy "$1"
    hs="$UE4SS/Mods/$name/hotswap"
    mkdir -p "$hs"
    l_put "$hs/req" "$id"
    if l_wait "$hs/$id.out"; then
        cat "$hs/$id.out"; rm -f "$hs/$id.out"
    else
        rm -f "$hs/req"
        echo "TIMEOUT after ${TIMEOUT}s — game running: $(l_running). Files are pushed, but the running $name did not answer: $SWAP_SILENT_HINT"
    fi
}

# Screenshot folder: UEDEV_SHOTS, else <LOCALAPPDATA>/<Project>/Saved/Screenshots/Windows on
# Windows, else the same folder inside the game's Proton prefix (steamapps/compatdata/*/pfx).
l_shots_dir() {
    [[ -n "${UEDEV_SHOTS:-}" ]] && { printf '%s\n' "$UEDEV_SHOTS"; return; }
    local proj d rel
    proj="$(l_proc)"; proj="${proj%-Win64-Shipping}"; proj="${proj%-WinGDK-Shipping}"
    [[ -n "$proj" ]] || return 0
    rel="$proj/Saved/Screenshots/Windows"
    if [[ -n "${LOCALAPPDATA:-}" ]]; then
        d="$LOCALAPPDATA"; command -v cygpath >/dev/null && d="$(cygpath -u "$d")"
        [[ -d "$d/$rel" ]] && { printf '%s\n' "$d/$rel"; return; }
    fi
    if [[ "$UE4SS" == */steamapps/* ]]; then
        for d in "${UE4SS%%/steamapps/*}"/steamapps/compatdata/*/pfx/drive_c/users/steamuser/AppData/Local/"$rel"; do
            [[ -d "$d" ]] && { printf '%s\n' "$d"; return; }
        done
    fi
}

t_shot_newest() {
    local d f; d="$(l_shots_dir)"
    [[ -n "$d" && -d "$d" ]] || return 0
    f="$(ls -1t "$d"/*.png 2>/dev/null | head -n 1 || true)"
    [[ -n "$f" ]] && printf '%s|%s\n' "$f" "$(stat -c %Y "$f")"
    return 0
}

t_fetch() { cp -f "$1" "$2"; }

t_ps() { echo "uedev ps runs PowerShell on a remote Windows box: it needs the ssh transport (docs/ssh.md)" >&2; exit 2; }
