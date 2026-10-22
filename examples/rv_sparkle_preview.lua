--[[ RV There Yet? — sparkle preview + middle-click probe (DevBridge, runtime hooks: tracked,
    remove with `uedev clean`).

    While a plank is carried, cycles candidate Niagara systems that ship with the game,
    attached at five points along the board, 4 s each, naming the candidate on screen.
    Also logs every IA_TertiaryFire (middle mouse) event with posing state, to learn whether
    it fires once per click or every frame while held.
--]]

local CANDIDATES = { "NS_LighterSparks", "NS_FireEmberAmbient_01", "NS_WeldingHit", "NS_Ping_01" }
local POINTS = { -180, -90, 0, 90, 180 }      -- along the plank's local Z (its 4 m length)

local nfl = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")

local systems = {}
for _, s in ipairs(FindAllOf("NiagaraSystem") or {}) do
    local n = name(s):match("([^%.]+)$")
    for _, want in ipairs(CANDIDATES) do if n == want then systems[want] = s end end
end

SPARKLE = SPARKLE or { idx = 0, comps = {}, last = 0 }

local function clear()
    for _, comp in ipairs(SPARKLE.comps) do
        pcall(function() if comp:IsValid() then comp:DeactivateImmediate() end end)
    end
    SPARKLE.comps = {}
end
SPARKLE_CLEAR = clear

local function show_next()
    clear()
    local p = held()
    if not p then return end
    SPARKLE.idx = SPARKLE.idx % #CANDIDATES + 1
    local want = CANDIDATES[SPARKLE.idx]
    local sys = systems[want]
    if not sys then log("sparkle: %s not loaded", want); return end
    local root = p.RootComponent
    for _, z in ipairs(POINTS) do
        local ok, comp = pcall(call, nfl, "SpawnSystemAttached", sys, root, FName("None"),
            { X = 0.0, Y = 0.0, Z = z }, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, 0, true, true, 0, false)
        if ok and comp then SPARKLE.comps[#SPARKLE.comps + 1] = comp
        elseif not ok then log("sparkle spawn failed: %s", tostring(comp)) end
    end
    pcall(call, ksl, "PrintString", me(), string.format("SPARKLE TEST %d/%d: %s", SPARKLE.idx, #CANDIDATES, want),
        true, false, { R = 1.0, G = 0.9, B = 0.3, A = 1.0 }, 4.0, FName("devbridge_sparkle"))
    log("sparkle candidate %d: %s (%d spawned)", SPARKLE.idx, want, #SPARKLE.comps)
end

if not SPARKLE.loop then
    local ticks = 0
    SPARKLE.loop = loop(500, function()
        ticks = ticks + 1
        if ticks % 8 == 0 then ExecuteInGameThread(function() pcall(show_next) end) end
        return false
    end)
    TERT_N = 0
    hook("/Game/Ride/Character/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:InpActEvt_IA_TertiaryFire_K2Node_EnhancedInputActionEvent_31",
        function(self)
            TERT_N = TERT_N + 1
            if TERT_N > 400 then return end
            local c = self:get()
            if c:IsLocallyControlled() then log("tertiary #%d posing=%s", TERT_N, tostring(c.IsHandPosing)) end
        end)
end

local found = {}
for _, w in ipairs(CANDIDATES) do found[#found + 1] = w .. (systems[w] and "" or " (MISSING)") end
return "sparkle preview running: " .. table.concat(found, ", ") .. " | " .. show(installed())
