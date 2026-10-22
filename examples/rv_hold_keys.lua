--[[ RV There Yet? — direct plank control through the game's HoldTransform component.
    DEV TOOL, sent through DevBridge (`uedev run examples/rv_hold_keys.lua`), not a mod.

    The carried plank hovers at BP_FirstPersonCharacter_C.HoldTransform, a SceneComponent
    attached to FirstPersonCamera (stock relative location 75, 0, 200; rotation 0). Setting
    that component's relative transform moves/rotates the plank in true cm and degrees.
    LOCAL ONLY until a second client has confirmed what other players see.

    Numpad (NumLock ON — with it off, the numpad sends arrow keys instead):
      4 / 6   yaw  left / right          8 / 2   pitch up / down
      7 / 9   roll left / right          + / -   further / closer
      1 / 3   lower / raise              0       step: coarse (15°, 10 cm) <-> fine (1°, 1 cm)
      5       level (pitch and roll to 0, keep yaw)
      .       reset to stock

    Re-running this file updates the logic without binding the keys twice.
--]]

local STOCK = { X = 75.0, Y = 0.0, Z = 200.0 }
local COARSE = { deg = 15.0, cm = 10.0 }
local FINE = { deg = 1.0, cm = 1.0 }

local function char() return find("BP_FirstPersonCharacter_C") end
local function hold() local c = char(); return c and c.HoldTransform end

-- Start from whatever the component holds right now.
if H == nil then
    local ht = hold()
    local l, r = ht.RelativeLocation, ht.RelativeRotation
    H = { x = l.X, y = l.Y, z = l.Z, pitch = r.Pitch, yaw = r.Yaw, roll = r.Roll, fine = false }
end

local function wrap(a) return (a + 180.0) % 360.0 - 180.0 end
local function snap(v, step) return math.floor(v / step + 0.5) * step end

local function hud(extra)
    local c = char()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local text = string.format("PLANK  yaw %+.0f  pitch %+.0f  roll %+.0f  |  dist %.0f cm  height %+.0f cm  |  step %s%s",
        H.yaw, H.pitch, H.roll, H.x, H.z - STOCK.Z, H.fine and "FINE 1°/1cm" or "COARSE 15°/10cm",
        extra and ("  |  " .. extra) or "")
    pcall(call, ksl, "PrintString", c, text, true, false, { R = 0.4, G = 1.0, B = 0.6, A = 1.0 }, 4.0, FName("devbridge_hold"))
end

local function apply(extra)
    local ht = hold()
    if not ht then return end
    H.yaw, H.pitch, H.roll = wrap(H.yaw), math.max(-89.0, math.min(89.0, H.pitch)), wrap(H.roll)
    H.x = math.max(30.0, math.min(400.0, H.x))
    call(ht, "K2_SetRelativeLocation", { X = H.x, Y = H.y, Z = H.z }, false, {}, true)
    call(ht, "K2_SetRelativeRotation", { Pitch = H.pitch, Yaw = H.yaw, Roll = H.roll }, false, {}, true)
    hud(extra)
end

local function step() return H.fine and FINE or COARSE end
local function rot(axis, sign)
    local s = step().deg
    H[axis] = H[axis] + sign * s
    if not H.fine then H[axis] = snap(H[axis], s) end
end

H_actions = {
    NUM_FOUR  = function() rot("yaw", -1) end,
    NUM_SIX   = function() rot("yaw", 1) end,
    NUM_EIGHT = function() rot("pitch", 1) end,
    NUM_TWO   = function() rot("pitch", -1) end,
    NUM_SEVEN = function() rot("roll", -1) end,
    NUM_NINE  = function() rot("roll", 1) end,
    ADD       = function() H.x = H.x + step().cm end,
    SUBTRACT  = function() H.x = H.x - step().cm end,
    NUM_ONE   = function() H.z = H.z - step().cm end,
    NUM_THREE = function() H.z = H.z + step().cm end,
    NUM_ZERO  = function() H.fine = not H.fine end,
    NUM_FIVE  = function() H.pitch, H.roll = 0.0, 0.0 end,
    DECIMAL   = function()
        H.x, H.y, H.z, H.pitch, H.yaw, H.roll = STOCK.X, STOCK.Y, STOCK.Z, 0.0, 0.0, 0.0
    end,
}

-- Looked up at press time, so a re-run swaps the behaviour in place.
H_dispatch = function(key)
    local f = H_actions[key]
    if not f then return end
    f()
    apply(key == "DECIMAL" and "reset to stock" or nil)
end

if not H_bound then
    local bound = 0
    for key in pairs(H_actions) do
        local ok = pcall(RegisterKeyBind, Key[key], function()
            ExecuteInGameThread(function()
                local ok2, err = pcall(H_dispatch, key)
                if not ok2 then log("hold keys: %s failed: %s", key, tostring(err)) end
            end)
        end)
        if ok then bound = bound + 1 end
    end
    H_bound = bound
end

apply("numpad controls live")
return string.format("bound %d keys; state yaw=%.1f pitch=%.1f roll=%.1f x=%.1f z=%.1f", H_bound, H.yaw, H.pitch, H.roll, H.x, H.z)
