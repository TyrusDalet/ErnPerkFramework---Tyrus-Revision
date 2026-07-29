--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Custom actor-local resource delta bridge.

Global/player scripts cannot directly modify another actor's dynamic stats.
The framework global script attaches this local script on demand, then sends
resource damage/restoration here so the target actor applies it to itself.
]]

local calculation = require("scripts.ErnPerkFramework.calculation")
local self = require("openmw.self")
local types = require("openmw.types")

--- Reports the actual target-local resource write to an interested caller.
--- This distinguishes a queued cross-actor request from one that reached the
--- actor and lets perk diagnostics compare the resolved and observed deltas.
local function reportResult(data, result)
    local recipient = data.resultTarget
    if recipient == nil or not recipient:isValid() or data.resultEvent == nil then
        return
    end
    recipient:sendEvent(data.resultEvent, result)
end

--- Applies framework resource damage/restoration from the target actor script.
--- @param data table resource, operation, amount, source, sourceEffect, damageType.
--- @return number amount Final resolved amount applied.
local function applyActorResourceDelta(data)
    data = data or {}
    local amount = data.amount or data.baseValue or data.value
    if type(amount) ~= "number" or amount <= 0 then
        return 0
    end

    local resource = data.resource or "health"
    local operation = data.operation or data.kind or calculation.RESOURCE_OPERATION.Damage
    local stat = types.Actor.stats.dynamic[resource](self)
    local before = stat.current
    local ok, applied = pcall(calculation.applyActorResourceDelta, {
        actor = self,
        resource = resource,
        operation = operation,
        amount = amount,
        source = data.source,
        sourceEffect = data.sourceEffect,
        damageType = data.damageType,
        calculation = data.calculation,
        context = data.context or data,
        metadata = data.metadata,
        min = data.min,
        max = data.max,
    })
    local after = types.Actor.stats.dynamic[resource](self).current

    reportResult(data, {
        requestId = data.requestId,
        target = self,
        targetId = self.id,
        resource = resource,
        operation = operation,
        requested = amount,
        resolved = ok and applied or 0,
        before = before,
        after = after,
        observed = operation == calculation.RESOURCE_OPERATION.Damage
            and (before - after)
            or (after - before),
        sourceEffect = data.sourceEffect,
        contributors = data.metadata and data.metadata.contributors or nil,
        success = ok,
        error = ok and nil or tostring(applied),
    })

    if not ok then
        error(applied, 0)
    end

    if data.sourceEffect == "FactionPerks_IL_LegionaryResolve" then
        print("ErnPerkFramework resource actor applied Shield Wall amount="
            .. tostring(amount)
            .. " resolved=" .. tostring(applied)
            .. " healthBefore=" .. tostring(before)
            .. " healthAfter=" .. tostring(after))
    end

    return applied
end

return {
    eventHandlers = {
        ErnPerkFramework_ApplyActorResourceDelta = applyActorResourceDelta,
    },
}
