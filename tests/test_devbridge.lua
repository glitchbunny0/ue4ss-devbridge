-- Off-game tests for DevBridge. Run: lua tests/test_devbridge.lua (from repo root).
package.path = "DevBridge/Scripts/?.lua;" .. package.path
local core = require("devbridge_core")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- ------------------------------------------------------------ request ids
check("id parsed", core.request_id("--@id abc-12_x.3\nreturn 1") == "abc-12_x.3")
check("id must be first line", core.request_id("return 1\n--@id x") == nil)
check("id stops at path separators", core.request_id("--@id ../../evil\n") == "..")
check("id stops at backslash", core.request_id("--@id a\\b\n") == "a")

-- ------------------------------------------------------------ run / env
local logged = {}
local G = setmetatable({
    FindFirstOf = function(c) return "first:" .. c end,
    FindAllOf = function(c) if c == "None" then return nil end return { "a:" .. c, "b:" .. c } end,
}, { __index = _G })
local env = core.new_env(G, function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end)

local out = core.run(env, "print('hello', 1, true, nil)\nreturn 2.5, 3, {1, 2, x = 'y'}", "t1")
check("print captured", has(out, "hello\t1\ttrue\tnil"), out)
check("float return", has(out, "=> 2.5000"), out)
check("integer return", has(out, "=> 3\n"), out)
check("table return", has(out, '=> {1, 2, x="y"}'), out)
check("ok marker", has(out, "\nOK\n"), out)
check("print did not hit the log during a request", #logged == 0)

out = core.run(env, "return (", "t2")
check("compile error reported", has(out, "COMPILE ERROR"), out)

out = core.run(env, "print('before')\nerror('boom')", "t3")
check("runtime error reported", has(out, "ERROR:") and has(out, "boom"), out)
check("prints kept on error", has(out, "before"), out)
check("traceback included", has(out, "traceback"), out)

core.run(env, "counter = 1", "t4")
out = core.run(env, "counter = counter + 1; return counter", "t5")
check("globals persist across requests", has(out, "=> 2"), out)
check("persistent globals do not leak into _G", rawget(_G, "counter") == nil)

env.print("from a hook")
check("print outside a request goes to the log", logged[#logged] == "from a hook", logged[#logged])

out = core.run(env, "return find('BP_X_C'), #all('BP_X_C'), #all('None')", "t6")
check("find/all helpers", has(out, "=> first:BP_X_C") and has(out, "=> 2") and has(out, "=> 0"), out)

out = core.run(env, "local t = {}; t.self = t; return t", "t7")
check("cycles do not recurse", has(out, "<cycle>"), out)

check("vector table", core.show({ X = 1, Y = 2.5, Z = -3 }) == "(X=1 Y=2.5000 Z=-3)", core.show({ X = 1, Y = 2.5, Z = -3 }))
check("rotator table", core.show({ Pitch = 0.5, Yaw = 90.0, Roll = 0 }) == "(P=0.5000 Y=90.0 R=0)")
check("table with extra keys is not a vector", core.show({ X = 1, Y = 2, Z = 3, W = 4 }):sub(1, 1) == "{")

-- FindFirstOf yields an invalid object (not nil) on no match; find() must give nil.
local G2 = setmetatable({ FindFirstOf = function(c)
    if c == "Missing" then return setmetatable({}, { __index = { IsValid = function() return false end } }) end
    return setmetatable({ c = c }, { __index = { IsValid = function() return true end } })
end }, { __index = _G })
local env2 = core.new_env(G2, function() end)
check("find maps an invalid result to nil", env2.find("Missing") == nil)
check("find keeps a valid result", env2.find("Real") ~= nil and env2.find("Real").c == "Real")
check("find chains with or", (env2.find("Missing") or env2.find("Real")).c == "Real")

-- ------------------------------------------------------------ userdata shapes
-- Plain Lua cannot make userdata, but every io.tmpfile() is a distinct full
-- userdata, and full userdata carry per-object metatables. Give each one a
-- dispatcher onto its own field table.
local objs = setmetatable({}, { __mode = "k" })
local MT = {
    __index = function(u, k)
        local f = objs[u]
        if f == nil then return nil end
        local v = f[k]
        if v == nil and f.__strict then error("no member " .. tostring(k)) end
        return v
    end,
}
local function ud(fields)
    local u = io.tmpfile()
    objs[u] = fields
    debug.setmetatable(u, MT)
    return u
end

local uobj = ud({ __strict = true,
    type = function() return "UObject" end,
    IsValid = function() return true end,
    GetFullName = function() return "BP_Plank_C /Game/Map.Map:PersistentLevel.BP_Plank_C_1" end })
check("valid UObject shows full name", core.show(uobj) == "<BP_Plank_C /Game/Map.Map:PersistentLevel.BP_Plank_C_1>", core.show(uobj))

local dead = ud({ __strict = true,
    type = function() return "UObject" end,
    IsValid = function() return false end,
    GetFullName = function() error("would fault") end })
check("invalid UObject never reads its name", core.show(dead) == "<UObject invalid>", core.show(dead))

local vec = ud({ __strict = true, type = function() return "UScriptStruct" end, X = 1, Y = 2.5, Z = -3 })
check("vector struct", core.show(vec) == "(X=1 Y=2.5000 Z=-3)", core.show(vec))

local rot = ud({ __strict = true, type = function() return "UScriptStruct" end, Pitch = 0.5, Yaw = 90.0, Roll = 0 })
check("rotator struct", core.show(rot) == "(P=0.5000 Y=90.0 R=0)", core.show(rot))

-- Live UE4SS: a struct wrapper's IsValid/GetFullName describe the struct TYPE.
local rot2 = ud({ __strict = true, type = function() return "UScriptStruct" end,
    IsValid = function() return true end,
    GetFullName = function() return "ScriptStruct /Script/CoreUObject.Rotator" end,
    Pitch = -12.25, Yaw = 20.875, Roll = 0 })
check("struct fields win over the struct's type name", core.show(rot2) == "(P=-12.2500 Y=20.8750 R=0)", core.show(rot2))
local other = ud({ __strict = true, type = function() return "UScriptStruct" end,
    IsValid = function() return true end,
    GetFullName = function() return "ScriptStruct /Script/Engine.HitResult" end })
check("non-vector struct still shows its type", core.show(other) == "<ScriptStruct /Script/Engine.HitResult>", core.show(other))

local fname = ud({ __strict = true, type = function() return "FName" end, ToString = function() return "rvfp_hud" end })
check("FName via ToString", core.show(fname) == "rvfp_hud", core.show(fname))
check("FName quoted when nested", core.show({ fname }) == '{"rvfp_hud"}', core.show({ fname }))

local arr = ud({ __strict = true, type = function() return "TArray" end,
    GetArrayNum = function() return 3 end, [1] = 10, [2] = 20, [3] = 30 })
check("TArray", core.show(arr) == "<TArray n=3> [10, 20, 30]", core.show(arr))

local opaque = ud({ __strict = true, type = function() return "Mystery" end })
check("unknown userdata falls back to its type", core.show(opaque) == "<Mystery>", core.show(opaque))

local untyped = ud({ __strict = true })
check("userdata without type()", core.show(untyped) == "<userdata>", core.show(untyped))

local wrapped = ud({ __strict = true, type = function() return "RemoteUnrealParam" end, get = function() return uobj end })
check("RemoteUnrealParam is unwrapped (TArray elements, hook params)", core.show(wrapped) == core.show(uobj), core.show(wrapped))

env.__test_obj = ud({ __strict = true, Health = 30, Name = fname })
out = core.run(env, "return props(__test_obj, {'Health', 'Missing', 'Name'})", "t8")
check("props reads present and tolerates missing", has(out, '=> Health=30 Missing=nil Name="rvfp_hud"\n'), out)

-- ------------------------------------------------------------ guarded calls
-- A fake UFunction whose ForEachProperty walks properties like UE4SS 3.0.1 does:
-- parameters first, then (for Blueprint functions) compiler-generated locals.
-- No property-flag API, exactly as in the live build.
local function prop(nm, cls)
    return {
        GetFName = function() return { ToString = function() return nm end } end,
        GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end,
    }
end
local function ufunc(props)
    return setmetatable({}, { __call = function(_, self, ...) return "called", select("#", ...) end,
        __index = { ForEachProperty = function(_, cb) for _, p in ipairs(props) do cb(p) end end } })
end
local comp = {
    IsSimulatingPhysics = ufunc({ prop("BoneName", "NameProperty"), prop("ReturnValue", "BoolProperty") }),
    -- Blueprint function as read live: two params, then locals.
    SetNewAttachTransform = ufunc({ prop("NewTransform", "StructProperty"), prop("Success", "BoolProperty"),
        prop("CallFunc_MakeTransform_ReturnValue", "StructProperty"), prop("K2Node_DynamicCast_bSuccess", "BoolProperty") }),
    HandleHandPoseInput = ufunc({ prop("Yaw", "DoubleProperty"), prop("Pitch", "DoubleProperty"), prop("Fwd", "DoubleProperty"),
        prop("CallFunc_Multiply_DoubleDouble_ReturnValue", "DoubleProperty"), prop("Temp_bool_Variable", "BoolProperty") }),
}
local fn_name = ud({ __strict = true, type = function() return "FName" end, ToString = function() return "None" end })

local sigp = core.signature(comp, "IsSimulatingPhysics")
check("signature reads params in order", sigp and #sigp == 2 and sigp[1].name == "BoneName" and sigp[1].class == "NameProperty")
check("native ReturnValue recognised by name", sigp and sigp[2].ret == true)
check("signature of a missing member is nil", core.signature(comp, "Nope") == nil)
local sbp = core.signature(comp, "SetNewAttachTransform")
check("Blueprint locals are cut off", sbp and #sbp == 2 and sbp[2].name == "Success", sbp and #sbp)
local shp = core.signature(comp, "HandleHandPoseInput")
check("CallFunc_ and Temp_ locals both cut", shp and #shp == 3, shp and #shp)

local ok, err = pcall(env.call, comp, "IsSimulatingPhysics", nil)
check("nil for an FName is refused (the 20:27 crash)", not ok and has(err, "REFUSED") and has(err, "BoneName is an FName"), err)
ok, err = pcall(env.call, comp, "IsSimulatingPhysics", "None")
check("string for an FName is refused (the 0.4.0 crash)", not ok and has(err, "FName"), err)
ok, err = pcall(env.call, comp, "IsSimulatingPhysics")
check("an FName left off the end is refused", not ok and has(err, "BoneName (FName) missing"), err)
local r1, r2 = env.call(comp, "IsSimulatingPhysics", fn_name)
check("FName userdata passes and the call goes through", r1 == "called" and r2 == 1, tostring(r1))

ok, err = pcall(env.call, comp, "SetNewAttachTransform", nil, {})
check("nil for a struct is refused", not ok and has(err, "NewTransform is a struct"), err)
check("struct table passes (out param table too)", (env.call(comp, "SetNewAttachTransform", { Translation = {} }, {})) == "called")
check("plain doubles pass", (env.call(comp, "HandleHandPoseInput", 0.0, 0.0, 1.0)) == "called")

-- ------------------------------------------------------------------ snapshot / diff
local soft_reads = 0
local function sprop(nm, cls) return prop(nm, cls) end
local base = { props = { sprop("Health", "FloatProperty"), sprop("bAlive", "BoolProperty") } }
local mid = { props = { sprop("Name", "NameProperty"), sprop("SoftRef", "SoftObjectProperty"),
                        sprop("OnHit", "MulticastInlineDelegateProperty"), sprop("Items", "ArrayProperty") },
              super = base }
local leaf = { props = { sprop("Pos", "StructProperty"), sprop("Health", "FloatProperty") }, super = mid }
local function class(c)
    return setmetatable({}, { __index = {
        IsValid = function() return true end,
        ForEachProperty = function(_, cb) for _, p in ipairs(c.props) do cb(p) end end,
        GetSuperStruct = function() return c.super and class(c.super) or nil end,
    } })
end
local thing = setmetatable({ Health = 30.0, bAlive = true, Pos = { X = 1, Y = 2, Z = 3 },
    Items = ud({ __strict = true, type = function() return "TArray" end, GetArrayNum = function() return 4 end }) },
    { __index = function(_, k)
        if k == "GetClass" then return function() return class(leaf) end end
        if k == "SoftRef" then soft_reads = soft_reads + 1; return "would crash" end
        if k == "Name" then return fn_name end
    end })
local snapA, nA = core.snapshot(thing)
check("snapshot walks the whole class chain", snapA.Health == "30.0" and snapA.bAlive == "true" and snapA.Name == '"None"', nA)
check("snapshot shows structs and array sizes", snapA.Pos == "(X=1 Y=2 Z=3)" and snapA.Items == "<TArray n=4>", snapA.Pos)
check("snapshot NEVER reads a SoftObjectProperty", soft_reads == 0 and snapA.SoftRef == nil)
check("snapshot skips delegates", snapA.OnHit == nil)
check("leaf property wins over the inherited one of the same name (5 readable, dup skipped)", nA == 5, nA)
thing.Health = 25.0; thing.bAlive = false
local snapB = core.snapshot(thing)
local d = core.diff(snapA, snapB)
check("diff lists exactly the changed properties, sorted", #d == 2 and d[1] == "Health: 30.0 -> 25.0" and d[2] == "bAlive: true -> false", table.concat(d, " | "))
snapB.Extra = "1"; snapB.Pos = nil
d = core.diff(snapA, snapB)
check("diff reports new and gone keys", table.concat(d, "|"):find("Extra: (new) 1", 1, true) and table.concat(d, "|"):find("Pos: (X=1 Y=2 Z=3) -> (gone)", 1, true), table.concat(d, " | "))
check("env.diff joins lines", env.diff({ a = "1" }, { a = "2" }) == "a: 1 -> 2")

-- ------------------------------------------------------------------ runtime hook / loop tracking
local reg, unreg, async = {}, {}, {}
local G3 = setmetatable({
    RegisterHook = function(path, pre, post) reg[#reg + 1] = { path = path, pre = pre, post = post }; return 100 + #reg, 200 + #reg end,
    UnregisterHook = function(path, pre_id, post_id) unreg[#unreg + 1] = { path = path, pre = pre_id, post = post_id } end,
    LoopAsync = function(ms, fn) async[#async + 1] = fn end,
}, { __index = _G })
local env3 = core.new_env(G3, function() end)
out = core.run(env3, [[
RegisterHook("/Game/X.X_C:Tick", function() end)
local a, b = RegisterHook("/Game/X.X_C:Other", function() end, function() end)
LoopAsync(33, function() TICKS = (TICKS or 0) + 1; return false end)
return a, b, installed().hooks, installed().loops]], "t9")
check("RegisterHook in a request is tracked and returns the real ids", has(out, "=> 102\n=> 202\n=> 2\n=> 1"), out)
check("both hooks reached UE4SS", #reg == 2 and reg[2].path == "/Game/X.X_C:Other")
check("tracked loop runs", async[1]() == false and env3.TICKS == 1)
out = core.run(env3, "return cleanup()", "t10")
check("cleanup unregisters every hook with its own ids", #unreg == 2 and unreg[1].pre == 102 and unreg[1].post == 202 and unreg[2].pre == 101, out)
check("cleanup reports counts", has(out, "2 hooks unregistered, 0 failed, 1 loops stopped"), out)
check("a stopped loop ends itself (returns true) and stops ticking", async[1]() == true and env3.TICKS == 1)
check("nothing left installed", env3.installed().hooks == 0 and env3.installed().loops == 0)
local G4 = setmetatable({ RegisterHook = function() return 1, 2 end, LoopAsync = function() end }, { __index = _G })
local env4 = core.new_env(G4, function() end)
env4.hook("/Game/Y:F", function() end)
check("cleanup survives a build without UnregisterHook", has(env4.cleanup(), "0 hooks unregistered, 1 failed"))

print(string.format("devbridge core: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
