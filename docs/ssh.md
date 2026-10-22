# The ssh transport

For a game running on another machine with Windows: `uedev` turns each operation into a
PowerShell script and runs it there over SSH. The code is `lib/uedev/ssh.sh`; nothing else in the
repo depends on it, and the bridge itself does not know it exists.

## Requirements

- **This machine:** `ssh`, `scp`, `iconv` and GNU `base64` (`-w0`), besides what `uedev` needs anyway.
- **The game machine:** an OpenSSH server you can log into with a key and no prompts (`uedev`
  connects with `BatchMode=yes`), and the built-in Windows PowerShell. Setting up the server is
  outside this repo; any standard OpenSSH-on-Windows guide applies.

## Settings

```sh
cat > ~/.config/uedev/config <<'EOF'
UEDEV_HOST=player@192.168.1.20
UEDEV_UE4SS="C:\Program Files (x86)\Steam\steamapps\common\<Game>\<Project>\Binaries\Win64\ue4ss"
EOF
```

Setting `UEDEV_HOST` selects this transport (or set `UEDEV_TRANSPORT=ssh`). `UEDEV_UE4SS` is the
**Windows** path of the `ue4ss` folder on the game machine. The game's process and screenshot
folder (`%LOCALAPPDATA%\<Project>\Saved\Screenshots\Windows`) are detected there;
`UEDEV_PROCESS` / `UEDEV_SHOTS` override them.

## How it works

- Windows OpenSSH runs commands through `cmd.exe` (pipes are cmd's, and the command line is capped
  at 8191 characters). `uedev` therefore sends one fixed `-EncodedCommand` bootstrap and passes the
  real script — and any payload — base64 on stdin. Nothing user-supplied is interpolated into the
  command line.
- Requests and hot-swap requests are written and renamed on the game machine, exactly as the
  protocol in the README describes; `uedev` waits there and returns the answer in the same round
  trip.
- Mod folders travel as a base64 tar and are unpacked with Windows' own `tar`.
- Screenshots come back with `scp`.
- `uedev ps < script.ps1` runs any PowerShell on the game machine, with `$proc` (the game's
  process name) and `Get-Game` predefined.

## Security

The SSH login is the way into the bridge from outside: whoever can log in can write its folder
and so run code in the game. Keep the login key-only and the server reachable from your own
network only.
