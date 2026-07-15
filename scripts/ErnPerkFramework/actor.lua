--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Local actor script for non-player actors. It exposes framework runtime hooks
to NPC and creature scripts so perk mods can register shared pipelines without
each mod installing separate engine handlers.
]]

local MOD_NAME = require("scripts.ErnPerkFramework.settings").MOD_NAME
local combat = require("scripts.ErnPerkFramework.combat")
local calculation = require("scripts.ErnPerkFramework.calculation")

return {
    interfaceName = MOD_NAME,
    interface = {
        DEFAULT_ON_HIT_PRIORITY = combat.DEFAULT_ON_HIT_PRIORITY,
        DEFAULT_CALCULATION_PRIORITY = calculation.DEFAULT_CALCULATION_PRIORITY,
        CALCULATION_OPERATION = calculation.OPERATION,
        CALCULATION = calculation.CALCULATION,
        RESOURCE_OPERATION = calculation.RESOURCE_OPERATION,
        registerOnHitHandler = combat.registerOnHitHandler,
        unregisterOnHitHandler = combat.unregisterOnHitHandler,
        getOnHitHandlers = combat.getOnHitHandlers,
        registerCalculationHandler = calculation.registerCalculationHandler,
        unregisterCalculationHandler = calculation.unregisterCalculationHandler,
        resolveCalculation = calculation.resolveCalculation,
        applyActorResourceDelta = calculation.applyActorResourceDelta,
        getCalculationHandlers = calculation.getCalculationHandlers,
    },
}
