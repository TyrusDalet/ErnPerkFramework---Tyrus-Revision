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
local MOD_NAME = require("scripts.ErnPerkFramework.settings").MOD_NAME
local perkUtil = require("scripts.ErnPerkFramework.perk")
local pself = require("openmw.self")
local reqs = require("scripts.ErnPerkFramework.requirements")
local types = require("openmw.types")
local interfaces = require("openmw.interfaces")
local settings = require("scripts.ErnPerkFramework.settings")
local combat = require("scripts.ErnPerkFramework.combat")
local calculation = require("scripts.ErnPerkFramework.calculation")
local skill = require("scripts.ErnPerkFramework.skill")

if require("openmw.core").API_REVISION < 62 then
    error("OpenMW 0.49 or newer is required!")
end

local version = 1
local GENERIC_RESOURCE_ID = "generic"

-- manifest of registered perks. This is a map of ID -> perk record.
local perkTable = {}
-- list of all perk IDs.
local perkIDs = {}

-- list of perks, in the order they were picked.
local playerPerks = {}
-- set of perks currently owned by the player. Kept in sync with playerPerks
-- so requirement checks and UI state do not repeatedly scan the ordered list.
local playerPerkSet = {}
local playerPerkRevision = 0
local perkResources = {
    [GENERIC_RESOURCE_ID] = {
        id = GENERIC_RESOURCE_ID,
        name = "Perk Point",
        pluralName = "Perk Points",
    },
}
local perkResourceTotals = {}
-- Source name -> flat stat modifier report. This is a framework-owned read
-- registry first, and an optional AbilitiesAsModifiers display bridge second.
local externalModifierReports = {}

local function copyArray(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        table.insert(out, value)
    end
    return out
end

local function copyMap(map)
    local out = {}
    for key, value in pairs(map or {}) do
        out[key] = value
    end
    return out
end

local function rebuildPlayerPerkSet()
    playerPerkSet = {}
    for _, perkID in ipairs(playerPerks) do
        playerPerkSet[perkID] = true
    end
    playerPerkRevision = playerPerkRevision + 1
end

--- Validates a single requirement data table.
--- Requirements must have `id` (string) and `check` (function).
--- `localizedName` (string or function) is optional.
--- @param requirement table The requirement data to validate.
--- @return boolean True if valid, false otherwise (errors are thrown on failure).
local function validateRequirement(requirement)
    if (not requirement) or (type(requirement) ~= "table") then
        error("validateRequirement() argument is not a table.", 3)
        return false
    end
    if (not requirement.id) or (type(requirement.id) ~= "string") then
        error("validateRequirement() requirement data is missing a string 'id' field.", 3)
        return false
    end
    if (not requirement.check) or (type(requirement.check) ~= "function") then
        error("validateRequirement() requirement data is missing a function 'check' field.", 3)
        return false
    end
    if (requirement.localizedName ~= nil) then
        if (type(requirement.localizedName) ~= "function") and (type(requirement.localizedName) ~= "string") then
            error(
                "validateRequirement() requirement data has a 'localizedName' field, which must be a string or a function that returns a string.",
                3)
            return false
        end
    end
    return true
end

---@class PerkData
---@field id string                                  -- Unique perk ID
---@field requirements table                         -- Array of requirement objects (validated elsewhere)
---@field onAdd fun(perk: table)                     -- Called when the perk is added
---@field onRemove fun(perk: table)                  -- Called when the perk is removed
---@field localizedName? string|fun():string         -- Display name or function returning it
---@field localizedDescription? string|fun():string  -- Description or function returning it
---@field localizedFlavour? string|fun():string      -- Muted flavour text shown above the description
---@field localizedFlavor? string|fun():string       -- Alias for localizedFlavour
---@field art? string|fun():string                   -- Texture path or function returning it
---@field hidden? boolean|fun():boolean              -- Whether perk is hidden
---@field cost? number|fun():number                  -- Cost of the perk
---@field costResource? string|fun():string          -- Optional custom resource spent to acquire the perk
---@field category? table                            -- Optional category data.
--                                                  -- Supported shapes:
--                                                  --   { "TypeName", "GroupName", sortOrder }
--                                                  --   { "ModName", "TypeName", "GroupName", sortOrder }
--                                                  --   { mod="ModName", type="TypeName", group="GroupName", order=sortOrder }
--                                                  -- Missing mod is shown under "Unsorted".

--- Registers a new perk into the framework.
--- Perks must have `id`, `requirements` (table), `onAdd` (function), and `onRemove` (function).
--- Optional fields: `localizedName`, `localizedDescription`, `localizedFlavour`, `art`, `hidden`, `cost`.
--- If a perk with the same ID already exists, it is replaced.
--- @param data PerkData The perk record data to register.
--- @return boolean True upon successful registration.
local function registerPerk(data)
    if (not data) or (type(data) ~= "table") then
        error("registerPerk() argument is not a table.", 2)
        return false
    end
    if (not data.id) or (type(data.id) ~= "string") then
        error("registerPerk() perk data is missing a string 'id' field.", 2)
        return false
    end
    if (not data.requirements) or (type(data.requirements) ~= "table") then
        error("registerPerk(" .. tostring(data.id) .. ") perk data is missing a table 'requirements' field.", 2)
        return false
    end
    if (not data.onAdd) or (type(data.onAdd) ~= "function") then
        error("registerPerk(" .. tostring(data.id) .. ") perk data is missing a function 'onAdd' field.", 2)
        return false
    end
    if (not data.onRemove) or (type(data.onRemove) ~= "function") then
        error("registerPerk(" .. tostring(data.id) .. ") perk data is missing a function 'onRemove' field.", 2)
        return false
    end
    if (data.localizedName ~= nil) then
        if (type(data.localizedName) ~= "function") and (type(data.localizedName) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'localizedName' field, which must be a string or a function that returns a string.", 2)
            return false
        end
    end
    if (data.localizedDescription ~= nil) then
        if (type(data.localizedDescription) ~= "function") and (type(data.localizedDescription) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'localizedDescription' field, which must be a string or a function that returns a string.",
                2)
            return false
        end
    end
    if (data.localizedFlavour ~= nil) then
        if (type(data.localizedFlavour) ~= "function") and (type(data.localizedFlavour) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'localizedFlavour' field, which must be a string or a function that returns a string.",
                2)
            return false
        end
    end
    if (data.localizedFlavor ~= nil) then
        if (type(data.localizedFlavor) ~= "function") and (type(data.localizedFlavor) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'localizedFlavor' field, which must be a string or a function that returns a string.",
                2)
            return false
        end
    end
    if (data.art ~= nil) then
        if (type(data.art) ~= "function") and (type(data.art) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has an 'art' field, which must be a string or a function that returns a texture path.",
                2)
            return false
        end
    end
    if (data.hidden ~= nil) then
        -- Hidden perks don't normally appear in the menu.
        if (type(data.hidden) ~= "function") and (type(data.hidden) ~= "boolean") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'hidden' field, which must be a boolean or a function that returns a boolean.",
                2)
            return false
        end
    end
    if (data.cost ~= nil) then
        if (type(data.cost) ~= "function") and (type(data.cost) ~= "number") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'cost' field, which must be a number or a function that returns a number.",
                2)
            return false
        end
    end
    if (data.costResource ~= nil) then
        if (type(data.costResource) ~= "function") and (type(data.costResource) ~= "string") then
            error(
                "registerPerk(" ..
                tostring(data.id) ..
                ") perk data has a 'costResource' field, which must be a string or a function that returns a string.",
                2)
            return false
        end
    end

    -- category is optional. It can be the legacy 3-element array
    -- { typeName, groupName, sortOrder }, the newer 4-element array
    -- { modName, typeName, groupName, sortOrder }, or a named table
    -- { mod=..., type=..., group=..., order=... }.
    if (data.category ~= nil) then
        if type(data.category) ~= "table" then
            error(
                "registerPerk(" .. tostring(data.id) ..
                ") perk data has a 'category' field, which must be a table.", 2)
            return false
        end
        local cat = data.category
        local usesNamedShape = cat.mod ~= nil or cat.type ~= nil or cat.group ~= nil or cat.order ~= nil
        if usesNamedShape then
            if cat.mod ~= nil and type(cat.mod) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category.mod must be a string when provided.", 2)
                return false
            end
            if cat.type ~= nil and type(cat.type) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category.type must be a string when provided.", 2)
                return false
            end
            if cat.group ~= nil and type(cat.group) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category.group must be a string when provided.", 2)
                return false
            end
            if cat.order ~= nil and type(cat.order) ~= "number" then
                error("registerPerk(" .. tostring(data.id) .. ") category.order must be a number when provided.", 2)
                return false
            end
        elseif type(cat[4]) == "number" then
            if type(cat[1]) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category[1] must be a string (mod name).", 2)
                return false
            end
            if type(cat[2]) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category[2] must be a string (type name).", 2)
                return false
            end
            if type(cat[3]) ~= "string" then
                error("registerPerk(" .. tostring(data.id) .. ") category[3] must be a string (group name).", 2)
                return false
            end
        else
            if type(cat[1]) ~= "string" then
                error(
                    "registerPerk(" .. tostring(data.id) ..
                    ") category[1] must be a string (type name, e.g. \"Faction\").", 2)
                return false
            end
            if type(cat[2]) ~= "string" then
                error(
                    "registerPerk(" .. tostring(data.id) ..
                    ") category[2] must be a string (group name, e.g. \"Mages Guild\").", 2)
                return false
            end
            if type(cat[3]) ~= "number" then
                error(
                    "registerPerk(" .. tostring(data.id) ..
                    ") category[3] must be a number (sort order within the group).", 2)
                return false
            end
        end
    end

    for i, r in ipairs(data.requirements) do
        if not validateRequirement(r) then
            error("registerPerk(" .. tostring(data.id) .. ") perk data has a bad requirement at index " .. tostring(i), 2)
            return false
        end
    end

    -- check if we have an id collision.
    -- we want to allow this so perk mods can patch eachother.
    if perkTable[data.id] ~= nil then
        print("registerPerk(" .. tostring(data.id) .. ") is replacing an existing perk.")
        -- Call onRemove for any player that registered the old one previously?
        -- Gets messy because the ID of the removed perk is unavailable once we leave this
        -- function.
    else
        -- didn't previously exist
        print("registerPerk(" .. tostring(data.id) .. ") completed.")
        table.insert(perkIDs, data.id)
    end

    perkTable[data.id] = perkUtil.NewPerk(data)
    return true
end

--- Gets the map of all registered perks (ID -> perk object).
--- @return table A map of registered perk ID to perk object.
local function getPerks()
    return perkTable
end

--- Gets one registered perk by ID.
--- Use this when checking another mod's perk metadata without assuming that
--- the player currently owns that perk.
--- @param perkID string The registered perk ID to look up.
--- @return table|nil perk The perk object, or nil if no loaded perk registered this ID.
local function getPerk(perkID)
    if type(perkID) ~= "string" then
        error("getPerk() requires a string perkID.", 2)
    end
    return perkTable[perkID]
end

--- Returns whether a perk ID has been registered by any loaded perk mod.
--- This tests installed/loaded capability, not player ownership.
--- @param perkID string The registered perk ID to test.
--- @return boolean registered True if a loaded mod registered this perk.
local function isPerkRegistered(perkID)
    return getPerk(perkID) ~= nil
end

--- Gets a list of all registered perk IDs.
--- @return table A list (array) of perk IDs (strings).
local function getPerkIDs()
    return perkIDs
end

--- Gets the table of common requirement builder functions.
--- @return table The requirement builder functions module.
local function requirements()
    return reqs
end

--- getPerksForPlayer returns a list of perk IDs in the order that the player chose them.
--- This list only contains the IDs of the perks the player currently has.
--- @return table A list (array) of perk IDs (strings).
local function getPlayerPerks()
    return playerPerks
end

--- Returns the cached player perk ownership set.
--- Keys are perk IDs, values are true. Treat as read-only.
--- @return table set Map of currently owned perk IDs.
local function getPlayerPerkSet()
    return playerPerkSet
end

--- Returns true if the player currently owns a perk.
--- @param perkID string Perk ID to test.
--- @return boolean owned True when the player owns this perk.
local function playerHasPerk(perkID)
    if type(perkID) ~= "string" then
        error("playerHasPerk() requires a string perkID.", 2)
    end
    return playerPerkSet[perkID] == true
end

--- Returns a monotonic revision that changes when player perk ownership changes.
--- UI code can use this to invalidate cached ownership-dependent state.
--- @return number revision Current player perk ownership revision.
local function getPlayerPerkRevision()
    return playerPerkRevision
end

local function customResourcesEnabled()
    return settings.allowCustomPerkAcquisitionMethods == true
end

--- Registers a custom perk point/token resource.
--- Custom resources are only spent when allowCustomPerkAcquisitionMethods is enabled.
--- @param data table Resource data: id, name, pluralName.
--- @return boolean success Always true after validation.
local function registerPerkResource(data)
    if data == nil or type(data) ~= "table" then
        error("registerPerkResource() requires a data table.", 2)
    end
    if type(data.id) ~= "string" then
        error("registerPerkResource() requires a string id.", 2)
    end
    if data.id == GENERIC_RESOURCE_ID then
        error("registerPerkResource() cannot replace the generic resource.", 2)
    end
    if data.name ~= nil and type(data.name) ~= "string" then
        error("registerPerkResource() name must be a string when provided.", 2)
    end
    if data.pluralName ~= nil and type(data.pluralName) ~= "string" then
        error("registerPerkResource() pluralName must be a string when provided.", 2)
    end

    perkResources[data.id] = {
        id = data.id,
        name = data.name or data.id,
        pluralName = data.pluralName or ((data.name or data.id) .. "s"),
    }
    perkResourceTotals[data.id] = perkResourceTotals[data.id] or 0
    return true
end

--- Returns metadata for one perk resource.
--- @param resourceID string Resource id.
--- @return table resource Resource metadata.
local function getPerkResource(resourceID)
    if type(resourceID) ~= "string" then
        error("getPerkResource() requires a string resourceID.", 2)
    end
    return perkResources[resourceID] or {
        id = resourceID,
        name = resourceID,
        pluralName = resourceID .. "s",
    }
end

--- Returns the resource registry.
--- @return table resources Resource id -> metadata.
local function getPerkResources()
    return perkResources
end

local function getPerkCostResource(perk)
    if not customResourcesEnabled() then
        return GENERIC_RESOURCE_ID
    end
    if type(perk) == "string" then
        perk = getPerks()[perk]
    end
    if perk ~= nil then
        return perk:costResource() or GENERIC_RESOURCE_ID
    end
    return GENERIC_RESOURCE_ID
end

--- Adds earned points/tokens to a custom resource total.
--- Generic level-based points cannot be modified through this function.
--- @param resourceID string Custom resource id.
--- @param amount number Amount to add. Negative values remove earned total.
--- @return number total New earned total.
local function addPerkResource(resourceID, amount)
    if type(resourceID) ~= "string" then
        error("addPerkResource() requires a string resourceID.", 2)
    end
    if resourceID == GENERIC_RESOURCE_ID then
        error("addPerkResource() cannot modify generic level-based points.", 2)
    end
    if type(amount) ~= "number" then
        error("addPerkResource() requires a numeric amount.", 2)
    end
    perkResourceTotals[resourceID] = math.max(0, (perkResourceTotals[resourceID] or 0) + math.floor(amount))
    return perkResourceTotals[resourceID]
end

--- Sets a custom resource earned total.
--- Generic level-based points cannot be modified through this function.
--- @param resourceID string Custom resource id.
--- @param amount number New total.
--- @return number total New earned total.
local function setPerkResource(resourceID, amount)
    if type(resourceID) ~= "string" then
        error("setPerkResource() requires a string resourceID.", 2)
    end
    if resourceID == GENERIC_RESOURCE_ID then
        error("setPerkResource() cannot modify generic level-based points.", 2)
    end
    if type(amount) ~= "number" then
        error("setPerkResource() requires a numeric amount.", 2)
    end
    perkResourceTotals[resourceID] = math.max(0, math.floor(amount))
    return perkResourceTotals[resourceID]
end

--- _setPlayerPerks replaces the ordered list of perk IDs that the player chose.
--- You don't want to use this for general perk manipulation, since it won't call
--- onAdd or onRemove.
--- @param perkIDList table The new ordered list of perk IDs to set for the player.
local function _setPlayerPerks(perkIDList)
    playerPerks = {}
    local seen = {}
    for _, perkID in ipairs(perkIDList or {}) do
        if type(perkID) == "string" and not seen[perkID] then
            table.insert(playerPerks, perkID)
            seen[perkID] = true
        end
    end
    rebuildPlayerPerkSet()
end

--- respecPerks removes all perks from the player.
local function respecPerks()
    print(nil, "respec() started.")
    local snapshot = copyArray(getPlayerPerks())
    for _, perkID in ipairs(snapshot) do
        local foundPerk = getPerks()[perkID]
        if foundPerk then
            print(nil, "Removing perk " .. perkID .. ".")
            local ok, err = pcall(function()
                foundPerk:onRemove()
            end)
            if not ok then
                print("respecPerks() onRemove failed for " .. tostring(perkID) .. ": " .. tostring(err))
            end
        end
    end
    _setPlayerPerks({})
    print(nil, "respec() ended.")
end

--- totalAllowedPoints returns how many total perk resource points the player has.
--- This value includes spent and unspent points.
--- @param resourceID string|nil Resource id. Defaults to generic level-based points.
--- @return number total Total points/tokens earned.
local function totalAllowedPoints(resourceID)
    resourceID = resourceID or GENERIC_RESOURCE_ID
    if resourceID ~= GENERIC_RESOURCE_ID and customResourcesEnabled() then
        return perkResourceTotals[resourceID] or 0
    end
    local level = types.Actor.stats.level(pself).current
    return math.floor(settings.perksPerLevel * level)
end

--- currentSpentPoints returns how many perk resource points have been allocated.
--- @param resourceID string|nil Resource id. Defaults to generic level-based points.
--- @return number spent Spent points/tokens.
local function currentSpentPoints(resourceID)
    resourceID = resourceID or GENERIC_RESOURCE_ID
    local total = 0
    for _, foundID in ipairs(getPlayerPerks()) do
        local foundPerk = getPerks()[foundID]
        if foundPerk and getPerkCostResource(foundPerk) == resourceID then
            total = total + foundPerk:cost()
        end
    end
    return total
end

--- Returns unspent points/tokens for one resource.
--- @param resourceID string|nil Resource id. Defaults to generic level-based points.
--- @return number available Unspent points/tokens.
local function availablePoints(resourceID)
    resourceID = resourceID or GENERIC_RESOURCE_ID
    return totalAllowedPoints(resourceID) - currentSpentPoints(resourceID)
end

--- Returns unspent points/tokens for the resource a perk spends.
--- @param perk table|string Perk object or perk id.
--- @return number available Unspent points/tokens for this perk's resource.
local function availablePointsForPerk(perk)
    return availablePoints(getPerkCostResource(perk))
end

--- Returns whether the player can afford a perk using its current resource.
--- @param perk table|string Perk object or perk id.
--- @return boolean affordable True if enough resource is available.
local function canAffordPerk(perk)
    if type(perk) == "string" then
        perk = getPerks()[perk]
    end
    if perk == nil then
        return false
    end
    return perk:cost() <= availablePointsForPerk(perk)
end

--- Grants a perk directly from trusted script code.
--- Use this for trainers, dialogue rewards, quest rewards, or other acquisition
--- paths that should not behave like a normal perk menu purchase. By default it
--- bypasses requirements and resource cost; callers can opt back into either
--- check when they want framework validation without spending points.
--- @param perkID string Perk id to grant.
--- @param options table|nil Optional flags: checkRequirements, checkCost.
--- @return boolean success True when the perk was newly granted.
--- @return string|nil reason Failure reason: badPerk, alreadyOwned, requirements, or cost.
local function grantPerk(perkID, options)
    if type(perkID) ~= "string" then
        error("grantPerk() requires a string perkID.", 2)
    end
    options = options or {}

    local foundPerk = getPerk(perkID)
    if foundPerk == nil then
        return false, "badPerk"
    end
    if playerHasPerk(perkID) then
        return false, "alreadyOwned"
    end
    if options.checkRequirements == true and not foundPerk:evaluateRequirements().satisfied then
        return false, "requirements"
    end
    if options.checkCost == true and not canAffordPerk(foundPerk) then
        return false, "cost"
    end

    local nextPlayerPerks = copyArray(getPlayerPerks())
    table.insert(nextPlayerPerks, perkID)
    _setPlayerPerks(nextPlayerPerks)
    foundPerk:onAdd()
    return true
end

--- Builds a flat modifier report suitable for AbilitiesAsModifiers.
--- Accepts either a flat map or the common perk rank data shape:
--- { attributes = { strength = 5 }, skills = { longblade = 5 } }.
--- @param data table|nil The modifier data to normalize.
--- @return table|nil A flat modifier map, or nil if there is nothing to report.
local function buildModifierReport(data)
    if data == nil then
        return nil
    end
    if type(data) ~= "table" then
        error("buildModifierReport() requires a table or nil.", 2)
    end

    local report = {}
    for id, val in pairs(data.attributes or {}) do
        report[id] = val
    end
    for id, val in pairs(data.skills or {}) do
        report[id] = val
    end
    for id, val in pairs(data.modifiers or {}) do
        report[id] = val
    end

    if next(report) == nil then
        for id, val in pairs(data) do
            if id ~= "attributes" and id ~= "skills" and id ~= "modifiers" and type(val) == "number" then
                report[id] = val
            end
        end
    end

    if next(report) == nil then
        return nil
    end
    return report
end

--- Reports external stat modifiers into the framework registry.
--- Reports are keyed by sourceName. Passing nil or an empty modifier table clears
--- the source. When AbilitiesAsModifiers is installed the normalized report is
--- also forwarded there for display, but the framework registry remains useful
--- even without AAM.
--- @param sourceName string The label shown by AbilitiesAsModifiers.
--- @param data table|nil Modifier data, or nil to clear this source.
--- @return boolean stored True when the framework accepted the report.
--- @return boolean aamForwarded True when AAM was present and received it.
local function reportExternalModifiers(sourceName, data)
    if type(sourceName) ~= "string" then
        error("reportExternalModifiers() requires a string sourceName.", 2)
    end

    local report = buildModifierReport(data)
    if report == nil then
        externalModifierReports[sourceName] = nil
    else
        externalModifierReports[sourceName] = copyMap(report)
    end

    local aamForwarded = false
    if interfaces.AAM ~= nil then
        interfaces.AAM.reportExternalModifiers(sourceName, report)
        aamForwarded = true
    end
    return true, aamForwarded
end

--- Returns one source's current external modifier report.
--- The returned table is a copy so callers cannot mutate the registry.
--- @param sourceName string Source label used in reportExternalModifiers.
--- @return table|nil report Flat statId -> modifier map, or nil when absent.
local function getExternalModifierReport(sourceName)
    if type(sourceName) ~= "string" then
        error("getExternalModifierReport() requires a string sourceName.", 2)
    end
    local report = externalModifierReports[sourceName]
    if report == nil then
        return nil
    end
    return copyMap(report)
end

--- Returns all current external modifier reports.
--- The returned table and nested reports are copies.
--- @return table reports Source name -> flat statId -> modifier map.
local function getExternalModifierReports()
    local reports = {}
    for sourceName, report in pairs(externalModifierReports) do
        reports[sourceName] = copyMap(report)
    end
    return reports
end

--- Returns every source currently reporting a modifier for one stat.
--- @param statId string Attribute, skill, or other stat id.
--- @return table sources Source name -> modifier value.
local function getExternalModifierSources(statId)
    if type(statId) ~= "string" then
        error("getExternalModifierSources() requires a string statId.", 2)
    end
    local sources = {}
    for sourceName, report in pairs(externalModifierReports) do
        local value = report[statId]
        if type(value) == "number" and value ~= 0 then
            sources[sourceName] = value
        end
    end
    return sources
end

--- Returns the total currently reported external modifier for one stat.
--- This is a registry total only; it does not read OpenMW's live stat object.
--- @param statId string Attribute, skill, or other stat id.
--- @return number total Sum of all reports for this stat.
local function getExternalModifierTotal(statId)
    local total = 0
    for _, value in pairs(getExternalModifierSources(statId)) do
        total = total + value
    end
    return total
end

--- Saves the player's perk state for persistence.
--- @return table The save data table.
local function onSave()
    return {
        version = version,
        playerPerks = playerPerks,
        perkResourceTotals = perkResourceTotals,
    }
end

--- Loads the player's perk state from saved data.
--- Clears existing perks if the version changes.
--- @param data table The loaded save data.
local function onLoad(data)
    if (data == nil) then
        return
    end
    if (not data) or (not data.version) or (data.version ~= version) then
        -- throw all known perks away since version changed.
        return
    end
    _setPlayerPerks(data.playerPerks or {})
    perkResourceTotals = data.perkResourceTotals or {}
    for _, p in ipairs(playerPerks) do
        print("Active Perk: " .. p)
    end
end

return {
    interfaceName = MOD_NAME,
    interface = {
        version = version,
        registerPerk = registerPerk,
        getPerks = getPerks,
        getPerk = getPerk,
        isPerkRegistered = isPerkRegistered,
        getPerkIDs = getPerkIDs,
        requirements = requirements,
        getPlayerPerks = getPlayerPerks,
        getPlayerPerkSet = getPlayerPerkSet,
        playerHasPerk = playerHasPerk,
        getPlayerPerkRevision = getPlayerPerkRevision,
        GENERIC_RESOURCE_ID = GENERIC_RESOURCE_ID,
        registerPerkResource = registerPerkResource,
        getPerkResource = getPerkResource,
        getPerkResources = getPerkResources,
        getPerkCostResource = getPerkCostResource,
        addPerkResource = addPerkResource,
        setPerkResource = setPerkResource,
        availablePoints = availablePoints,
        availablePointsForPerk = availablePointsForPerk,
        canAffordPerk = canAffordPerk,
        grantPerk = grantPerk,
        respecPerks = respecPerks,
        _setPlayerPerks = _setPlayerPerks,
        currentSpentPoints = currentSpentPoints,
        totalAllowedPoints = totalAllowedPoints,
        DEFAULT_ON_HIT_PRIORITY = combat.DEFAULT_ON_HIT_PRIORITY,
        DEFAULT_CALCULATION_PRIORITY = calculation.DEFAULT_CALCULATION_PRIORITY,
        DEFAULT_SKILL_USE_PRIORITY = skill.DEFAULT_SKILL_USE_PRIORITY,
        CALCULATION_OPERATION = calculation.OPERATION,
        CALCULATION = calculation.CALCULATION,
        RESOURCE_OPERATION = calculation.RESOURCE_OPERATION,
        SKILL_USE_SOURCE_TYPE = skill.SKILL_USE_SOURCE_TYPE,
        registerOnHitHandler = combat.registerOnHitHandler,
        unregisterOnHitHandler = combat.unregisterOnHitHandler,
        getOnHitHandlers = combat.getOnHitHandlers,
        registerCalculationHandler = calculation.registerCalculationHandler,
        unregisterCalculationHandler = calculation.unregisterCalculationHandler,
        resolveCalculation = calculation.resolveCalculation,
        applyActorResourceDelta = calculation.applyActorResourceDelta,
        getCalculationHandlers = calculation.getCalculationHandlers,
        registerSkillUseHandler = skill.registerSkillUseHandler,
        unregisterSkillUseHandler = skill.unregisterSkillUseHandler,
        getSkillUseHandlers = skill.getSkillUseHandlers,
        buildModifierReport = buildModifierReport,
        reportExternalModifiers = reportExternalModifiers,
        getExternalModifierReport = getExternalModifierReport,
        getExternalModifierReports = getExternalModifierReports,
        getExternalModifierSources = getExternalModifierSources,
        getExternalModifierTotal = getExternalModifierTotal,
    },
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    }
}
