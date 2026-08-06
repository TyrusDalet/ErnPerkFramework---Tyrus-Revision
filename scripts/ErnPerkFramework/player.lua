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
local types = require("openmw.types")
local ui = require("openmw.ui")
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

--- Restores continuous spell effects that were removed independently of their
--- owning perk, most notably by Dispel. Removing and re-adding the spellbook
--- entry is necessary when the record remains known but its active effect does
--- not; ordinary powers are never processed unless a perk declares them here.
--- @param perk table Registered perk object.
local function reconcilePersistentSpells(perk)
    local activeSpells = types.Actor.activeSpells(pself)
    local spellbook = types.Actor.spells(pself)
    for index, spellId in ipairs(perk:persistentSpells()) do
        if type(spellId) ~= "string" or spellId == "" then
            log(nil, "Ignoring invalid persistent spell entry " .. tostring(index)
                .. " for perk " .. tostring(perk:id()) .. ".")
        elseif not activeSpells:isSpellActive(spellId) then
            local ok, err = pcall(function()
                if spellbook[spellId] then spellbook:remove(spellId) end
                spellbook:add(spellId)
            end)
            if ok then
                log(1, nil, "Restored persistent spell " .. spellId
                    .. " for perk " .. tostring(perk:id()) .. ".")
            else
                log(nil, "Could not restore persistent spell " .. spellId
                    .. " for perk " .. tostring(perk:id()) .. ": " .. tostring(err))
            end
        end
    end
end

local function syncPerks()
    log(2, nil, "syncPerks() started.")
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
            log(3, nil, "syncPerks() reapply begin: " .. tostring(perkID))
            local addOk, addErr = pcall(function() foundPerk:onAdd() end)
            if not addOk then
                log(nil, "syncPerks() onAdd failed for " .. tostring(perkID)
                    .. ": " .. tostring(addErr))
            else
                log(3, nil, "syncPerks() reapply end: " .. tostring(perkID))
            end
            log(3, nil, "syncPerks() persistent-spell check begin: "
                .. tostring(perkID))
            local spellOk, spellErr = pcall(reconcilePersistentSpells, foundPerk)
            if not spellOk then
                log(nil, "syncPerks() persistent-spell check failed for "
                    .. tostring(perkID) .. ": " .. tostring(spellErr))
            else
                log(3, nil, "syncPerks() persistent-spell check end: "
                    .. tostring(perkID))
            end
            observedOwnedPerks[perkID] = true
            pendingInitialReapply[perkID] = nil
        elseif pendingInitialReapply[perkID] then
            log(nil, "Deferring reapply for perk " .. perkID .. ", not registered yet.")
        end
        -- A large mod list can own hundreds of perks. Yield after every entry
        -- so their reconciliation callbacks and engine bindings are not all
        -- executed in one unbounded update frame.
        coroutine.yield()
    end

    log(2, nil, "syncPerks() ended.")
end

local SYNC_STEPS_PER_TICK = 24
local syncCoroutine = nil
local reloadPlayerPerks
local pendingReloadRequests = {}
local reloadCoroutine = nil
local activeReloadRequest = nil
local RELOAD_STEPS_PER_TICK = 8

--- Sends a queued rebuild result back to its requesting player script.
--- @param request table Request metadata.
--- @param result table Primitive rebuild result.
local function finishReloadRequest(request, result)
    result = result or {
        success = false,
        reason = "missing-result",
        restored = 0,
        forced = 0,
        failed = 1,
    }
    if request and request.resultEvent then
        result.requestId = request.requestId
        result.source = request.source
        result.requestedVersion = request.requestedVersion
        pself:sendEvent(request.resultEvent, result)
    end
end

--- Advances a queued lifecycle rebuild without monopolizing one update frame.
local function processReload()
    if reloadCoroutine == nil then return end
    for _ = 1, RELOAD_STEPS_PER_TICK do
        local ok, result = coroutine.resume(reloadCoroutine)
        if not ok then
            finishReloadRequest(activeReloadRequest, {
                success = false,
                reason = "reload-error",
                error = tostring(result),
                restored = 0,
                forced = 0,
                failed = 1,
            })
            reloadCoroutine = nil
            activeReloadRequest = nil
            return
        end
        if coroutine.status(reloadCoroutine) == "dead" then
            finishReloadRequest(activeReloadRequest, result)
            reloadCoroutine = nil
            activeReloadRequest = nil
            return
        end
    end
end

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

    -- A version migration owns the perk list until its complete acquisition
    -- order has been restored. Ordinary sync must not inspect a partial list.
    if reloadCoroutine ~= nil then
        processReload()
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

    -- External perk packs can request the same full lifecycle rebuild used by
    -- `luaperks reload`. Requests wait for the current sync to finish so a
    -- migration cannot respec ownership while the sync coroutine is iterating
    -- over it.
    if #pendingReloadRequests > 0 then
        activeReloadRequest = table.remove(pendingReloadRequests, 1)
        reloadCoroutine = coroutine.create(function()
            return reloadPlayerPerks({ batched = true })
        end)
        -- Do not begin lifecycle callbacks in the same frame that accepted the
        -- request; this also leaves a clean diagnostic boundary in the log.
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
        log(2, nil, "Perk " .. tostring(data.perkID) .. " is already active. Can't add it twice.")
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
    local cascade = interfaces.ErnPerkFramework.getPerkRefundCascade(data.perkID)
    if #cascade == 0 then
        return
    end
    local removeSet = {}
    for _, perkID in ipairs(cascade) do
        removeSet[perkID] = true
    end
    local activePerksByID = {}
    for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        if not removeSet[perkID] then
            table.insert(activePerksByID, perkID)
        end
    end
    interfaces.ErnPerkFramework._setPlayerPerks(activePerksByID)
    for _, perkID in ipairs(cascade) do
        local perk = interfaces.ErnPerkFramework.getPerks()[perkID]
        if perk then
            local ok, err = pcall(function() perk:onRemove() end)
            if not ok then
                log(nil, "Refund onRemove failed for " .. tostring(perkID) .. ": " .. tostring(err))
            end
        end
        forgetOwnedPerk(perkID)
    end
end

local function splitString(str)
    local out = {}
    for item in str:gmatch("([^,%s]+)") do
        table.insert(out, item)
    end
    return out
end

--- Prints player-invoked command output to the visible in-game console.
--- Framework diagnostics still use print()/log so they remain log-only.
--- @param message any Text or value to display.
local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

local function dumpPlayerPerks()
    consolePrint("PerkFramework owned perks:")
    local playerPerks = interfaces.ErnPerkFramework.getPlayerPerks()
    if #playerPerks == 0 then
        consolePrint("  none")
        return
    end

    for i, perkID in ipairs(playerPerks) do
        local foundPerk = interfaces.ErnPerkFramework.getPerks()[perkID]
        if foundPerk == nil then
            consolePrint("  " .. tostring(i) .. ". " .. tostring(perkID) .. " registered=false")
        else
            local ok, req = pcall(function()
                return foundPerk:evaluateRequirements()
            end)
            local reqText = "error"
            if ok and req ~= nil then
                reqText = tostring(req.satisfied)
            end
            local resourceID = interfaces.ErnPerkFramework.getPerkCostResource(foundPerk)
            consolePrint("  " .. tostring(i) .. ". " .. tostring(perkID)
                .. " registered=true"
                .. " requirements=" .. reqText
                .. " cost=" .. tostring(foundPerk:cost())
                .. " resource=" .. tostring(resourceID))
        end
    end
end

--- Rebuilds every currently owned perk through its normal lifecycle.
--- The ordered ownership list is the purchase history: respec clears it and
--- refunds its derived resource spending, then grantPerk repurchases entries
--- in the same order. A previously owned perk may bypass requirements when a
--- normal purchase fails, which preserves dialogue rewards and hidden perks;
--- real costs are always checked and therefore spent again.
reloadPlayerPerks = function(options)
    options = options or {}
    local purchaseOrder = {}
    for _, perkID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        purchaseOrder[#purchaseOrder + 1] = perkID
    end
    if #purchaseOrder == 0 then
        consolePrint("Perk Reload: no owned perks to rebuild.")
        return {
            success = true,
            reason = "no-owned-perks",
            restored = 0,
            forced = 0,
            failed = 0,
        }
    end

    -- Do not destroy ownership when one provider has not registered yet.
    -- This commonly occurs for a missing optional Core or during load order
    -- initialization and cannot be repaired through normal acquisition.
    for _, perkID in ipairs(purchaseOrder) do
        if interfaces.ErnPerkFramework.getPerk(perkID) == nil then
            consolePrint("Perk Reload aborted: " .. tostring(perkID)
                .. " is not currently registered.")
            return {
                success = false,
                reason = "perk-not-registered",
                perkID = perkID,
                restored = 0,
                forced = 0,
                failed = 0,
            }
        end
    end

    consolePrint("Perk Reload: rebuilding " .. tostring(#purchaseOrder)
        .. " owned perks in acquisition order.")
    syncCoroutine = nil
    pendingInitialReapply = {}
    observedOwnedPerks = {}

    local restored = 0
    local forced = 0
    local failed = 0

    -- Mirror respecPerks while allowing automatic migrations to yield between
    -- callbacks. Ownership is cleared only after every onRemove has run, which
    -- preserves the same callback semantics as an ordinary Framework respec.
    for index, perkID in ipairs(purchaseOrder) do
        local perk = interfaces.ErnPerkFramework.getPerk(perkID)
        log(3, nil, "Perk Reload remove begin " .. tostring(index)
            .. ": " .. tostring(perkID))
        local ok, err = pcall(function() perk:onRemove() end)
        if not ok then
            failed = failed + 1
            consolePrint("Perk Reload remove failed at " .. tostring(index)
                .. ": " .. tostring(perkID) .. " error=" .. tostring(err))
        else
            log(3, nil, "Perk Reload remove end " .. tostring(index)
                .. ": " .. tostring(perkID))
        end
        if options.batched then coroutine.yield() end
    end
    interfaces.ErnPerkFramework._setPlayerPerks({})

    for index, perkID in ipairs(purchaseOrder) do
        log(3, nil, "Perk Reload grant begin " .. tostring(index)
            .. ": " .. tostring(perkID))
        local callOk, success, reason = pcall(
            interfaces.ErnPerkFramework.grantPerk,
            perkID,
            { checkRequirements = true, checkCost = true }
        )
        local forcedThisPerk = false
        if callOk and not success and reason == "requirements" then
            callOk, success, reason = pcall(
                interfaces.ErnPerkFramework.grantPerk,
                perkID,
                { checkRequirements = false, checkCost = true }
            )
            forcedThisPerk = callOk and success == true
        end

        -- grantPerk records ownership before onAdd. If a callback throws, keep
        -- that truthful ownership/cost result but report the callback failure.
        local owned = interfaces.ErnPerkFramework.playerHasPerk(perkID)
        if success == true or (not callOk and owned) then
            restored = restored + 1
            if forcedThisPerk then forced = forced + 1 end
            observedOwnedPerks[perkID] = true
            pendingInitialReapply[perkID] = nil
            if not callOk then
                failed = failed + 1
                consolePrint("Perk Reload warning at " .. tostring(index)
                    .. ": " .. tostring(perkID)
                    .. " was restored but onAdd failed: " .. tostring(success))
            end
        else
            failed = failed + 1
            consolePrint("Perk Reload failed at " .. tostring(index)
                .. ": " .. tostring(perkID)
                .. " reason=" .. tostring(callOk and reason or success))
        end
        log(3, nil, "Perk Reload grant end " .. tostring(index)
            .. ": " .. tostring(perkID)
            .. " owned=" .. tostring(interfaces.ErnPerkFramework.playerHasPerk(perkID)))
        if options.batched then coroutine.yield() end
    end

    -- The rebuild itself just reconciled every callback. Leave one normal sync
    -- interval before checking again instead of immediately applying all perks
    -- for a third time during startup.
    remainingDT = 2.06
    consolePrint("Perk Reload complete: restored=" .. tostring(restored)
        .. " forced=" .. tostring(forced)
        .. " failed=" .. tostring(failed) .. ".")
    return {
        success = failed == 0,
        reason = failed == 0 and "complete" or "perk-rebuild-failed",
        restored = restored,
        forced = forced,
        failed = failed,
    }
end

--- Queues a full perk lifecycle rebuild for another player script.
--- The optional result event receives only primitive status fields and is sent
--- after the Framework's active synchronization coroutine has finished.
--- @param data table|nil Request metadata.
local function requestPlayerPerkReload(data)
    data = data or {}
    local resultEvent = data.resultEvent
    if type(resultEvent) ~= "string" or resultEvent == "" then
        resultEvent = nil
    end
    pendingReloadRequests[#pendingReloadRequests + 1] = {
        requestId = data.requestId,
        source = data.source,
        requestedVersion = data.requestedVersion,
        resultEvent = resultEvent,
    }
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
    local reload = command:lower() == "luaperks reload"
    local dump = command:lower() == "luaperks dump"

    if show ~= nil then
        consolePrint("Perk Show Menu: " .. tostring(show))
        local visible = splitString(show)
        if #visible == 0 then
            visible = nil
        end
        pself:sendEvent(settings.MOD_NAME .. "showPerkUI",
            { visiblePerks = visible })
    elseif respec then
        consolePrint("Perk Respec")
        syncCoroutine = nil
        pendingInitialReapply = {}
        observedOwnedPerks = {}
        interfaces.ErnPerkFramework.respecPerks()
        remainingDT = 0
    elseif reload then
        requestPlayerPerkReload({ source = "console" })
        consolePrint("Perk Reload queued. Close the console to begin the rebuild.")
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
        ErnPerkFramework_RequestPlayerPerkReload = requestPlayerPerkReload,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onConsoleCommand = onConsoleCommand,
    }
}
