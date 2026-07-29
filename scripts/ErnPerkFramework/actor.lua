--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Local actor script for non-player actors. It exposes framework runtime hooks
to NPC and creature scripts so perk mods can register shared pipelines without
each mod installing separate engine handlers.
]]

local MOD_NAME = require("scripts.ErnPerkFramework.ns")
local combat = require("scripts.ErnPerkFramework.combat")
local calculation = require("scripts.ErnPerkFramework.calculation")
local self = require("openmw.self")

--- Applies framework resource damage/restoration from the target actor script.
--- OpenMW only allows local scripts to modify an actor's dynamic stats, so
--- callers send this event to the actor that should receive the final delta.
--- @param data table resource, operation, amount, source, sourceEffect, damageType.
--- @return number amount Final resolved amount applied.
local function applyActorResourceDeltaEvent(data)
    data = data or {}
    local amount = data.amount or data.baseValue or data.value
    if type(amount) ~= "number" or amount <= 0 then
        return 0
    end

    local context = data.context or {}
    context.sourceEffect = data.sourceEffect or context.sourceEffect
    context.damageType = data.damageType or context.damageType

    return calculation.applyActorResourceDelta({
        actor = self,
        resource = data.resource or "health",
        operation = data.operation or data.kind or calculation.RESOURCE_OPERATION.Damage,
        amount = amount,
        source = data.source,
        sourceEffect = data.sourceEffect,
        damageType = data.damageType,
        calculation = data.calculation,
        context = context,
        metadata = data.metadata,
        min = data.min,
        max = data.max,
    })
end

return {
    interfaceName = MOD_NAME,
    interface = {
        HIT_BRIDGE_REVISION = combat.HIT_BRIDGE_REVISION,
        DEFAULT_ON_HIT_PRIORITY = combat.DEFAULT_ON_HIT_PRIORITY,
        HIT_DIRECTION = combat.HIT_DIRECTION,
        DEFAULT_CALCULATION_PRIORITY = calculation.DEFAULT_CALCULATION_PRIORITY,
        CALCULATION_OPERATION = calculation.OPERATION,
        CALCULATION = calculation.CALCULATION,
        RESOURCE_OPERATION = calculation.RESOURCE_OPERATION,
        registerOnHitHandler = combat.registerOnHitHandler,
        unregisterOnHitHandler = combat.unregisterOnHitHandler,
        getOnHitHandlers = combat.getOnHitHandlers,
        registerRawOnHitObserver = combat.registerRawOnHitObserver,
        unregisterRawOnHitObserver = combat.unregisterRawOnHitObserver,
        getRawOnHitObservers = combat.getRawOnHitObservers,
        getHitDirection = combat.getHitDirection,
        dispatchOnHit = combat.dispatchOnHit,
        addHitDamage = combat.addHitDamage,
        registerCalculationHandler = calculation.registerCalculationHandler,
        unregisterCalculationHandler = calculation.unregisterCalculationHandler,
        resolveCalculation = calculation.resolveCalculation,
        applyActorResourceDelta = calculation.applyActorResourceDelta,
        getCalculationHandlers = calculation.getCalculationHandlers,
    },
    eventHandlers = {
        ErnPerkFramework_ApplyActorResourceDelta = applyActorResourceDeltaEvent,
        [MOD_NAME .. "_ApplyActorResourceDelta"] = applyActorResourceDeltaEvent,
    },
}
