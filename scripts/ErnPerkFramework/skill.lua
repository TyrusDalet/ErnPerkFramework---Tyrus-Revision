--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2026 See AUTHORS.txt

Shared player skill-use dispatcher.

OpenMW exposes SkillProgression.addSkillUsedHandler, but if every perk mod
registers its own listener then each mod repeats the same spell/enchantment
source detection. This module installs one listener and fans the event out to
registered perk handlers in deterministic priority order.
]]

local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local pself = require("openmw.self")

local DEFAULT_PRIORITY = 1000
local handlers = {}
local nextOrder = 0
local installed = false
local lastSpellCast = nil

local SOURCE_TYPE = {
    Spell = "spell",
    Enchantment = "enchantment",
    Unknown = "unknown",
}

local SPELLCAST_START_KEYS = {
    ["self start"] = true,
    ["touch start"] = true,
    ["target start"] = true,
}

local SPELLCAST_STOP_KEYS = {
    ["self stop"] = true,
    ["touch stop"] = true,
    ["target stop"] = true,
}

local function sortHandlers()
    table.sort(handlers, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)
end

local function playerKnowsSpell(spell)
    if spell == nil or spell.id == nil then
        return false
    end
    for _, knownSpell in pairs(types.Actor.spells(pself)) do
        if knownSpell.id == spell.id then
            return true
        end
    end
    return false
end

local function selectedEnchantedItem()
    if types.Actor.getSelectedEnchantedItem == nil then
        return nil
    end
    return types.Actor.getSelectedEnchantedItem(pself)
end

local function captureSpellcast(groupname, key)
    if groupname ~= "spellcast" then
        return
    end
    if SPELLCAST_START_KEYS[key] then
        local enchantedItem = selectedEnchantedItem()
        local spell = types.Player.getSelectedSpell(pself)
        lastSpellCast = {
            spell = spell,
            cost = spell and spell.cost or 0,
            enchantedItem = enchantedItem,
            sourceType = enchantedItem and SOURCE_TYPE.Enchantment or SOURCE_TYPE.Spell,
            isPlayerCast = spell ~= nil and enchantedItem == nil and playerKnowsSpell(spell),
        }
    elseif SPELLCAST_STOP_KEYS[key] then
        lastSpellCast = nil
    end
end

local function dispatchSkillUsed(skillId, params)
    local cast = lastSpellCast or {}
    local event = {
        skillId = skillId,
        params = params,
        actor = pself,
        spell = cast.spell,
        cost = cast.cost or 0,
        enchantedItem = cast.enchantedItem,
        sourceType = cast.sourceType or SOURCE_TYPE.Unknown,
        isPlayerCast = cast.isPlayerCast == true,
    }

    for _, entry in ipairs(handlers) do
        if (entry.skill == nil or entry.skill == skillId) and
            (entry.sourceType == nil or entry.sourceType == event.sourceType) and
            (entry.playerCastOnly ~= true or event.isPlayerCast) then
            local ok, err = pcall(entry.handler, event)
            if not ok then
                print("ErnPerkFramework skill-use handler failed (" .. tostring(entry.id) .. "): " .. tostring(err))
            end
        end
    end
end

local function install()
    if installed then
        return
    end
    installed = true
    interfaces.AnimationController.addTextKeyHandler('', captureSpellcast)
    interfaces.SkillProgression.addSkillUsedHandler(dispatchSkillUsed)
end

--- Registers a skill-use handler.
--- @param data table Registration data: id, skill, sourceType, playerCastOnly, priority.
--- @param handler function|nil Callback receiving a skill-use event table.
--- @return boolean success Always true after successful validation.
local function registerSkillUseHandler(data, handler)
    if data == nil or type(data) ~= "table" then
        error("registerSkillUseHandler() requires a data table.", 3)
    end
    if handler == nil then
        handler = data.handler
    end
    if type(handler) ~= "function" then
        error("registerSkillUseHandler() requires a handler function.", 3)
    end
    if type(data.id) ~= "string" then
        error("registerSkillUseHandler() requires a string id.", 3)
    end
    if data.skill ~= nil and type(data.skill) ~= "string" then
        error("registerSkillUseHandler() skill must be a string when provided.", 3)
    end
    if data.priority ~= nil and type(data.priority) ~= "number" then
        error("registerSkillUseHandler() priority must be a number when provided.", 3)
    end

    for i = #handlers, 1, -1 do
        if handlers[i].id == data.id then
            table.remove(handlers, i)
        end
    end

    nextOrder = nextOrder + 1
    table.insert(handlers, {
        id = data.id,
        skill = data.skill,
        sourceType = data.sourceType,
        playerCastOnly = data.playerCastOnly == true,
        priority = data.priority or DEFAULT_PRIORITY,
        order = nextOrder,
        handler = handler,
    })
    sortHandlers()
    install()
    return true
end

--- Unregisters a skill-use handler by id.
--- @param id string Handler id.
local function unregisterSkillUseHandler(id)
    if type(id) ~= "string" then
        error("unregisterSkillUseHandler() requires a string id.", 2)
    end
    for i = #handlers, 1, -1 do
        if handlers[i].id == id then
            table.remove(handlers, i)
        end
    end
end

--- Returns registered skill-use handlers for diagnostics/debugging.
--- @return table handlers Handler metadata list.
local function getSkillUseHandlers()
    local out = {}
    for _, entry in ipairs(handlers) do
        table.insert(out, {
            id = entry.id,
            skill = entry.skill,
            sourceType = entry.sourceType,
            playerCastOnly = entry.playerCastOnly,
            priority = entry.priority,
        })
    end
    return out
end

return {
    DEFAULT_SKILL_USE_PRIORITY = DEFAULT_PRIORITY,
    SKILL_USE_SOURCE_TYPE = SOURCE_TYPE,
    registerSkillUseHandler = registerSkillUseHandler,
    unregisterSkillUseHandler = unregisterSkillUseHandler,
    getSkillUseHandlers = getSkillUseHandlers,
}
