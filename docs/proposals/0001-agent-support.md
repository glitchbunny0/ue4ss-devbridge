# Proposal 0001 — agent support

**Status:** draft, open for feedback. The UE4SS-side piece — letting external tools use the Lua
Debugger's REPL — is proposed upstream ([UE4SS #1471](https://github.com/UE4SS-RE/RE-UE4SS/issues/1471)). Feedback on this plan: open an issue here.

## Summary

Make DevBridge safe and practical for AI agents to drive a running UE4SS game. In order:

1. **An agent-safe bridge** — structured (JSON) answers, a budget that turns runaway Lua into an
   error instead of a frozen game, and a read-only mode built on structured operations.
2. **A small MCP server** over the existing transports, with about ten tools and one persistent
   connection to the game machine.
3. **Event streams** — hooks and property watches recorded in the game, read back with a cursor.
4. **Exploration:** injecting input through the game's own Enhanced Input, so an agent can test a
   mod's controls unattended.

No sockets inside the game, no native code: the file protocol stays the only interface to the mod.

## Where this comes from: vibe modding

This repo came out of three days of a human and an AI coding agent modding *RV There Yet?*
(UE 5.6, UE4SS 3.0.1 experimental) together. The human plays, judges feel and says what is wrong;
the agent mines the SDK dump, writes the mod, probes the live game through the bridge, looks at
screenshots itself, and tests every change off-game against a strict UE4SS mock first. It is a
fun way to mod, and it is what the tooling here is shaped by.

- **Day 1 — [RVFinePlank](https://github.com/glitchbunny0/rv-fine-plank).** Fine control of the
  carried plank, written and tested (62 assertions, CI, installer smoke test) from a published SDK
  dump before the game had been run once. Its premise was wrong: the first live measurements showed
  that the hand-pose input it scaled does not move the carried plank at all. Offline work proves
  the wiring and the maths; only the live game proves the premise.
- **Day 2 — DevBridge, this repo.** A REPL into the running game. Live probing found the real
  lever (the character's `HoldTransform` component) and a list of facts no documentation states:
  Blueprint post-hooks never fire in this UE4SS build; `nil` or a Lua string for an `FName`
  parameter is a native crash, not a Lua error; UE4SS hot reload crashes the game once a mod hooks
  Blueprint functions; `FindFirstOf` returns an invalid object rather than `nil`; a property named
  `IsHolding` flips when an object is dropped, not when it is picked up. Those became the bridge's
  guarded `call`, its tracked hooks, and the mocks' rules.
- **Days 2–3 — [RVPlankControl](https://github.com/glitchbunny0/rv-plank-control).** Turns the
  plank about its bottom end in real degrees and centimetres inside a 90° cone, freezes it in mid
  air so the player can walk around it, offers three mouse modes picked by which of the
  character's hands are raised, learns mouse sensitivity from the player's own look, and marks the
  plank it controls with the game's own welding sparks. 306 off-game checks.
- **Day 3 — hot swap.** Because UE4SS's reload crashes the game, the mod became a shell that
  registers its hooks once and re-loads its logic in place (`uedev swap`). The shell runs in the
  live game; a live swap is still to be verified.
- **Tooling along the way:** screenshots copied back for the agent to look at, snapshot/diff of an
  object around a player action, local and SSH transports, and an end-to-end test of the client
  against the real bridge in a fake game process.

The lesson that shapes this proposal: **an agent's mistakes are the dangerous kind.** It will pass
a confident wrong argument (a native crash), trust a property's name (wrong half the time here),
or write a loop that never ends (a frozen game). Agent support is mostly guard rails.

## What an agent needs that a human does not

- **Guard rails**, because a crash or a frozen game ends the session for everyone at the PC.
- **Structured answers.** Today's answers are text (`=> value` lines); agents parse JSON far more
  reliably.
- **A small tool surface.** Every MCP tool definition costs roughly 300–500 tokens on every turn;
  24 tools is 7–12k tokens of overhead before any work happens.
- **Eyes and a feedback loop:** screenshots, and "what happened since I last looked" without
  scraping a log.
- **Low latency.** Agents make many small calls. Measured: the SSH transport spends ~570 ms per
  call starting SSH and PowerShell; the file protocol itself answered in ~60 ms against the real
  bridge in a test harness (the live bridge polls every 100 ms, so expect up to ~50 ms more).

## Landscape (surveyed October 2026)

Live agent bridges into *shipped* UE games are new and small:

| Project | Approach | Notes |
|---|---|---|
| [ue4ss-bridge](https://github.com/littleRabbit94/ue4ss-bridge) | UE4SS Lua mod + Python MCP server, JSON file IPC | Most complete UE4SS one: 24 tools, events, read-only switches. No guard against native-fault arguments; game on the same machine only. |
| [uevr-mcp](https://github.com/elliotttate/uevr-mcp) | UEVR plugin + MCP server | Deepest (103 tools) but built on UEVR (all rights reserved, one maintainer); quiet since June. |
| [FrostPunk2Agent](https://github.com/BumpyClock/FrostPunk2Agent) | UE4SS file bridge + CLI + agent skills | Game-specific; chose CLI + skills over MCP. |

The attention around "AI + Unreal" is on editor plugins (including Epic's own MCP plugin in UE
5.8) and on generic debugger/instrumentation MCP servers, neither of which reaches a shipped game's
UObjects. We take three ideas from ue4ss-bridge — JSON answers, read/eval switches, event cursors —
and keep what is particular to DevBridge: the native-fault guard, remote transports, hot swap and
the end-to-end test.

## Proposal

### Stage 1 — an agent-safe bridge (protocol 2, backward compatible)

- **JSON answers on request.** A request whose header carries `--@format json` gets
  `{"ok", "prints", "values", "error", "protocol"}`; UObjects become `{"object": "<full name>"}`,
  vectors and rotators their components. Without the header the answer stays today's text, so
  existing clients keep working. `hello()` reports protocol 2.
- **Instruction budget.** Each request runs under a Lua count hook that raises after a configurable
  number of instructions (header `--@budget N`, sensible default), so an endless loop becomes an
  `ERROR` and the game keeps running. It cannot stop a single slow native call. The bridge already
  uses Lua's debug library in the live game; the count hook itself is untested there.
- **Structured operations and a read mode.** Arbitrary Lua cannot be made read-only (a property
  assignment is a write), so read-only needs operations the bridge runs itself: `find`, `props`,
  `functions`, `sig`, `snap`/`diff`, `log`. A mode file next to `ARMED` selects what may run:
  `read` (structured reads only), `call` (adds the guarded `call`), `eval` (adds raw Lua; today's
  behaviour). The human sets it; no agent tool changes it.
- **One request in flight.** Kept as today (one slot), now enforced by the clients with a lock
  rather than by convention.

### Stage 2 — an MCP server

- Python with the official `mcp` SDK; stdio by default, streamable HTTP on loopback optional.
- Uses the same transports as `uedev`. Being long-running, it keeps one session to the game machine
  open (for SSH: one persistent remote PowerShell loop), removing the ~570 ms per call without
  opening a port on the game machine.
- About ten tools: `status`, `inspect` (find / props / functions / signature), `snapshot` and
  `diff`, `call` (guarded), `lua` (only in `eval` mode), `log` (tail and grep with a cursor),
  `events`, `screenshot` (returned as an image and as a file path, for clients that drop images),
  `push`, `swap`. Tool descriptions carry the call rules that crash games when broken.
- Deliberately **not** tools: arming, disarming and changing the mode. Those stay with the human.

### Stage 3 — events

Hooks and property watches recorded inside the game into one bounded buffer with sequence numbers;
`events(since)` drains it. Hooks stay tracked and removable (`uedev clean`). Modelled on
ue4ss-bridge's `poll_events`.

### Stage 4 — exploration: input injection

UE5's Enhanced Input exposes `InjectInputForAction` on the local player subsystem. If it works from
UE4SS Lua, an agent could hold the pose key, click and move the mouse through the game's own input
actions, and test a mod's controls with nobody at the keyboard. Unverified in any game so far.

## Non-goals

- Sockets or native code inside the game process.
- Anything aimed at online play, anti-cheat-protected games, or other players' sessions.
- A gameplay mod; DevBridge stays a development tool that must never ship to players.
- Replacing UE4SS's own Lua Debugger, which is better for stepping through code at the PC.

## Questions we would like feedback on

1. **Join forces or stay separate?** Should DevBridge speak ue4ss-bridge's wire protocol (or
   contribute the guard and transports there) rather than grow its own MCP server?
2. **Read mode:** are structured operations plus `read`/`call`/`eval` modes the right shape, or is
   `ARMED` plus raw Lua enough in practice?
3. **Instruction budget:** any known trouble with Lua count hooks inside UE4SS's game-thread Lua
   states? What default is generous enough for real probes?
4. **Tool surface:** are ten tools the right cut, or does an agent need finer ones?
5. **Autonomy:** should an agent ever push or swap without a human confirming?
6. **Implementation:** Python for the MCP server, or one self-contained binary?
