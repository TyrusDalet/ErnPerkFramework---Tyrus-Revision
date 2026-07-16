--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2025 Erin Pentecost
2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local log = require("scripts.ErnPerkFramework.log")
local settings = require("scripts.ErnPerkFramework.settings")
local UI = require('openmw.interfaces').UI

settings.init()

local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local function shouldShowUI()
    -- now we have to see if there is at least one perk that we could buy
    for id, perk in pairs(interfaces.ErnPerkFramework.getPerks()) do
        if (not hasPerk(id)) and perk:evaluateRequirements().satisfied and interfaces.ErnPerkFramework.canAffordPerk(perk) then
            return true
        end
    end
    return false
end

local pendingInitialReapply = {}
local observedOwnedPerks = {}

local function observeOwnedPerks(snapshot)
    for _, perkID in ipairs(snapshot) do
        if not observedOwnedPerks[perkID] then
            observedOwnedPerks[perkID] = true
            pendingInitialReapply[perkID] = true
        end
    end
end

local function forgetOwnedPerk(perkID)
    observedOwnedPerks[perkID] = nil
    pendingInitialReapply[perkID] = nil
end

local function syncPerks()
    log(nil, "syncPerks() started.")
    -- Keep pruning until the number of perks stops going down. This handles
    -- dependency chains where removing one perk can invalidate another.
    --
    -- Missing perk IDs are preserved. With multiple perk mods/cores, sync can
    -- run before every provider has registered its perks; deleting those IDs
    -- would turn a temporary load-order gap into permanent save data loss.
    local snapshot = {}
    for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        table.insert(snapshot, perkID)
    end
    observeOwnedPerks(snapshot)
    local currentCount = #snapshot
    local removedAny = false
    for i = 1, 1000 do
        local currentPerksTotalCost = {}
        local filteredPerks = {}
        -- iterate from oldest to newest.
        for _, perkID in ipairs(snapshot) do
            local foundPerk = interfaces.ErnPerkFramework.getPerks()[perkID]
            if (foundPerk == nil) then
                log(nil, "Preserving perk " .. perkID .. ", not registered yet.")
                table.insert(filteredPerks, perkID)
            elseif foundPerk:evaluateRequirements().satisfied then
                local resourceID = interfaces.ErnPerkFramework.getPerkCostResource(foundPerk)
                currentPerksTotalCost[resourceID] = currentPerksTotalCost[resourceID] or 0
                if currentPerksTotalCost[resourceID] + foundPerk:cost() >
                    interfaces.ErnPerkFramework.totalAllowedPoints(resourceID) then
                    log(nil, "Removing perk " .. perkID .. ", not enough points.")
                    foundPerk:onRemove()
                    forgetOwnedPerk(perkID)
                    removedAny = true
                else
                    currentPerksTotalCost[resourceID] = currentPerksTotalCost[resourceID] + foundPerk:cost()
                    table.insert(filteredPerks, perkID)
                end
            else
                log(nil, "Removing perk " .. perkID .. ", don't meet requirements.")
                foundPerk:onRemove()
                forgetOwnedPerk(perkID)
                removedAny = true
            end
            coroutine.yield()
        end
        snapshot = filteredPerks

        if currentCount == #snapshot then
            -- there were no changes, so stop.
            break
        end
        currentCount = #snapshot
    end

    if removedAny then
        -- Now that removals are done, rewrite the owned list.
        interfaces.ErnPerkFramework._setPlayerPerks(snapshot)
    end

    -- Re-apply registered perks every sync pass. Many perk mods use onAdd as
    -- their reconciliation hook for travel/cell-change state, so sync must stay
    -- periodic. Successful reapply is intentionally quiet to avoid log spam.
    for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        local foundPerk = interfaces.ErnPerkFramework.getPerks()[perkID]
        if foundPerk then
            foundPerk:onAdd()
            observedOwnedPerks[perkID] = true
            pendingInitialReapply[perkID] = nil
        elseif pendingInitialReapply[perkID] then
            log(nil, "Deferring reapply for perk " .. perkID .. ", not registered yet.")
        end
    end

    log(nil, "syncPerks() ended.")
end

local SYNC_STEPS_PER_TICK = 128
local syncCoroutine = nil
local function processSync()
    if syncCoroutine == nil then
        syncCoroutine = coroutine.create(syncPerks)
    end
    for i = 1, SYNC_STEPS_PER_TICK do
        local ok, err = coroutine.resume(syncCoroutine)
        if not ok then
            print("syncPerks() failed: " .. tostring(err))
            syncCoroutine = nil
            return
        end
        if coroutine.status(syncCoroutine) == "dead" then
            syncCoroutine = nil
            return
        end
    end
end

local remainingDT = 0
local function onUpdate(dt)
    -- don't do anything if we are in the UI.
    if UI.getMode() ~= nil and UI.getMode() ~= "" then
        return
    end

    -- Once a sync has started, keep advancing it in small batches each frame
    -- instead of waiting for the normal periodic timer between coroutine
    -- resumes. This keeps reload/load reconciliation responsive without
    -- turning every ordinary frame into a full sync pass.
    if syncCoroutine ~= nil then
        processSync()
        return
    end

    -- don't call this all the time
    remainingDT = remainingDT - dt
    if remainingDT > 0 then
        return
    end

    remainingDT = 2.06
    -- sync often in case we drop requirements somehow
    processSync()
end

local function addPerk(data)
    if (data == nil) or (not data.perkID) then
        error("addPerk() called with invalid data.")
        return
    end
    local foundPerk = interfaces.ErnPerkFramework.getPerks()[data.perkID]
    if foundPerk == nil then
        error("addPerk(" .. tostring(data.perkID) .. ") called with bad perkID.")
        return
    end
    if hasPerk(data.perkID) then
        log(nil, "Perk " .. tostring(data.perkID) .. " is already active. Can't add it twice.")
        return
    end
    if foundPerk:evaluateRequirements().satisfied then
        if interfaces.ErnPerkFramework.canAffordPerk(foundPerk) then
            local activePerksByID = {}
            for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
                table.insert(activePerksByID, perkID)
            end
            table.insert(activePerksByID, data.perkID)
            interfaces.ErnPerkFramework._setPlayerPerks(activePerksByID)
            foundPerk:onAdd()
            observedOwnedPerks[data.perkID] = true
            pendingInitialReapply[data.perkID] = nil
        else
            log(nil,
                "Perk " ..
                tostring(data.perkID) ..
                " point cost can't be paid. Can't add it.")
        end
    else
        log(nil, "Perk " .. tostring(data.perkID) .. " requirements are not met. Can't add it.")
    end
end

local function removePerk(data)
    if (data == nil) or (not data.perkID) then
        error("removePerk() called with invalid data.")
        return
    end
    local foundPerk = interfaces.ErnPerkFramework.getPerks()[data.perkID]
    if foundPerk == nil then
        error("removePerk(" .. tostring(data.perkID) .. ") called with bad perkID.")
        return
    end
    local activePerksByID = {}
    for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        table.insert(activePerksByID, perkID)
    end
    for i, p in ipairs(activePerksByID) do
        if p == data.perkID then
            table.remove(activePerksByID, i)
            break
        end
    end
    interfaces.ErnPerkFramework._setPlayerPerks(activePerksByID)
    foundPerk:onRemove()
    forgetOwnedPerk(data.perkID)
end

local function splitString(str)
    local out = {}
    for item in str:gmatch("([^,%s]+)") do
        table.insert(out, item)
    end
    return out
end

local function dumpPlayerPerks()
    print("PerkFramework owned perks:")
    local playerPerks = interfaces.ErnPerkFramework.getPlayerPerks()
    if #playerPerks == 0 then
        print("  none")
        return
    end

    for i, perkID in ipairs(playerPerks) do
        local foundPerk = interfaces.ErnPerkFramework.getPerks()[perkID]
        if foundPerk == nil then
            print("  " .. tostring(i) .. ". " .. tostring(perkID) .. " registered=false")
        else
            local ok, req = pcall(function()
                return foundPerk:evaluateRequirements()
            end)
            local reqText = "error"
            if ok and req ~= nil then
                reqText = tostring(req.satisfied)
            end
            local resourceID = interfaces.ErnPerkFramework.getPerkCostResource(foundPerk)
            print("  " .. tostring(i) .. ". " .. tostring(perkID)
                .. " registered=true"
                .. " requirements=" .. reqText
                .. " cost=" .. tostring(foundPerk:cost())
                .. " resource=" .. tostring(resourceID))
        end
    end
end

--- Normalizes player-entered console commands before matching.
--- Some OpenMW console paths deliver commands with a trailing "\" marker;
--- strip it so `luaperks menu\` behaves exactly like `luaperks menu`.
--- @param command string|nil Raw console command.
--- @return string command Trimmed and whitespace-normalized command.
local function normalizeConsoleCommand(command)
    command = tostring(command or "")
    command = command:match("^%s*(.-)%s*$")
    command = command:gsub("%s*\\+$", "")
    command = command:match("^%s*(.-)%s*$")
    return command:gsub("%s+", " ")
end

local function onConsoleCommand(mode, command, selectedObject)
    command = normalizeConsoleCommand(command)
    local function getSuffixForCmd(prefix)
        local lower = command:lower()
        if lower == prefix then
            return ""
        end
        if lower:sub(1, #prefix + 1) == prefix .. " " then
            return command:sub(#prefix + 2)
        end
        return nil
    end
    local show = getSuffixForCmd("luaperks menu")
    local respec = command:lower() == "luaperks respec"
    local dump = command:lower() == "luaperks dump"

    if show ~= nil then
        print("Perk Show Menu: " .. tostring(show))
        local visible = splitString(show)
        if #visible == 0 then
            visible = nil
        end
        pself:sendEvent(settings.MOD_NAME .. "showPerkUI",
            { visiblePerks = visible })
    elseif respec then
        print("Perk Respec")
        syncCoroutine = nil
        pendingInitialReapply = {}
        observedOwnedPerks = {}
        interfaces.ErnPerkFramework.respecPerks()
        remainingDT = 0
    elseif dump then
        dumpPlayerPerks()
    end
end

local function UiModeChanged(data)
    if (data.newMode ~= nil) then
        return
    end
    -- spawn perk UI after the levelup UI.
    if data.oldMode == 'LevelUp' then
        if shouldShowUI() then
            pself:sendEvent(settings.MOD_NAME .. "showPerkUI", {})
        end
    elseif settings.showOnRest and data.oldMode == 'Rest' then
        -- showOnRest is true by default when NCGDMW or NCG is detected (see settings.lua).
        -- It can also be toggled manually in the mod options for any other rest-based
        -- levelling overhaul.
        if shouldShowUI() then
            pself:sendEvent(settings.MOD_NAME .. "showPerkUI", {})
        end
    else
        pself:sendEvent(settings.MOD_NAME .. "closePerkUI", {})
    end
end

return {
    eventHandlers = {
        UiModeChanged = UiModeChanged,
        [settings.MOD_NAME .. "addPerk"] = addPerk,
        [settings.MOD_NAME .. "removePerk"] = removePerk,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onConsoleCommand = onConsoleCommand,
    }
}
