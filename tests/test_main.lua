-- End-to-end test of DevBridge/Scripts/main.lua against a fake UE4SS: real files
-- in a temp io/ dir, LoopAsync captured, ExecuteInGameThread run inline.
-- Run from repo root: lua tests/test_main.lua
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end

local root = (os.getenv("TMPDIR") or "/tmp") .. "/devbridge-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
local dir = root .. "/DevBridge"
assert(os.execute("mkdir -p '" .. dir .. "/Scripts' '" .. dir .. "/io'"))
assert(os.execute("cp DevBridge/Scripts/*.lua '" .. dir .. "/Scripts/'"))
package.path = dir .. "/Scripts/?.lua;" .. package.path

local loops, game_thread_calls, printed = {}, 0, {}
LoopAsync = function(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } end
ExecuteInGameThread = function(fn) game_thread_calls = game_thread_calls + 1; fn() end
FindFirstOf = function(c) return "first:" .. c end
local real_print = print
print = function(s) printed[#printed + 1] = s end

dofile(dir .. "/Scripts/main.lua")

check("one poll loop registered", #loops == 1)
check("poll interval 100 ms", loops[1] and loops[1].ms == 100)
check("load line names the resolved io dir", printed[1] and printed[1]:find(dir .. "/io/", 1, true), printed[1])
check("load line says disarmed when io/ARMED is absent", printed[1] and printed[1]:find("disarmed", 1, true), printed[1])

local tick = loops[1].fn
check("loop keeps running", tick() == false)
check("polling runs on the game thread", game_thread_calls == 1)

-- disarmed: answered, NOT executed
write(dir .. "/io/req.lua", "--@id d1\nRAN_WHILE_DISARMED = true\nreturn 1")
tick()
local out0 = read(dir .. "/io/d1.out") or ""
check("disarmed request is answered with DISARMED", out0:find("DISARMED", 1, true), out0)
check("disarmed request was not executed", rawget(_G, "RAN_WHILE_DISARMED") == nil)
check("disarmed request consumed", read(dir .. "/io/req.lua") == nil)

write(dir .. "/io/ARMED", "")
write(dir .. "/io/req.lua", "--@id h1\nlocal h = hello(); return h.protocol, h.armed, h.bridge")
tick()
local outh = read(dir .. "/io/h1.out") or ""
check("hello reports protocol 1, armed, version", outh:find("=> 1\n=> true\n=> 0.3.0", 1, true), outh)

write(dir .. "/io/req.lua", "--@id r1\nprint('hi')\nreturn find('BP_C')")
tick()
local out = read(dir .. "/io/r1.out")
check("response written", out ~= nil)
check("response content", out and out:find("hi\n=> first:BP_C\nOK", 1, true), out)
check("request consumed", read(dir .. "/io/req.lua") == nil)
check("no tmp left behind", read(dir .. "/io/r1.out.tmp") == nil)
check("serve logged", printed[#printed] and printed[#printed]:find("#r1 served", 1, true), printed[#printed])

tick()
check("idle tick writes nothing new", read(dir .. "/io/anon1.out") == nil)

write(dir .. "/io/req.lua", "--@id r2\nerror('nope')")
tick()
out = read(dir .. "/io/r2.out")
check("error response", out and out:find("ERROR:", 1, true), out)

write(dir .. "/io/r3.out", "stale")
write(dir .. "/io/req.lua", "--@id r3\nreturn 'fresh'")
tick()
check("existing response overwritten", (read(dir .. "/io/r3.out") or ""):find("fresh", 1, true), read(dir .. "/io/r3.out"))

write(dir .. "/io/req.lua", "--@id big\nreturn string.rep('x', 300000)")
tick()
out = read(dir .. "/io/big.out") or ""
check("oversized response truncated", #out < 300000 and out:find("truncated", 1, true), #out)

os.execute("rm -rf '" .. root .. "'")
print = real_print
print(string.format("devbridge main: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
