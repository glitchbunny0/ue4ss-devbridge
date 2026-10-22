# ue4ss-devbridge

A development-only REPL into a running UE4SS game.

`DevBridge` is a tiny UE4SS Lua mod that polls `Mods/DevBridge/io/req.lua` every 100 ms on the
**game thread**, runs whatever Lua it finds in a persistent environment, and writes the result to
`io/<id>.out`. That folder is the whole interface: anything that can put a file there can drive
the game (see [The protocol](#the-protocol)). `bin/uedev` is a ready-made client for it that also
reads and follows the UE4SS log, pushes mod folders, hot-swaps shell-based mods and takes
screenshots.

How `uedev` reaches the game's `ue4ss` folder is a separate, swappable **transport**:

- `local` (default) — the folder is a path on this machine: a Linux/Proton install, a Steam Deck,
  Windows seen from WSL (`/mnt/c/...`), or any mounted share. Plain file operations.
- `ssh` — the game runs on another, Windows machine; each operation becomes a PowerShell script
  sent over SSH. Kept apart in `lib/uedev/ssh.sh`, documented in [docs/ssh.md](docs/ssh.md).

Developed against a UE 5.6 game with UE4SS v3.0.1 (experimental build 1181). The bridge and the
client are game-agnostic; the scripts in `examples/` are written for *RV There Yet?* and show the
patterns.

> **Never ship this to players.** It executes any Lua that lands in its folder.

## Requirements

- **Game:** UE4SS installed for it. The bridge is a plain UE4SS Lua mod.
- **uedev:** bash, GNU coreutils, `tar`, and `pgrep` for detecting the game process. `ffmpeg` is
  optional; `uedev shot` uses it to scale screenshots. The ssh transport adds its own list.
- **Tests:** Lua 5.4; `tools/run_tests.sh` builds one into `$TMPDIR` if none is installed.

## Configure

```sh
mkdir -p ~/.config/uedev
cat > ~/.config/uedev/config <<'EOF'
UEDEV_UE4SS="/path/to/steamapps/common/<Game>/<Project>/Binaries/Win64/ue4ss"
EOF
```

The file holds `KEY=value` lines and is parsed, never executed; environment variables of the same
name win. The game's process name and its screenshot folder are worked out from the
`*-Shipping.exe` beside the `ue4ss` folder (on Proton, the screenshot folder is found inside the
game's prefix); `UEDEV_PROCESS` and `UEDEV_SHOTS` override them. `uedev help` lists every setting.
For a game on a remote Windows machine, see [docs/ssh.md](docs/ssh.md).

## Install

```sh
uedev push DevBridge     # from this repo; loads at the next game start
uedev status             # after the start: bridge installed, answering, armed?
uedev arm                # let it run requests (uedev disarm stops it)
```

Leave UE4SS hot reload off (`EnableHotReloadSystem = 0` in `UE4SS-settings.ini`); see Limits.

## Use

```sh
uedev status                                   # game running? which mods loaded? bridge answering?
uedev -e 'return find("PlayerController")'
uedev -e 'local pc = find("PlayerController"); return props(pc, {"Pawn", "ControlRotation"})'
uedev run probe.lua                            # or: ... | uedev run -
uedev log 80 MyMod                             # last 80 matching log lines
uedev follow 'MyMod|DevBridge'                 # stream until Ctrl+C
uedev shot                                     # engine screenshot, copied back
uedev push path/to/MyMod                       # copy a mod folder in (loads at the next game start)
```

Inside a request, `print` is captured into the response and returned values are serialised
(UObjects as their full name, vectors/rotators as components, FName/FString via `ToString`,
TArrays element-wise). Helpers: `find(cls)`, `all(cls)`, `name(obj)`, `props(obj, {names})`,
`show(v)`, `log(fmt, ...)`, `snap(obj)` / `diff(a, b)` (every safely-readable property of an
object across its class chain, then what changed — e.g. snapshot, do something in game, diff),
`hello()` (version, protocol, armed), `sig(obj, "Func")` (parameters by reflection) and
`call(obj, "Func", ...)` — **use `call` for any UFunction not called before**: it reads the
signature and refuses, as a Lua error, the arguments UE4SS turns into a native fault (`nil` or a
string for an FName, a non-table for a struct, an FName left off the end). UE4SS 3.0.1 exposes no
property flags to Lua, so it checks by position and leaves arity and out-param tables to UE4SS's
own Lua errors. Globals a request defines persist, so a hook can be installed once:

```lua
RegisterHook("/Game/Path/BP_Thing.BP_Thing_C:SomeFunction",
    function(self) print("called on", name(self:get())) end)
```

A `print` from a hook (outside any request) goes to `UE4SS.log` as `[DevBridge] ...`, so read it
with `uedev follow`. Hooks and loops added through the bridge are tracked; `uedev clean` removes
them.

## Hot swap (experimental): `uedev swap DIR`

UE4SS's own hot reload tears a mod's Lua state down while the game still holds the mod's
Blueprint hooks, and the next hooked call hangs or crashes the game (see Limits). A mod can avoid
that by making its `main.lua` a **hot-swap shell**: the shell registers every hook, keybind and
loop once at game start and owns all state; each registration only forwards into a logic table
that the shell can re-load from disk, in the same Lua state, with `load` (not `require`, which
UE4SS caches). Nothing is ever torn down, so the hooks stay valid.

`uedev swap DIR` copies the mod folder in, writes `Mods/<name>/hotswap/req` holding an id, and
waits for the shell to answer in `hotswap/<id>.out`:

- `OK <old> -> <new>, generation N`, then hook and key counts, and a `WARN` line when the shell
  file itself changed on disk (only that needs a game restart);
- or `REFUSED: <cause>`, with the old logic still running.

Exit status is 0 only on `OK`. The bridge does not need to be armed; the shell polls on its own
loop. A mod that does not speak this protocol leaves the request unanswered and `uedev` reports a
TIMEOUT. The protocol has been exercised against a shell's off-game test suite and the shell has
loaded in a live game, but a live swap has not been verified yet — hence experimental.

## The protocol

Everything is a file under the game's `ue4ss` folder, so any language, tool or sync mechanism can
drive the bridge. Write every file atomically: write a temporary file in the same folder, then
rename it into place. The bridge does the same for its answers.

| What | You write | The game answers |
|---|---|---|
| Run Lua | `Mods/DevBridge/io/req.lua`: first line `--@id <id>` (`[A-Za-z0-9_.-]`), then the chunk | `Mods/DevBridge/io/<id>.out` within ~100 ms: captured `print` lines, one `=> value` per returned value, then `OK`; or `ERROR: <traceback>`, `COMPILE ERROR: ...`, or `DISARMED: ...`. Delete it after reading. |
| Arm / disarm | create / delete `Mods/DevBridge/io/ARMED` | — |
| Hot swap | `Mods/<Mod>/hotswap/req` holding an id (create the folder) | `Mods/<Mod>/hotswap/<id>.out`: `OK ...` or `REFUSED: ...` |
| Logs | — | `UE4SS.log`, the bridge's lines prefixed `[DevBridge]` |

The bridge takes `req.lua` and deletes it, so there is one request slot: keep one request in
flight per bridge. Answers over 256 KB are truncated.

`uedev` speaks this protocol through a transport: a file in `lib/uedev/` that defines the `t_*`
functions listed in `bin/uedev`, selected with `UEDEV_TRANSPORT=<name>`. `lib/uedev/local.sh` is
the reference, and `tests/test_uedev_local.sh` runs it end to end against the real bridge in a
fake game.

## Limits

- **Kill switch:** requests run only while `io/ARMED` exists (`uedev arm` / `uedev disarm`);
  disarmed, the bridge answers `DISARMED` and executes nothing. `uedev status` shows the state
  and the bridge's version/protocol handshake.
- **Keep UE4SS hot reload off** once any mod hooks Blueprint functions. In 3.0.1 a reload does not
  cleanly drop script hooks, so the next call of a hooked function enters a torn-down Lua state —
  seen as a hang and as an access-violation crash, and one reload surviving proves nothing.
  `uedev clean` removes the bridge's own runtime hooks but cannot make reloads safe for hooks
  other mods registered. Restart the game to load new mod builds, or use a hot-swap shell.
  `uedev status` flags `EnableHotReloadSystem = 1`.
- Snapshots read an allowlist of property types only; `SoftObjectProperty` reads have hard-crashed
  games through UE4SS, and delegates/maps/sets are skipped.
- `pcall` only catches Lua errors. A call that UE4SS turns into a native fault — a Lua string
  where a UFunction wants an `FName`, wrong out-param arity — kills the game exactly as it would
  from a mod. An endless loop freezes the game thread.
- The bridge has its own Lua state; it sees the engine, not another mod's local variables.
- UE4SS's `require` caches compiled modules itself, so clearing `package.loaded` does not reload
  code. To patch the bridge live after `uedev push`, `dofile` the module and copy its fields into
  the table `main.lua` captured (`debug.getupvalue(print, i)` named `M`).
- The local transport is tested on Linux (CI runs it against the real bridge in a fake game); on
  Windows itself it needs a bash such as WSL or Git Bash, which has not been tried.

## Security model

- The bridge opens no port and listens to nothing but its own folder: whoever can write
  `Mods/DevBridge/io/` can run code in the game — the same trust as `Mods/` itself, which loads
  any mod placed there at the next start. Reaching that folder from elsewhere is the transport's
  job, and its security is the transport's (SSH: see [docs/ssh.md](docs/ssh.md)).
- `ARMED` is a guard against accidents (a stale request, a forgotten session), not a security
  boundary. Disarm between sessions anyway.

## Examples

`examples/` holds session scripts for *RV There Yet?*: `rv_helpers.lua` (who am I, what am I
holding, what am I looking at), `rv_hold_keys.lua` (numpad control of the carried object through
its hold component) and `rv_sparkle_preview.lua` (cycling the game's own Niagara systems on a
carried object, with tracked hooks). They name game classes, functions and asset paths only; no
game files are included.

## Prior art

[littleRabbit94/ue4ss-bridge](https://github.com/littleRabbit94/ue4ss-bridge) (MIT) uses the same
file-polled, game-thread design and adds an MCP server; worth a look if you want an agent to drive
the game directly.

## Tests

`./tools/run_tests.sh` — 66 core assertions (serialiser, request ids, persistence, error capture,
UE4SS userdata shapes, `find` on a no-match, the `call` guard, snapshot/diff), 19 driving
`main.lua` against a fake UE4SS with real files in a temp `io/` folder, and 27 end-to-end ones
running `uedev` over the local transport against the real bridge inside a fake game process
(requests, arming, status, log and follow, push, swap and its timeout, refusals). Syntax checks
cover every script. CI runs the same script on every push.

## License

MIT — see [LICENSE](LICENSE).
