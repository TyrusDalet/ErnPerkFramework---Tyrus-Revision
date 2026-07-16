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

--- Applies framework resource damage/restoration from the target actor script.
--- @param data table resource, operation, amount, source, sourceEffect, damageType.
--- @return number amount Final resolved amount applied.
local function applyActorResourceDelta(data)
    data = data or {}
    local amount = data.amount or data.baseValue or data.value
    if type(amount) ~= "number" or amount <= 0 then
        return 0
    end

    local healthBefore = nil
    if data.resource == nil or data.resource == "health" then
        healthBefore = types.Actor.stats.dynamic.health(self).current
    end

    local applied = calculation.applyActorResourceDelta({
        actor = self,
        resource = data.resource or "health",
        operation = data.operation or data.kind or calculation.RESOURCE_OPERATION.Damage,
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

    if data.sourceEffect == "FactionPerks_IL_LegionaryResolve" then
        local healthAfter = healthBefore
        if healthBefore ~= nil then
            healthAfter = types.Actor.stats.dynamic.health(self).current
        end
        print("ErnPerkFramework resource actor applied Shield Wall amount="
            .. tostring(amount)
            .. " resolved=" .. tostring(applied)
            .. " healthBefore=" .. tostring(healthBefore)
            .. " healthAfter=" .. tostring(healthAfter))
    end

    return applied
end

return {
    eventHandlers = {
        ErnPerkFramework_ApplyActorResourceDelta = applyActorResourceDelta,
    },
}
