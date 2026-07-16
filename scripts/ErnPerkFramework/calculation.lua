--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Shared calculation resolver.

This is deliberately not hit-specific. Any actor-affecting value that several
mods may want to alter can be resolved through the same arithmetic order:

    Multiplier -> Divider -> Subtraction -> Addition -> Modifier

"Percent less" effects belong in Divider, not Multiplier. Modifier is for final
post-resolution work or exact final-value overrides.
]]

local OPERATION = {
    Multiplier = "Multiplier",
    Divider = "Divider",
    Subtraction = "Subtraction",
    Addition = "Addition",
    Modifier = "Modifier",
}

local CALCULATION = {
    HIT_DAMAGE_HEALTH = "hit.damage.health",
    HIT_DAMAGE_FATIGUE = "hit.damage.fatigue",
    HIT_DAMAGE_MAGICKA = "hit.damage.magicka",
    DIRECT_DAMAGE_HEALTH = "direct.damage.health",
    DIRECT_DAMAGE_FATIGUE = "direct.damage.fatigue",
    DIRECT_DAMAGE_MAGICKA = "direct.damage.magicka",
    DIRECT_RESTORE_HEALTH = "direct.restore.health",
    DIRECT_RESTORE_FATIGUE = "direct.restore.fatigue",
    DIRECT_RESTORE_MAGICKA = "direct.restore.magicka",
    ENCHANT_CAST_ON_USE_SELF_EFFECT_MAGNITUDE = "enchant.castOnUse.selfEffectMagnitude",
    ENCHANT_CONSTANT_EFFECT_SELF_EFFECT_MAGNITUDE = "enchant.constantEffect.selfEffectMagnitude",
}

local RESOURCE_OPERATION = {
    Damage = "damage",
    Restore = "restore",
}

local RESOURCE_CALCULATION = {
    damage = {
        health = CALCULATION.DIRECT_DAMAGE_HEALTH,
        fatigue = CALCULATION.DIRECT_DAMAGE_FATIGUE,
        magicka = CALCULATION.DIRECT_DAMAGE_MAGICKA,
    },
    restore = {
        health = CALCULATION.DIRECT_RESTORE_HEALTH,
        fatigue = CALCULATION.DIRECT_RESTORE_FATIGUE,
        magicka = CALCULATION.DIRECT_RESTORE_MAGICKA,
    },
}

local types = require("openmw.types")

local ORDER = {
    OPERATION.Multiplier,
    OPERATION.Divider,
    OPERATION.Subtraction,
    OPERATION.Addition,
    OPERATION.Modifier,
}

local DEFAULT_PRIORITY = 1000
local handlersByCalculation = {}
local nextOrder = 0

--- Sorts handlers by priority while preserving registration order for ties.
--- @param list table Handler entries for one operation bucket.
local function sortHandlers(list)
    table.sort(list, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)
end

--- Removes a handler id from every operation bucket for one calculation.
--- @param calculation string Calculation channel name.
--- @param id string Handler id to remove.
local function removeHandler(calculation, id)
    local byOperation = handlersByCalculation[calculation]
    if byOperation == nil then
        return
    end

    for _, operation in ipairs(ORDER) do
        local list = byOperation[operation]
        if list then
            for i = #list, 1, -1 do
                if list[i].id == id then
                    table.remove(list, i)
                end
            end
        end
    end
end

--- Validates and normalizes a calculation handler registration.
--- @param data table Registration data.
--- @param handler function|nil Optional handler override.
--- @return table data Normalized registration data.
--- @return function handler Handler callback.
local function validateRegistration(data, handler)
    if data == nil or type(data) ~= "table" then
        error("registerCalculationHandler() requires a data table.", 3)
    end
    if handler == nil then
        handler = data.handler
    end
    if type(handler) ~= "function" then
        error("registerCalculationHandler() requires a handler function.", 3)
    end
    if type(data.id) ~= "string" then
        error("registerCalculationHandler() requires a string id.", 3)
    end
    if type(data.calculation) ~= "string" then
        error("registerCalculationHandler() requires a string calculation.", 3)
    end
    if OPERATION[data.operation] == nil then
        error("registerCalculationHandler() operation must be Multiplier, Divider, Subtraction, Addition, or Modifier.", 3)
    end
    if data.priority ~= nil and type(data.priority) ~= "number" then
        error("registerCalculationHandler() priority must be a number when provided.", 3)
    end

    return data, handler
end

--- Registers one contribution to a named calculation channel.
--- Duplicate ids replace previous registrations within the same calculation.
--- @param data table Registration data: id, calculation, operation, priority.
--- @param handler function|nil Callback receiving calculation context.
--- @return boolean success Always true after successful validation.
local function registerCalculationHandler(data, handler)
    data, handler = validateRegistration(data, handler)

    handlersByCalculation[data.calculation] = handlersByCalculation[data.calculation] or {}
    local byOperation = handlersByCalculation[data.calculation]
    byOperation[data.operation] = byOperation[data.operation] or {}

    removeHandler(data.calculation, data.id)

    nextOrder = nextOrder + 1
    table.insert(byOperation[data.operation], {
        id = data.id,
        calculation = data.calculation,
        operation = data.operation,
        priority = data.priority or DEFAULT_PRIORITY,
        order = nextOrder,
        handler = handler,
    })
    sortHandlers(byOperation[data.operation])
    return true
end

--- Unregisters a calculation handler by id.
--- @param id string Handler id.
--- @param calculation string|nil Optional calculation name to limit removal.
local function unregisterCalculationHandler(id, calculation)
    if type(id) ~= "string" then
        error("unregisterCalculationHandler() requires a string id.", 2)
    end

    if calculation ~= nil then
        if type(calculation) ~= "string" then
            error("unregisterCalculationHandler() calculation must be a string when provided.", 2)
        end
        removeHandler(calculation, id)
        return
    end

    for calc, _ in pairs(handlersByCalculation) do
        removeHandler(calc, id)
    end
end

--- Extracts a numeric contribution from a handler return value.
--- @param result any Handler result.
--- @return number|nil value Numeric contribution, or nil for no-op.
local function contributionValue(result)
    if result == nil or result == false then
        return nil
    end
    if type(result) == "number" then
        return result
    end
    if type(result) == "table" then
        return result.value or result.amount
    end
    return nil
end

--- Applies one arithmetic operation contribution to the running value.
--- @param value number Current resolved value.
--- @param operation string Operation bucket name.
--- @param amount number|nil Contribution amount.
--- @return number value Updated value.
local function applyOperation(value, operation, amount)
    if amount == nil then
        return value
    end
    if operation == OPERATION.Multiplier then
        return value * amount
    elseif operation == OPERATION.Divider then
        if amount == 0 then
            return value
        end
        return value / amount
    elseif operation == OPERATION.Subtraction then
        return value - amount
    elseif operation == OPERATION.Addition then
        return value + amount
    elseif operation == OPERATION.Modifier then
        return amount
    end
    return value
end

--- Clamps a value against optional min/max bounds.
--- @param value number Current value.
--- @param minValue number|nil Minimum allowed value.
--- @param maxValue number|nil Maximum allowed value.
--- @return number value Clamped value.
local function clamp(value, minValue, maxValue)
    if minValue ~= nil and value < minValue then
        value = minValue
    end
    if maxValue ~= nil and value > maxValue then
        value = maxValue
    end
    return value
end

--- Resolves a named calculation through all registered operation buckets.
--- @param data table Resolution data: calculation, baseValue, actor, source, context, min, max.
--- @return number value Final resolved value.
local function resolveCalculation(data)
    if data == nil or type(data) ~= "table" then
        error("resolveCalculation() requires a data table.", 2)
    end
    local calculation = data.calculation or data.id
    if type(calculation) ~= "string" then
        error("resolveCalculation() requires a string calculation.", 2)
    end

    local value = data.baseValue
    if value == nil then
        value = data.value
    end
    if type(value) ~= "number" then
        error("resolveCalculation() requires a numeric baseValue.", 2)
    end

    local context = {
        calculation = calculation,
        baseValue = value,
        value = value,
        actor = data.actor,
        source = data.source,
        context = data.context,
        metadata = data.metadata or {},
    }

    local byOperation = handlersByCalculation[calculation]
    if byOperation == nil then
        return clamp(value, data.min, data.max)
    end

    for _, operation in ipairs(ORDER) do
        local list = byOperation[operation]
        if list then
            for _, entry in ipairs(list) do
                context.value = value
                local ok, result = pcall(entry.handler, context)
                if ok then
                    value = applyOperation(value, operation, contributionValue(result))
                    value = clamp(value, data.min, data.max)
                else
                    print("ErnPerkFramework calculation handler failed (" .. tostring(entry.id) .. "): " .. tostring(result))
                end
            end
        end
    end

    return clamp(value, data.min, data.max)
end

--- Resolves and applies direct actor resource damage or restoration.
--- `amount` is always positive; `operation` chooses whether it subtracts from
--- or restores to the selected dynamic stat.
--- @param data table actor, resource, amount, operation, source, context.
--- @return number amount Final resolved amount applied.
local function applyActorResourceDelta(data)
    if data == nil or type(data) ~= "table" then
        error("applyActorResourceDelta() requires a data table.", 2)
    end
    if data.actor == nil then
        error("applyActorResourceDelta() requires an actor.", 2)
    end

    local resource = data.resource
    if resource ~= "health" and resource ~= "fatigue" and resource ~= "magicka" then
        error("applyActorResourceDelta() resource must be health, fatigue, or magicka.", 2)
    end

    local operation = data.operation or data.kind
    if operation ~= RESOURCE_OPERATION.Damage and operation ~= RESOURCE_OPERATION.Restore then
        error("applyActorResourceDelta() operation must be damage or restore.", 2)
    end

    local amount = data.amount or data.baseValue or data.value
    if type(amount) ~= "number" then
        error("applyActorResourceDelta() requires a numeric amount.", 2)
    end
    amount = math.abs(amount)

    local context = data.context or {}
    context.resource = resource
    context.operation = operation
    context.sourceEffect = data.sourceEffect or context.sourceEffect
    context.damageType = data.damageType or context.damageType

    local finalAmount = resolveCalculation({
        calculation = data.calculation or RESOURCE_CALCULATION[operation][resource],
        baseValue = amount,
        min = data.min or 0,
        max = data.max,
        actor = data.actor,
        source = data.source,
        context = context,
        metadata = data.metadata,
    })

    local stat = types.Actor.stats.dynamic[resource](data.actor)
    if operation == RESOURCE_OPERATION.Damage then
        stat.current = stat.current - finalAmount
    else
        stat.current = math.min(stat.current + finalAmount, stat.base + stat.modifier)
    end
    return finalAmount
end

--- Returns registered calculation handlers for diagnostics/debugging.
--- @param calculation string|nil Optional calculation channel filter.
--- @return table handlers Handler metadata list.
local function getCalculationHandlers(calculation)
    local out = {}
    local function append(calc, byOperation)
        for _, operation in ipairs(ORDER) do
            for _, entry in ipairs(byOperation[operation] or {}) do
                table.insert(out, {
                    id = entry.id,
                    calculation = calc,
                    operation = entry.operation,
                    priority = entry.priority,
                })
            end
        end
    end

    if calculation ~= nil then
        if type(calculation) ~= "string" then
            error("getCalculationHandlers() calculation must be a string when provided.", 2)
        end
        append(calculation, handlersByCalculation[calculation] or {})
    else
        for calc, byOperation in pairs(handlersByCalculation) do
            append(calc, byOperation)
        end
    end
    return out
end

return {
    OPERATION = OPERATION,
    CALCULATION = CALCULATION,
    RESOURCE_OPERATION = RESOURCE_OPERATION,
    DEFAULT_CALCULATION_PRIORITY = DEFAULT_PRIORITY,
    registerCalculationHandler = registerCalculationHandler,
    unregisterCalculationHandler = unregisterCalculationHandler,
    resolveCalculation = resolveCalculation,
    applyActorResourceDelta = applyActorResourceDelta,
    getCalculationHandlers = getCalculationHandlers,
}
