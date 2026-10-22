# ue4ss-devbridge

A development-only REPL into a running UE4SS game, driven from another machine over SSH.

`DevBridge` is a tiny UE4SS Lua mod that polls `Mods/DevBridge/io/req.lua` every 100 ms on the
**game thread**, runs whatever Lua it finds in a persistent environment, and writes the result to
`io/<id>.out`. `bin/uedev` is the client: it ships the request over SSH, waits for the answer and
prints it, and also tails the UE4SS log, pushes mod folders, takes screenshots and runs remote
PowerShell.

Developed against a UE 5.6 game with UE4SS v3.0.1 (experimental build 1181). The bridge and the
client are game-agnostic; the scripts in `examples/` are written for *RV There Yet?* and show the
patterns.

> **Never ship this to players.** It executes any Lua that lands in its folder.

## Requirements

- **Game box:** Windows, UE4SS installed for the game, an OpenSSH server you can log into with a
  key (`BatchMode`, no password prompts), and the built-in Windows PowerShell.
- **Client:** Linux with bash, `ssh`/`scp`, `tar`, `iconv` and GNU coreutils (`base64 -w0`,
  `date +%N`). `ffmpeg` is optional; `uedev shot` uses it to scale screenshots.
- **Tests:** Lua 5.4; `tools/run_tests.sh` builds one into `$TMPDIR` if none is installed.

## Configure

```sh
mkdir -p ~/.config/uedev
cat > ~/.config/uedev/config <<'EOF'
UEDEV_HOST=player@192.168.1.20
UEDEV_UE4SS="C:\Program Files (x86)\Steam\steamapps\common\<Game>\<Project>\Binaries\Win64\ue4ss"
EOF
```

The file holds `KEY=value` lines and is parsed, never executed; environment variables of the same
name win. The game's process name and its screenshot folder are worked out from the
`*-Shipping.exe` beside the `ue4ss` folder; `UEDEV_PROCESS` and `UEDEV_SHOTS` override them.
`uedev help` lists every setting.

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

## Security model

- The bridge opens no port. The only way in is the SSH login `uedev` uses, so keep that
  key-only and reachable from your own network only.
- `ARMED` is a guard against accidents (a stale request, a forgotten session), not a security
  boundary: anything that can write to `Mods/DevBridge/io/` can also write to `Mods/` and get its
  code loaded at the next start. Disarm between sessions anyway.
- Windows OpenSSH runs commands through `cmd.exe` (pipes break, 8191-char command line), so
  `uedev` sends a fixed `-EncodedCommand` bootstrap and passes every script and payload base64 on
  stdin; nothing user-supplied is interpolated into the command line.

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
UE4SS userdata shapes, `find` on a no-match, the `call` guard, snapshot/diff) and 19 end-to-end
ones driving `main.lua` against a fake UE4SS with real files in a temp `io/` folder, plus a syntax
check of `uedev`. CI runs the same script on every push.

## License

MIT — see [LICENSE](LICENSE).
