# uedev transport: ssh — the game runs on a Windows box reached over SSH; every operation
# is a PowerShell script sent to it. Sourced by bin/uedev; see docs/ssh.md.
#
# Settings: UEDEV_HOST (ssh target, required), UEDEV_UE4SS (the WINDOWS path of the ue4ss
# folder), optional UEDEV_PROCESS / UEDEV_SHOTS. Needs ssh, scp and iconv on this side,
# an OpenSSH server with key login and Windows PowerShell on the other.

t_init() {
    [[ -n "${UEDEV_HOST:-}" ]] || { echo "uedev: UEDEV_HOST is not set (ssh transport; see docs/ssh.md)" >&2; exit 2; }
    HOST="$UEDEV_HOST"
    SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")
    U="$(psq "$UE4SS")"
    # Prepended to every remote script: $proc (the game's process name) and Get-Game.
    PRELUDE="\$proc = $(psq "${UEDEV_PROCESS:-}")
if (-not \$proc) {
  \$exe = Get-ChildItem -File -Filter '*-Shipping.exe' -Path (Split-Path $U), $U -ErrorAction SilentlyContinue | Select-Object -First 1
  if (\$exe) { \$proc = \$exe.BaseName }
}
function Get-Game { if (\$proc) { Get-Process -Name \$proc -ErrorAction SilentlyContinue } }"
}

# PowerShell single-quoted literal of a string.
psq() { printf "'%s'" "${1//\'/\'\'}"; }

# Run a PowerShell script (stdin) remotely. The script travels base64 on stdin;
# only a fixed bootstrap rides the command line, which cmd.exe caps at 8191 chars.
ps() {
    local boot enc
    boot='$ProgressPreference="SilentlyContinue"; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())); & ([ScriptBlock]::Create($s))'
    enc="$(printf '%s' "$boot" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
    { printf '%s\n' "$PRELUDE"; cat; } | base64 -w0 | "${SSH[@]}" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" \
        2> >(grep -v -E '^#< CLIXML|^<Objs ' >&2) | tr -d '\r'
}

t_ps() { ps; }

# t_lua ID REQUEST — drop a request for the bridge, print its answer (or a TIMEOUT line).
t_lua() {
    local id="$1" b64
    b64="$(printf '%s' "$2" | base64 -w0)"
    ps <<EOF
\$io = Join-Path $U 'Mods\DevBridge\io'
if (-not (Test-Path \$io)) { 'NO BRIDGE: ' + \$io + ' does not exist (run: uedev push DevBridge)'; exit 3 }
\$req = Join-Path \$io 'req.lua'; \$tmp = Join-Path \$io 'req.lua.tmp'; \$out = Join-Path \$io '$id.out'
[IO.File]::WriteAllBytes(\$tmp, [Convert]::FromBase64String('$b64'))
Move-Item -Force \$tmp \$req
\$deadline = (Get-Date).AddSeconds($TIMEOUT)
while (-not (Test-Path \$out) -and (Get-Date) -lt \$deadline) { Start-Sleep -Milliseconds 40 }
if (Test-Path \$out) {
  [Console]::Out.Write([IO.File]::ReadAllText(\$out, [Text.Encoding]::UTF8)); Remove-Item \$out
} else {
  Remove-Item \$req -ErrorAction SilentlyContinue
  \$g = [bool](Get-Game)
  "TIMEOUT after ${TIMEOUT}s — game running: \$g. Not running, bridge not loaded (check: uedev log 200 DevBridge), or the game thread is stuck."
}
EOF
}

t_log() {
    local n="$1" pat="$2"
    ps <<EOF
\$l = Join-Path $U 'UE4SS.log'
\$lines = Get-Content -Encoding UTF8 -Tail $( [[ -n "$pat" ]] && echo 20000 || echo "$n" ) \$l
$( [[ -n "$pat" ]] && echo "\$lines = @(\$lines | Where-Object { \$_ -match $(psq "$pat") }) | Select-Object -Last $n" )
\$lines
EOF
}

t_follow() {
    ps <<EOF
Get-Content -Encoding UTF8 -Tail 0 -Wait (Join-Path $U 'UE4SS.log') | Where-Object { \$_ -match $(psq "$1") }
EOF
}

# Everything `uedev status` shows before it asks the bridge itself.
t_status() {
    ps <<EOF
\$p = Get-Game
if (\$p) { "game: running (\$proc, pid \$(\$p.Id), started \$(\$p.StartTime.ToString('HH:mm:ss')))" }
elseif (\$proc) { "game: not running (\$proc)" }
else { 'game: unknown (no *-Shipping.exe beside the ue4ss folder; set UEDEV_PROCESS)' }
\$l = Join-Path $U 'UE4SS.log'
if (Test-Path \$l) {
  "log: \$((Get-Item \$l).LastWriteTime.ToString('HH:mm:ss'))"
  Get-Content -Encoding UTF8 \$l | Where-Object { \$_ -match '$STATUS_LINES' } | Select-Object -Last 6
}
"bridge installed: \$(Test-Path (Join-Path $U 'Mods\DevBridge\enabled.txt'))"
"armed (io/ARMED): \$(Test-Path (Join-Path $U 'Mods\DevBridge\io\ARMED'))"
\$hr = (Select-String -Path (Join-Path $U 'UE4SS-settings.ini') -Pattern '^EnableHotReloadSystem\s*=' -ErrorAction SilentlyContinue).Line
if (\$hr -match '=\s*1') { "hot reload: \$hr  <- $HOT_RELOAD_WARNING" } else { "hot reload: \$hr" }
EOF
}

t_arm() {
    ps <<EOF
\$a = Join-Path $U 'Mods\DevBridge\io\ARMED'
if ('$1' -eq 'arm') { New-Item -ItemType File -Force \$a | Out-Null } else { Remove-Item -Force -ErrorAction SilentlyContinue \$a }
"armed: \$(Test-Path \$a)"
EOF
}

# A mod folder travels as a base64 tar and is unpacked with Windows' own tar.
t_push_script() {
    local d="$1" name payload
    name="$(basename "$d")"
    payload="$(tar -C "$(dirname "$d")" --exclude="$name/hotswap" -cf - "$name" | base64 -w0)"
    cat <<EOF
\$mods = Join-Path $U 'Mods'
\$tar = Join-Path \$env:TEMP 'uedev-push.tar'
[IO.File]::WriteAllBytes(\$tar, [Convert]::FromBase64String('$payload'))
tar -xf \$tar -C \$mods
Remove-Item \$tar
EOF
}

t_push() {
    local name; name="$(basename "$1")"
    { t_push_script "$1"; cat <<EOF
\$n = (Get-ChildItem -Recurse -File (Join-Path \$mods '$name')).Count
"pushed $name -> \$mods\\$name (\$n files)"
EOF
    } | ps
}

# t_swap DIR ID — push, then request a swap from the mod's shell; print its answer. One round trip.
t_swap() {
    local name id="$2"; name="$(basename "$1")"
    { t_push_script "$1"; cat <<EOF
\$hs = Join-Path \$mods '$name\hotswap'
New-Item -ItemType Directory -Force \$hs | Out-Null
\$req = Join-Path \$hs 'req'; \$tmp = Join-Path \$hs 'req.tmp'; \$out = Join-Path \$hs '$id.out'
[IO.File]::WriteAllBytes(\$tmp, [Text.Encoding]::ASCII.GetBytes('$id'))
Move-Item -Force \$tmp \$req
\$deadline = (Get-Date).AddSeconds($TIMEOUT)
while (-not (Test-Path \$out) -and (Get-Date) -lt \$deadline) { Start-Sleep -Milliseconds 40 }
if (Test-Path \$out) {
  [Console]::Out.Write([IO.File]::ReadAllText(\$out, [Text.Encoding]::UTF8)); Remove-Item \$out
} else {
  Remove-Item \$req -ErrorAction SilentlyContinue
  \$g = [bool](Get-Game)
  "TIMEOUT after ${TIMEOUT}s — game running: \$g. Files are pushed, but the running $name did not answer: $SWAP_SILENT_HINT"
}
EOF
    } | ps
}

# Newest screenshot as "path|stamp" (empty if none); default folder %LOCALAPPDATA%\<Project>\Saved\Screenshots\Windows.
t_shot_newest() {
    ps <<EOF
\$d = $(psq "${UEDEV_SHOTS:-}")
if (-not \$d) { \$d = Join-Path \$env:LOCALAPPDATA ((\$proc -replace '-(Win64|WinGDK)-Shipping\$', '') + '\Saved\Screenshots\Windows') }
\$f = Get-ChildItem -File -Filter *.png \$d -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (\$f) { "\$(\$f.FullName.Replace('\','/'))|\$(\$f.LastWriteTime.Ticks)" }
EOF
}

t_fetch() { scp -q -o BatchMode=yes "$HOST:$1" "$2"; }
