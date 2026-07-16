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
local interfaces = require('openmw.interfaces')
local log = require("scripts.ErnPerkFramework.log")
local core = require("openmw.core")
local localization = core.l10n(MOD_NAME)
local pself = require("openmw.self")

local sectionName = "perks"
local CATEGORY_UNSORTED = "Unsorted"
local CATEGORY_GENERAL = "General"

local function normalizeCategory(cat)
    if not cat then
        return {
            mod = CATEGORY_UNSORTED,
            type = CATEGORY_GENERAL,
            group = CATEGORY_GENERAL,
            order = 0,
        }
    end

    local modName = cat.mod
    local typeName = cat.type
    local groupName = cat.group
    local order = cat.order

    if modName == nil and typeName == nil and groupName == nil then
        if type(cat[4]) == "number" then
            modName = cat[1]
            typeName = cat[2]
            groupName = cat[3]
            order = cat[4]
        else
            modName = CATEGORY_UNSORTED
            typeName = cat[1]
            groupName = cat[2]
            order = cat[3]
        end
    else
        modName = modName or CATEGORY_UNSORTED
        typeName = typeName or cat[1]
        groupName = groupName or cat[2]
        order = order or cat[3]
    end

    return {
        mod = modName or CATEGORY_UNSORTED,
        type = typeName or CATEGORY_GENERAL,
        group = groupName or CATEGORY_GENERAL,
        order = order or 0,
    }
end

local function categoryKey(cat)
    return tostring(cat.mod) .. "\31" .. tostring(cat.type) .. "\31" .. tostring(cat.group)
end

local function sectionID(prefix, index)
    return MOD_NAME .. "_" .. prefix .. "_" .. tostring(index)
end

local function buildCategorizedPlayerPerks(playerPerkIDs)
    local perks = interfaces.ErnPerkFramework.getPerks()
    local groupsByKey = {}
    local groupOrder = {}

    for _, perkId in ipairs(playerPerkIDs or {}) do
        local perkRecord = perks[perkId]
        if perkRecord then
            local cat = normalizeCategory(perkRecord:category())
            local key = categoryKey(cat)
            if not groupsByKey[key] then
                groupsByKey[key] = {
                    category = cat,
                    perks = {},
                }
                table.insert(groupOrder, groupsByKey[key])
            end
            table.insert(groupsByKey[key].perks, {
                id = perkId,
                record = perkRecord,
                category = cat,
            })
        end
    end

    table.sort(groupOrder, function(a, b)
        local ca = a.category
        local cb = b.category
        if ca.mod ~= cb.mod then return ca.mod < cb.mod end
        if ca.type ~= cb.type then return ca.type < cb.type end
        return ca.group < cb.group
    end)

    local sections = {}
    for _, group in ipairs(groupOrder) do
        table.sort(group.perks, function(a, b)
            if a.category.order ~= b.category.order then
                return a.category.order < b.category.order
            end
            return a.record:name() < b.record:name()
        end)

        table.insert(sections, group)
    end

    return sections
end

local function initStatsWindowIntegration()
    if interfaces.StatsWindow then
        local sc = interfaces.StatsWindow.Constants
        log(nil, "StatsWindow found.")
        interfaces.StatsWindow.trackStat(MOD_NAME, function()
            return interfaces.ErnPerkFramework.getPlayerPerks()
        end)

        local lineBuilder = function(perkInfo)
            local perkRecord = perkInfo.record
            return {
                label = perkRecord:name(),
                tooltip = function()
                    return interfaces.StatsWindow.TooltipBuilders.TEXT({ text = perkRecord:description() })
                end,
                onClick = function()
                    pself:sendEvent(MOD_NAME .. "showPerkUI",
                        { visiblePerks = { perkInfo.id } })
                end,
            }
        end

        local function addCategorySection(parentID, id, header)
            interfaces.StatsWindow.addSectionToSection(id, parentID, {
                header = header,
                indent = true,
                sort = sc.Sort.ADDED_ORDER,
            })
        end

        interfaces.StatsWindow.addSectionToBox(sectionName,
            sc.DefaultBoxes.RIGHT_SCROLL_BOX, {
                l10n = MOD_NAME,
                placement = {
                    type = sc.Placement.AFTER,
                    target = sc.DefaultSections.BIRTHSIGN,
                    priority = 1,
                },
                header = localization(sectionName),
                indent = true,
                sort = sc.Sort.ADDED_ORDER,
                trackedStats = { [MOD_NAME] = true },
                builder = function()
                    local groups = buildCategorizedPlayerPerks(interfaces.StatsWindow.getStat(MOD_NAME))
                    local modSections = {}
                    local typeSections = {}
                    local modCount = 0
                    local typeCount = 0

                    for i, group in ipairs(groups) do
                        local cat = group.category
                        local modKey = tostring(cat.mod)
                        local modID = modSections[modKey]
                        if not modID then
                            modCount = modCount + 1
                            modID = sectionID("mod", modCount)
                            modSections[modKey] = modID
                            addCategorySection(sectionName, modID, cat.mod)
                        end

                        local typeKey = modKey .. "\31" .. tostring(cat.type)
                        local typeID = typeSections[typeKey]
                        if not typeID then
                            typeCount = typeCount + 1
                            typeID = sectionID("type", typeCount)
                            typeSections[typeKey] = typeID
                            addCategorySection(modID, typeID, cat.type)
                        end

                        local groupID = sectionID("group", i)
                        addCategorySection(typeID, groupID, cat.group)

                        for _, perkInfo in ipairs(group.perks) do
                            interfaces.StatsWindow.addLineToSection(perkInfo.id, groupID, lineBuilder(perkInfo))
                        end
                    end
                end,
            })
    else
        log(nil, "StatsWindow not found.")
    end
end



return {
    engineHandlers = {
        onInit = initStatsWindowIntegration,
        onLoad = initStatsWindowIntegration,
    }
}
