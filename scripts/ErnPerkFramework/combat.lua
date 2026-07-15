--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Shared combat hook utilities.

The OpenMW Combat interface allows any script to add its own onHit handler.
That works for isolated mods, but perk mods need a single ordered pipeline so
multiple effects can inspect and modify the same attack record before the
engine resolves the final result.
]]

local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local calculation = require("scripts.ErnPerkFramework.calculation")

local DEFAULT_PRIORITY = 1000

local handlers = {}
local nextOrder = 0
local hookInstalled = false

--- Sorts on-hit event handlers by priority and registration order.
local function sortHandlers()
    table.sort(handlers, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)
end

--- Runs registered on-hit event handlers, then resolves standard damage fields.
--- Event handlers are for detection and side effects; damage-affecting changes
--- should use calculation handlers so the final value is resolved once.
--- @param attack table OpenMW combat attack table.
local function dispatchOnHit(attack)
    local originalDamage = nil
    if attack.damage then
        originalDamage = {
            health = attack.damage.health,
            fatigue = attack.damage.fatigue,
            magicka = attack.damage.magicka,
        }
    end

    local context = {
        self = pself,
        target = pself,
        originalDamage = originalDamage,
        stop = false,
    }

    for _, entry in ipairs(handlers) do
        local ok, err = pcall(entry.handler, attack, context)
        if not ok then
            print("ErnPerkFramework onHit handler failed (" .. tostring(entry.id) .. "): " .. tostring(err))
        end
        if context.stop then
            break
        end
    end

    if attack.damage then
        if attack.damage.health ~= nil then
            attack.damage.health = calculation.resolveCalculation({
                calculation = calculation.CALCULATION.HIT_DAMAGE_HEALTH,
                baseValue = attack.damage.health,
                min = 0,
                actor = pself,
                source = attack.attacker,
                context = attack,
            })
        end
        if attack.damage.fatigue ~= nil then
            attack.damage.fatigue = calculation.resolveCalculation({
                calculation = calculation.CALCULATION.HIT_DAMAGE_FATIGUE,
                baseValue = attack.damage.fatigue,
                min = 0,
                actor = pself,
                source = attack.attacker,
                context = attack,
            })
        end
        if attack.damage.magicka ~= nil then
            attack.damage.magicka = calculation.resolveCalculation({
                calculation = calculation.CALCULATION.HIT_DAMAGE_MAGICKA,
                baseValue = attack.damage.magicka,
                min = 0,
                actor = pself,
                source = attack.attacker,
                context = attack,
            })
        end
    end
end

--- Installs the underlying OpenMW Combat hook once for this script context.
local function ensureHookInstalled()
    if hookInstalled then
        return
    end
    hookInstalled = true
    interfaces.Combat.addOnHitHandler(dispatchOnHit)
end

--- Validates and normalizes an on-hit event handler registration.
--- @param data table|function|nil Registration table or handler function.
--- @param handler function|nil Optional handler override.
--- @return table data Normalized registration data.
--- @return function handler Handler callback.
local function validateHandler(data, handler)
    if type(data) == "function" and handler == nil then
        handler = data
        data = {}
    end
    if data == nil then
        data = {}
    end
    if type(data) ~= "table" then
        error("registerOnHitHandler() first argument must be a table or function.", 3)
    end
    if handler == nil then
        handler = data.handler
    end
    if type(handler) ~= "function" then
        error("registerOnHitHandler() requires a handler function.", 3)
    end
    if data.id ~= nil and type(data.id) ~= "string" then
        error("registerOnHitHandler() id must be a string when provided.", 3)
    end
    if data.priority ~= nil and type(data.priority) ~= "number" then
        error("registerOnHitHandler() priority must be a number when provided.", 3)
    end

    return data, handler
end

--- Unregisters every on-hit event handler with the given id.
--- @param id string Handler id.
local function unregisterOnHitHandler(id)
    if type(id) ~= "string" then
        error("unregisterOnHitHandler() requires a string id.", 2)
    end
    for i = #handlers, 1, -1 do
        if handlers[i].id == id then
            table.remove(handlers, i)
        end
    end
end

--- Registers an on-hit event handler for this script context.
--- @param data table|function|nil Registration data or callback.
--- @param handler function|nil Optional callback when data is a table.
--- @return boolean success Always true after successful validation.
local function registerOnHitHandler(data, handler)
    data, handler = validateHandler(data, handler)
    ensureHookInstalled()

    if data.id ~= nil then
        unregisterOnHitHandler(data.id)
    end

    nextOrder = nextOrder + 1
    table.insert(handlers, {
        id = data.id or ("anonymous_" .. tostring(nextOrder)),
        priority = data.priority or DEFAULT_PRIORITY,
        order = nextOrder,
        handler = handler,
    })
    sortHandlers()
    return true
end

--- Returns on-hit handler metadata for diagnostics/debugging.
--- @return table handlers Handler metadata list.
local function getOnHitHandlers()
    local out = {}
    for _, entry in ipairs(handlers) do
        table.insert(out, {
            id = entry.id,
            priority = entry.priority,
        })
    end
    return out
end

return {
    DEFAULT_ON_HIT_PRIORITY = DEFAULT_PRIORITY,
    registerOnHitHandler = registerOnHitHandler,
    unregisterOnHitHandler = unregisterOnHitHandler,
    getOnHitHandlers = getOnHitHandlers,
}
