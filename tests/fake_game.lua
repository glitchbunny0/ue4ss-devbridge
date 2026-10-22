-- A stand-in for a running game with UE4SS, for tests/test_uedev_local.sh: loads the REAL
-- DevBridge mod from <ue4ss>/Mods/DevBridge with a minimal UE4SS API, pumps its LoopAsync on
-- one "game thread" like the engine does, sends print() to UE4SS.log, and plays a hot-swap
-- shell for the mod folder FakeShell (answers hotswap/req). Stops on <ue4ss>/STOP or after
-- the given number of seconds.
--   lua tests/fake_game.lua <ue4ss-dir> <seconds> <process-tag>
local root, seconds = arg[1], tonumber(arg[2] or "30")
local log = assert(io.open(root .. "/UE4SS.log", "a"))
print = function(s) log:write("[Lua] ", tostring(s)); log:flush() end

local loops = {}
LoopAsync = function(_, fn) loops[#loops + 1] = fn end
ExecuteInGameThread = function(fn) fn() end
FindFirstOf = function() return nil end
FindAllOf = function() return nil end
RegisterHook = function() return 1, 2 end
UnregisterHook = function() end

local scripts = root .. "/Mods/DevBridge/Scripts/"
package.path = scripts .. "?.lua;" .. package.path
log:write("UE4SS - v3.0.1 (fake game for tests)\n")
dofile(scripts .. "main.lua")

local function exists(p) local f = io.open(p, "rb"); if f then f:close() end return f ~= nil end
local function swap_shell()
    local hs = root .. "/Mods/FakeShell/hotswap/"
    local f = io.open(hs .. "req", "rb")
    if not f then return end
    local id = f:read("a"):match("^%s*([%w_%-%.]+)") or "anon"
    f:close()
    os.remove(hs .. "req")
    local o = assert(io.open(hs .. id .. ".out.tmp", "wb"))
    o:write("OK fake 1.0 -> 1.1, generation 2\nhooks: 0 live\nkeys: 0/0 bound\n")
    o:close()
    os.rename(hs .. id .. ".out.tmp", hs .. id .. ".out")
end

local t_end = os.time() + seconds
while os.time() < t_end and not exists(root .. "/STOP") do
    for _, fn in ipairs(loops) do fn() end
    swap_shell()
    os.execute("sleep 0.05")
end
log:write("Event loop end\n")
log:close()
