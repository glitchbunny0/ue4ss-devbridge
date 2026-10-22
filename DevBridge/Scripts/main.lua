--[[ DevBridge — a file-based REPL into a running UE4SS game, for development only.

    A client (over SSH) drops Lua source into io/req.lua. Every POLL_MS this mod
    picks it up on the GAME THREAD, runs it in a persistent environment, and
    writes the result to io/<id>.out (via a .tmp + rename, so the client never
    reads a half-written file).

    Request format: first line `--@id <id>`, then any Lua. The chunk may `print`
    (captured into the response) and `return` values (serialised). Globals it
    defines persist across requests, so hooks and state can be set up once.

    Kill switch: requests are executed only while io/ARMED exists (`uedev arm` /
    `uedev disarm`). Disarmed, a request is answered with DISARMED and not run.

    What this cannot protect against: a call UE4SS turns into a native fault
    (e.g. a Lua string passed for an FName parameter) kills the game exactly as
    it would from a mod, and an endless loop freezes the game thread. pcall only
    catches Lua errors.

    Never ship this to players: it executes whatever lands in its io folder.
--]]

local VERSION = "0.3.0"
local PROTOCOL = 1
local POLL_MS = 100
local MAX_OUT = 256 * 1024

local core = require("devbridge_core")

local function log(fmt, ...)
    print(string.format("[DevBridge] " .. fmt .. "\n", ...))
end

-- Resolve our own io/ folder from this script's path; fall back to a path
-- relative to the ue4ss working directory (which UE4SS sets to ue4ss/).
local function io_dir()
    local src = debug.getinfo(1, "S").source or ""
    local dir, sep = src:match("^@(.*)([/\\])Scripts[/\\]main%.lua$")
    if dir then return dir .. sep .. "io" .. sep end
    return "Mods\\DevBridge\\io\\"
end

local IO = io_dir()
local REQ = IO .. "req.lua"
local ARMED = IO .. "ARMED"

local function write_atomic(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

local function armed()
    local f = io.open(ARMED, "rb")
    if not f then return false end
    f:close()
    return true
end

local env = core.new_env(_G, log)
env.hello = function()
    return { bridge = VERSION, protocol = PROTOCOL, armed = armed(), io = IO }
end
local served = 0

local function serve(src)
    local id = core.request_id(src) or ("anon" .. served)
    local text
    if armed() then
        text = core.run(env, src, "req:" .. id)
    else
        text = "DISARMED: DevBridge is not executing requests (create io/ARMED, e.g. `uedev arm`)\n"
    end
    if #text > MAX_OUT then
        text = text:sub(1, MAX_OUT) .. "\n...[truncated at " .. MAX_OUT .. " bytes]\n"
    end
    served = served + 1
    if not write_atomic(IO .. id .. ".out", text) then
        log("#%s: could not write response to %s", id, IO)
    end
    -- No timing here: os.clock() in a game process is CPU time summed over all threads, not
    -- wall time, and Lua has no wall clock finer than a second.
    log("#%s %s", id, armed() and "served" or "refused (disarmed)")
end

local function poll()
    local f = io.open(REQ, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    os.remove(REQ)
    if src and #src > 0 then serve(src) end
end

pcall(function()
    LoopAsync(POLL_MS, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(poll)
            if not ok then log("poll failed: %s", tostring(err)) end
        end)
        return false -- run forever
    end)
end)

log("v%s (protocol %d) loaded — polling %s every %d ms, %s. DEV ONLY: executes any Lua dropped there while armed.",
    VERSION, PROTOCOL, IO, POLL_MS, armed() and "ARMED" or "disarmed")
