--[[ RV There Yet? helpers for a DevBridge session.
    Load once per game session:  uedev run examples/rv_helpers.lua

      me()           the character THIS client controls (co-op safe)
      held()         the actor being carried, or nil
      looking_at()   what the GAME thinks you are aiming at: its own look-at tracker
                     (CurrentLookAtObject/Component/Trace, range LookAtDistance = 400 cm),
                     i.e. exactly what interactions use. Nothing while carrying.
      watch_me()     snapshot of me() for a later diff:  S = watch_me() ... diff(S, watch_me())
--]]

me = function()
    for _, c in ipairs(FindAllOf("BP_FirstPersonCharacter_C") or {}) do
        if call(c, "IsLocallyControlled") then return c end
    end
end

held = function()
    local c = me()
    local p = c and c.CurrentPickUpActor
    if p and p:IsValid() then return p end
end

looking_at = function()
    local c = me()
    if not c then return "no local character" end
    local function field(s, k)
        local ok, v = pcall(function() return s[k] end)
        if ok then return v end
    end
    local tr = c.CurrentLookAtTrace
    return {
        object = name(c.CurrentLookAtObject),
        component = name(c.CurrentLookAtComponent),
        distance = tr and field(tr, "Distance"),
        point = tr and show(field(tr, "ImpactPoint")),
        blocking = tr and field(tr, "bBlockingHit"),
        range = c.LookAtDistance,
    }
end

watch_me = function() return snap(me()) end

return "rv helpers loaded: me() held() looking_at() watch_me()"
