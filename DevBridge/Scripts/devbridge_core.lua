--[[ DevBridge core: the parts that do not touch UE4SS directly, so they can be
    tested off-game. new_env builds the persistent REPL environment; run executes
    one request in it and returns the response text; show serialises values,
    including UE4SS userdata, without ever letting a failed probe escape.
--]]

local M = {}

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function utype(v)
    return try(function() return v:type() end)
end

local function fmtnum(n)
    if math.type and math.type(n) == "integer" then return tostring(n) end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%.1f", n) end
    return string.format("%.4f", n)
end

-- Serialise one value. Strings are raw at top level and %q inside tables.
function M.show(v, depth, seen, nested)
    depth = depth or 3
    seen = seen or {}
    local t = type(v)
    if t == "nil" or t == "boolean" then return tostring(v) end
    if t == "number" then return fmtnum(v) end
    if t == "string" then return nested and string.format("%q", v) or v end
    if t == "function" then return "<function>" end
    if t == "table" then
        if seen[v] then return "<cycle>" end
        -- Structs UE4SS hands back as plain tables (e.g. a returned FVector).
        local function exactly3(a, b, c)
            if type(v[a]) ~= "number" or type(v[b]) ~= "number" or type(v[c]) ~= "number" then return false end
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            return n == 3
        end
        if exactly3("X", "Y", "Z") then
            return string.format("(X=%s Y=%s Z=%s)", fmtnum(v.X), fmtnum(v.Y), fmtnum(v.Z))
        end
        if exactly3("Pitch", "Yaw", "Roll") then
            return string.format("(P=%s Y=%s R=%s)", fmtnum(v.Pitch), fmtnum(v.Yaw), fmtnum(v.Roll))
        end
        if depth <= 0 then return "{...}" end
        seen[v] = true
        local parts, n = {}, 0
        local len = #v
        for i = 1, len do
            n = n + 1
            if n > 60 then parts[#parts + 1] = "..."; break end
            parts[#parts + 1] = M.show(v[i], depth - 1, seen, true)
        end
        for k, val in pairs(v) do
            if not (math.type and math.type(k) == "integer" and k >= 1 and k <= len) then
                n = n + 1
                if n > 60 then parts[#parts + 1] = "..."; break end
                parts[#parts + 1] = tostring(k) .. "=" .. M.show(val, depth - 1, seen, true)
            end
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if t == "userdata" then
        local ut = utype(v) or "userdata"
        -- Hook params and TArray return elements arrive wrapped; show what they hold.
        if ut == "RemoteUnrealParam" or ut == "LocalUnrealParam" then
            local inner = try(function() return v:get() end)
            if inner ~= nil then return M.show(inner, depth, seen, nested) end
        end
        local function vec_or_rot()
            local x, y, z = try(function() return v.X end), try(function() return v.Y end), try(function() return v.Z end)
            if type(x) == "number" and type(y) == "number" and type(z) == "number" then
                return string.format("(X=%s Y=%s Z=%s)", fmtnum(x), fmtnum(y), fmtnum(z))
            end
            local p, yw, r = try(function() return v.Pitch end), try(function() return v.Yaw end), try(function() return v.Roll end)
            if type(p) == "number" and type(yw) == "number" and type(r) == "number" then
                return string.format("(P=%s Y=%s R=%s)", fmtnum(p), fmtnum(yw), fmtnum(r))
            end
        end
        -- A struct wrapper answers IsValid/GetFullName with its struct TYPE
        -- ("ScriptStruct /Script/CoreUObject.Rotator"), so read its fields first.
        if ut == "UScriptStruct" then
            local s = vec_or_rot()
            if s then return s end
        end
        -- UObject-like: validity first, because reading a dead object is a native fault.
        local valid = try(function() return v:IsValid() end)
        if valid == false then return "<" .. ut .. " invalid>" end
        if valid == true then
            local name = try(function() return v:GetFullName() end)
            if name then return "<" .. name .. ">" end
        end
        local s = try(function() return v:ToString() end)
        if type(s) == "string" then return nested and string.format("%q", s) or s end
        s = vec_or_rot()
        if s then return s end
        local num = try(function() return v:GetArrayNum() end)
        if type(num) == "number" then
            if depth <= 0 then return "<TArray n=" .. num .. ">" end
            local parts = {}
            for i = 1, math.min(num, 40) do
                parts[#parts + 1] = M.show(try(function() return v[i] end), depth - 1, seen, true)
            end
            if num > 40 then parts[#parts + 1] = "...(" .. num .. ")" end
            return "<TArray n=" .. num .. "> [" .. table.concat(parts, ", ") .. "]"
        end
        return "<" .. ut .. ">"
    end
    return tostring(v)
end

-- Build the persistent environment. `G` is the real global table (UE4SS API
-- lives there), `log` writes one line to UE4SS.log.
function M.new_env(G, log)
    local env = setmetatable({}, { __index = G })
    local buf -- current response buffer; nil outside a request (e.g. inside a hook)

    env.print = function(...)
        local n, parts = select("#", ...), {}
        for i = 1, n do parts[i] = M.show((select(i, ...))) end
        local line = table.concat(parts, "\t")
        if buf then buf[#buf + 1] = line else log("%s", line) end
    end
    env.show = function(...) return M.show(...) end -- delegate, so a live patch of M reaches it
    env.log = function(fmt, ...) log(fmt, ...) end

    -- Shorthands for the things a live session needs most.
    -- UE4SS's FindFirstOf returns an INVALID object, not nil, when nothing matches;
    -- normalise to nil so `find(a) or find(b)` falls through as it reads.
    env.find = function(cls)
        local o = G.FindFirstOf(cls)
        if o == nil then return nil end
        local ok, valid = pcall(function() return o:IsValid() end)
        if ok and valid == false then return nil end
        return o
    end
    env.all = function(cls)
        local list = G.FindAllOf(cls)
        if list == nil then return {} end
        return list
    end
    env.name = function(obj)
        if obj == nil then return "nil" end
        return try(function() return obj:IsValid() and obj:GetFullName() end) or "<invalid>"
    end
    -- Read several properties at once, as one line in the order asked; a missing
    -- one reads as nil instead of raising.
    env.props = function(obj, names)
        local out = {}
        for _, k in ipairs(names) do
            out[#out + 1] = k .. "=" .. M.show(try(function() return obj[k] end), 2, nil, true)
        end
        return table.concat(out, " ")
    end

    env.__begin = function() buf = {} end
    env.__end = function() local b = buf; buf = nil; return b or {} end

    -- Runtime hooks and loops are tracked so a session can remove what it added (`uedev
    -- clean`). This does NOT make UE4SS hot reload safe: in 3.0.1 a reload still tears the Lua
    -- state down under any Blueprint hook a mod registered at load. Keep it off and restart.
    -- Requests calling RegisterHook / LoopAsync get these tracked versions.
    local hooks, loops = {}, {}
    env.hook = function(path, pre, post)
        local pre_id, post_id = G.RegisterHook(path, pre, post)
        hooks[#hooks + 1] = { path = path, pre = pre_id, post = post_id }
        return pre_id, post_id
    end
    env.loop = function(ms, fn)
        local rec = { stopped = false }
        G.LoopAsync(ms, function()
            if rec.stopped then return true end
            return fn()
        end)
        loops[#loops + 1] = rec
        return rec
    end
    env.RegisterHook = env.hook
    env.LoopAsync = env.loop
    -- Remove everything this bridge session installed. Returns a one-line report.
    env.cleanup = function()
        local unhooked, failed = 0, 0
        for i = #hooks, 1, -1 do
            local h = hooks[i]
            local ok = pcall(G.UnregisterHook, h.path, h.pre, h.post)
            if ok then unhooked = unhooked + 1 else failed = failed + 1 end
            hooks[i] = nil
        end
        local stopped = 0
        for i = #loops, 1, -1 do
            if not loops[i].stopped then loops[i].stopped = true; stopped = stopped + 1 end
            loops[i] = nil
        end
        return string.format("cleanup: %d hooks unregistered, %d failed, %d loops stopped", unhooked, failed, stopped)
    end
    env.installed = function() return { hooks = #hooks, loops = #loops } end

    -- Signature of obj's UFunction `fname`, read by reflection: one entry per
    -- parameter, in order, with its property class and whether it is out/return.
    env.sig = function(obj, fname) return M.signature(obj, fname) end
    -- snap(obj) -> table of property -> shown value; diff(a, b) -> changed lines.
    env.snap = function(obj) return (M.snapshot(obj)) end
    env.diff = function(a, b) return table.concat(M.diff(a, b), "\n") end
    -- Guarded call: refuses, with a Lua error, any argument UE4SS would turn into
    -- a native fault (nil or a string for an FName, a non-table for a struct or an
    -- out param, wrong arity) — then calls obj:fname(...) exactly as written.
    env.call = function(obj, fname, ...)
        local params, err = M.signature(obj, fname)
        if not params then error("call " .. tostring(fname) .. ": cannot read signature (" .. tostring(err) .. ")", 2) end
        local problems = M.check_args(params, table.pack(...))
        if #problems > 0 then error("call " .. fname .. " REFUSED: " .. table.concat(problems, "; "), 2) end
        local f = obj[fname]
        return f(obj, ...)
    end
    return env
end

local LOCAL_PREFIXES = { "CallFunc_", "K2Node_", "Temp_", "LocalVar" }

-- Read a UFunction's parameters via UE4SS reflection. Never raises.
-- UE4SS 3.0.1 Lua exposes no property flags, so: Blueprint functions list their
-- locals after the parameters (cut at the first compiler-generated name), and a
-- native return value is recognised by its name. In/out cannot be told apart.
function M.signature(obj, fname)
    local f = try(function() return obj[fname] end)
    if f == nil then return nil, "no such member" end
    local params, done = {}, false
    local ok, err = pcall(function()
        f:ForEachProperty(function(prop)
            if done then return end
            local cls = try(function() return prop:GetClass():GetFName():ToString() end) or "?"
            local nm = try(function() return prop:GetFName():ToString() end) or "?"
            for _, pre in ipairs(LOCAL_PREFIXES) do
                if nm:sub(1, #pre) == pre then done = true; return end
            end
            params[#params + 1] = { name = nm, class = cls, ret = (nm == "ReturnValue") }
        end)
    end)
    if not ok then return nil, tostring(err) end
    return params
end

local function is_fname(v)
    return type(v) == "userdata" and try(function() return v:type() end) == "FName"
end

-- Problems with args (a table.pack) against params; an empty list means safe to
-- call. Only the native-fault classes are checked here, by position. Arity and
-- out-param tables are UE4SS's own Lua-error checks and are left to it.
function M.check_args(params, args)
    local problems = {}
    for i = 1, args.n do
        local p, v = params[i], args[i]
        if p and p.class == "NameProperty" and not is_fname(v) then
            problems[#problems + 1] = string.format("arg %d %s is an FName — pass FName(\"...\"), not %s", i, p.name, type(v))
        elseif p and p.class == "StructProperty" and type(v) ~= "table" and type(v) ~= "userdata" then
            problems[#problems + 1] = string.format("arg %d %s is a struct — pass a table, not %s", i, p.name, type(v))
        end
    end
    -- An FName parameter left off the end is as fatal as nil: UE4SS reads it anyway
    -- only if arity matches, but refuse rather than rely on that ordering.
    for i = args.n + 1, #params do
        local p = params[i]
        if p.class == "NameProperty" and not p.ret then
            problems[#problems + 1] = string.format("arg %d %s (FName) missing — pass FName(\"None\")", i, p.name)
        end
    end
    return problems
end

-- ------------------------------------------------------------------ snapshot / diff
-- Read every property of an object (whole class chain) whose type is safe to read and
-- cheap to show, so "what changed when I did X" is two snapshots and a diff.
-- Allowlist, not blocklist: reading a SoftObjectProperty has hard-crashed games through
-- UE4SS, and delegates/maps/sets are not worth the risk for a diff.
M.SNAP_TYPES = {
    BoolProperty = true, ByteProperty = true, IntProperty = true, Int64Property = true,
    UInt32Property = true, FloatProperty = true, DoubleProperty = true, NameProperty = true,
    StrProperty = true, EnumProperty = true, ObjectProperty = true, StructProperty = true,
    ArrayProperty = true,
}
M.SNAP_MAX = 800

function M.snapshot(obj)
    local out, n = {}, 0
    local cls = try(function() return obj:GetClass() end)
    local depth = 0
    while cls ~= nil and depth < 16 and n < M.SNAP_MAX do
        local valid = try(function() return cls:IsValid() end)
        if valid == false then break end
        pcall(function()
            cls:ForEachProperty(function(p)
                if n >= M.SNAP_MAX then return end
                local nm = try(function() return p:GetFName():ToString() end)
                local k = try(function() return p:GetClass():GetFName():ToString() end)
                if nm and k and M.SNAP_TYPES[k] and out[nm] == nil then
                    local v = try(function() return obj[nm] end)
                    if k == "ArrayProperty" then
                        local num = try(function() return v:GetArrayNum() end)
                        out[nm] = num and ("<TArray n=" .. num .. ">") or "?"
                    else
                        out[nm] = M.show(v, 1, nil, true)
                    end
                    n = n + 1
                end
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
    return out, n
end

-- Changed, added and removed keys between two snapshots, as sorted lines.
function M.diff(a, b)
    local lines = {}
    for k, v in pairs(b) do
        if a[k] == nil then lines[#lines + 1] = k .. ": (new) " .. v
        elseif a[k] ~= v then lines[#lines + 1] = k .. ": " .. a[k] .. " -> " .. v end
    end
    for k, v in pairs(a) do
        if b[k] == nil then lines[#lines + 1] = k .. ": " .. v .. " -> (gone)" end
    end
    table.sort(lines)
    return lines
end

-- The id from a request's first line (`--@id <id>`). Restricted to filename-safe
-- characters, because it becomes the response file's name.
function M.request_id(src)
    return src:match("^%-%-@id[ \t]+([%w_%-%.]+)")
end

-- Run one request's source in env; always returns response text, never raises.
function M.run(env, src, chunkname)
    local fn, cerr = load(src, "=" .. (chunkname or "req"), "t", env)
    if not fn then return "COMPILE ERROR: " .. tostring(cerr) .. "\n" end
    env.__begin()
    local res = table.pack(xpcall(fn, debug.traceback))
    local lines = env.__end()
    if res[1] then
        for i = 2, res.n do lines[#lines + 1] = "=> " .. M.show(res[i]) end
        lines[#lines + 1] = "OK"
    else
        lines[#lines + 1] = "ERROR: " .. tostring(res[2])
    end
    return table.concat(lines, "\n") .. "\n"
end

return M
