--[[
ErnPerkFramework for OpenMW.
Copyright (C) 2025 Erin Pentecost
2026 Robbie Barker

Experimental pannable constellation renderer. The classic perk menu remains
the default and owns no state in this module.
]]

local ambient = require("openmw.ambient")
local async = require("openmw.async")
local core = require("openmw.core")
local input = require("openmw.input")
local interfaces = require("openmw.interfaces")
local self = require("openmw.self")
local ui = require("openmw.ui")
local util = require("openmw.util")
local myui = require("scripts.ErnPerkFramework.pcp.myui")

local MOD_NAME = require("scripts.ErnPerkFramework.settings").MOD_NAME
local localization = core.l10n(MOD_NAME)
local v2 = util.vector2

local HOLD_SECONDS = 0.6
local CELL_WIDTH = 470
local CELL_HEIGHT = 350
local CELL_GAP = 70
local NEBULA_GAP = 200
local NEBULA_PADDING = 46
local NEBULA_TITLE_HEIGHT = 48
local WORLD_MARGIN = 80
local NODE_WIDTH = 30
local AUTO_NODE_GAP = 68
local MIN_AUTO_CELL_WIDTH = 390
local AUTO_LEVEL_GAP = 82
local AUTHORED_MIN_NODE_DISTANCE = 34
local MAX_AUTHORED_SHAPE_SCALE = 1.25
local MIN_ZOOM = 0.40
local MAX_ZOOM = 1.80
local ZOOM_STEP = 1.15
local TOOLTIP_WIDTH = 390
local MAX_TOOLTIP_HEIGHT = 340
local TOOLTIP_SCREEN_MARGIN = 20
local FRAME_THICKNESS = 3
local CONTROLLER_DEADZONE = 0.45
local CONTROLLER_REPEAT_DELAY = 0.34
local CONTROLLER_REPEAT_INTERVAL = 0.11
local CONTROLLER_PAN_SPEED = 460

local COLOR_OWNED = util.color.rgb(0.45, 0.82, 0.45)
local COLOR_AVAILABLE = util.color.rgb(0.92, 0.76, 0.34)
local COLOR_UNAFFORDABLE = util.color.rgb(0.82, 0.42, 0.32)
local COLOR_LOCKED = util.color.rgb(0.45, 0.45, 0.45)
local COLOR_SELECTED = util.color.rgb(0.92, 0.92, 0.84)
local COLOR_PANEL = util.color.rgb(0.025, 0.022, 0.018)
local COLOR_LINE = util.color.rgb(0.50, 0.43, 0.31)
local COLOR_STAR = util.color.rgb(0.62, 0.58, 0.48)
local COLOR_FLAVOUR = util.color.rgb(0.68, 0.63, 0.53)

local horizontalLine = ui.texture { path = "textures/menu_button_frame_top.dds" }
local verticalLine = ui.texture { path = "textures/menu_button_frame_left.dds" }
local transparentTexture = ui.texture { path = "icons/default icon.dds", size = v2(0, 0) }
local whiteTexture = ui.texture { path = "white" }

local menu
local canvasElement
local tabsElement
local hoverElement
local zoomElement
local galaxies = {}
local modNames = {}
local activeMod
local visiblePerks
local dimensions = {}
local panByMod = {}
local zoomByMod = {}
local hoveredPerkId
local lastCursorPosition
local controllerSelectedPerkId
local controllerRepeatState = {}
local controllerButtonState = {}
local hold
local dragging
local refreshDelay
local escapeHeld = false
local refreshHover
local moveHover
local close
local completeHold
local shapeResources = {}

--- Returns dimensions in the same logical coordinate space used by layouts on
--- the requested layer. `ui.screenSize()` reports physical pixels when UI
--- scaling is enabled and must not be used directly for widget placement.
local function layerSize(layerName)
    local index = ui.layers.indexOf(layerName)
    if index then return ui.layers[index].size end
    return ui.screenSize()
end

--- Builds a fixed four-sided frame. The stock thick-box template expands past
--- Widget bounds and loses its right and bottom edges when the parent clips;
--- explicit tiled edges remain entirely inside the requested rectangle.
local function fixedFrame(width, height)
    return {
        type = ui.TYPE.Widget,
        props = { position = v2(0, 0), size = v2(width, height) },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                props = {
                    position = v2(0, 0), size = v2(width, FRAME_THICKNESS),
                    resource = horizontalLine, tileH = true,
                },
            },
            {
                type = ui.TYPE.Image,
                props = {
                    position = v2(0, height - FRAME_THICKNESS),
                    size = v2(width, FRAME_THICKNESS),
                    resource = horizontalLine, tileH = true,
                },
            },
            {
                type = ui.TYPE.Image,
                props = {
                    position = v2(0, 0), size = v2(FRAME_THICKNESS, height),
                    resource = verticalLine, tileV = true,
                },
            },
            {
                type = ui.TYPE.Image,
                props = {
                    position = v2(width - FRAME_THICKNESS, 0),
                    size = v2(FRAME_THICKNESS, height),
                    resource = verticalLine, tileV = true,
                },
            },
        },
    }
end

local function normalizeCategory(category)
    category = category or {}
    local modName = category.mod
    local typeName = category.type
    local groupName = category.group
    local order = category.order
    if modName == nil and typeName == nil and groupName == nil then
        if type(category[4]) == "number" then
            modName, typeName, groupName, order = category[1], category[2], category[3], category[4]
        else
            modName, typeName, groupName, order = "Unsorted", category[1], category[2], category[3]
        end
    end
    return {
        mod = modName or "Unsorted",
        type = typeName or "General",
        group = groupName or "General",
        order = tonumber(order) or 0,
    }
end

local function perkAllowed(id)
    return visiblePerks == nil or visiblePerks[id] == true
end

local function buildGalaxyData()
    galaxies = {}
    modNames = {}
    local groupLookup = {}
    local nebulaLookup = {}

    for _, id in ipairs(interfaces.ErnPerkFramework.getPerkIDs()) do
        local perk = interfaces.ErnPerkFramework.getPerk(id)
        if perk and perkAllowed(id) then
            local category = normalizeCategory(perk:category())
            local galaxy = galaxies[category.mod]
            if not galaxy then
                galaxy = {
                    name = category.mod,
                    nebulae = {},
                    groups = {},
                    positions = {},
                    width = 0,
                    height = 0,
                }
                galaxies[category.mod] = galaxy
                groupLookup[category.mod] = {}
                nebulaLookup[category.mod] = {}
                table.insert(modNames, category.mod)
            end
            local nebula = nebulaLookup[category.mod][category.type]
            if not nebula then
                nebula = { name = category.type, groups = {}, width = 0, height = 0 }
                nebulaLookup[category.mod][category.type] = nebula
                table.insert(galaxy.nebulae, nebula)
            end
            local key = category.type .. "\31" .. category.group
            local group = groupLookup[category.mod][key]
            if not group then
                group = {
                    key = key,
                    type = category.type,
                    name = category.group,
                    perks = {},
                    nebula = nebula,
                    definition = interfaces.ErnPerkFramework.getConstellation(
                        category.mod, category.type, category.group),
                }
                groupLookup[category.mod][key] = group
                table.insert(nebula.groups, group)
                table.insert(galaxy.groups, group)
            end
            table.insert(group.perks, { id = id, perk = perk, order = category.order })
        end
    end

    table.sort(modNames)
    for _, galaxy in pairs(galaxies) do
        table.sort(galaxy.nebulae, function(a, b) return a.name < b.name end)
        galaxy.groups = {}
        for _, nebula in ipairs(galaxy.nebulae) do
            table.sort(nebula.groups, function(a, b) return a.name < b.name end)
            for _, group in ipairs(nebula.groups) do
                table.insert(galaxy.groups, group)
                table.sort(group.perks, function(a, b)
                    if a.order ~= b.order then return a.order < b.order end
                    return a.perk:name() < b.perk:name()
                end)
            end
        end
    end
end

local function dependencyDepth(id, groupIds, cache, visiting)
    if cache[id] ~= nil then return cache[id] end
    if visiting[id] then return 0 end
    visiting[id] = true
    local depth = 0
    local perk = interfaces.ErnPerkFramework.getPerk(id)
    if perk then
        for _, dependencyId in ipairs(perk:dependencies()) do
            if groupIds[dependencyId] then
                depth = math.max(depth, dependencyDepth(dependencyId, groupIds, cache, visiting) + 1)
            end
        end
    end
    visiting[id] = nil
    cache[id] = depth
    return depth
end

local function entryLess(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.perk:name() < b.perk:name()
end

--- Calculates one uniform scale for authored node coordinates. Mod-authored
--- artwork may intentionally place branch points close together, so scaling is
--- capped to keep one dense constellation from expanding the entire galaxy.
--- Near-duplicate points still fall back to generated placement.
local function authoredShapeScale(group)
    local definition = group.definition
    if not definition then return 1, {} end
    local shapeSize = definition.shapeSize or { width = 220, height = 220 }
    local accepted = {}
    local rejected = {}
    local minimum = nil
    local rejectionDistance = AUTHORED_MIN_NODE_DISTANCE / 4

    for _, entry in ipairs(group.perks) do
        local point = definition.positions
            and (definition.positions[entry.id] or definition.positions[entry.order])
        if point then
            local candidate = {
                id = entry.id,
                x = point.x * shapeSize.width,
                y = point.y * shapeSize.height,
            }
            local tooClose = false
            local distances = {}
            for _, other in ipairs(accepted) do
                local dx = candidate.x - other.x
                local dy = candidate.y - other.y
                local distance = math.sqrt(dx * dx + dy * dy)
                if distance < rejectionDistance then
                    tooClose = true
                    break
                end
                table.insert(distances, distance)
            end
            if tooClose then
                rejected[entry.id] = true
            else
                for _, distance in ipairs(distances) do
                    minimum = minimum and math.min(minimum, distance) or distance
                end
                table.insert(accepted, candidate)
            end
        end
    end
    if not minimum or minimum >= AUTHORED_MIN_NODE_DISTANCE then
        return 1, rejected
    end
    return math.min(MAX_AUTHORED_SHAPE_SCALE,
        AUTHORED_MIN_NODE_DISTANCE / minimum), rejected
end

--- Builds a layered graph for one constellation from framework-readable perk
--- dependencies. Authored graph levels remain authoritative; all other levels
--- are inferred from prerequisite depth.
local function prepareGroupLayout(group)
    local groupIds = {}
    for _, entry in ipairs(group.perks) do groupIds[entry.id] = true end

    local depthCache = {}
    local levels = {}
    local entriesByLevel = {}
    for _, entry in ipairs(group.perks) do
        local graph = entry.perk:graph() or {}
        local level = tonumber(graph.level)
        if level == nil then
            level = dependencyDepth(entry.id, groupIds, depthCache, {})
        end
        entry.graph = graph
        entry.level = level
        if not entriesByLevel[level] then
            entriesByLevel[level] = {}
            table.insert(levels, level)
        end
        table.insert(entriesByLevel[level], entry)
    end
    table.sort(levels)
    for _, level in ipairs(levels) do
        table.sort(entriesByLevel[level], entryLess)
    end

    -- A lightweight Sugiyama-style ordering pass keeps children near the
    -- horizontal centre of their parents and reduces avoidable edge crossings.
    local laneRatioById = {}
    for _, level in ipairs(levels) do
        local entries = entriesByLevel[level]
        local parentCentre = {}
        for _, entry in ipairs(entries) do
            local total = 0
            local count = 0
            for _, dependencyId in ipairs(entry.perk:dependencies()) do
                if groupIds[dependencyId] and laneRatioById[dependencyId] then
                    total = total + laneRatioById[dependencyId]
                    count = count + 1
                end
            end
            if count > 0 then parentCentre[entry.id] = total / count end
        end
        table.sort(entries, function(a, b)
            local aCentre = parentCentre[a.id]
            local bCentre = parentCentre[b.id]
            if aCentre ~= nil and bCentre ~= nil and aCentre ~= bCentre then
                return aCentre < bCentre
            end
            if aCentre ~= nil and bCentre == nil then return true end
            if aCentre == nil and bCentre ~= nil then return false end
            return entryLess(a, b)
        end)
        for lane, entry in ipairs(entries) do
            laneRatioById[entry.id] = lane / (#entries + 1)
        end
    end

    local widestLevel = 1
    for _, level in ipairs(levels) do
        widestLevel = math.max(widestLevel, #entriesByLevel[level])
    end
    if group.definition then
        group.shapeScale, group.rejectedPositions = authoredShapeScale(group)
        local shapeSize = group.definition.shapeSize or { width = 220, height = 220 }
        group.width = math.max(CELL_WIDTH, shapeSize.width * group.shapeScale + 160)
        group.height = math.max(CELL_HEIGHT, shapeSize.height * group.shapeScale + 100)
    else
        group.shapeScale = 1
        group.rejectedPositions = {}
        -- Do not cap generated width: unusually broad third-party tiers must
        -- remain navigable rather than silently violating node separation.
        group.width = math.max(MIN_AUTO_CELL_WIDTH, 120 + widestLevel * AUTO_NODE_GAP)
        group.height = math.max(CELL_HEIGHT, 150 + math.max(0, #levels - 1) * AUTO_LEVEL_GAP)
    end
    group.levels = levels
    group.entriesByLevel = entriesByLevel
end

-- Returns the symbol rectangle inside a constellation cell. Mod-provided node
-- coordinates are normalized against this rectangle so their paths trace the
-- supplied emblem instead of the larger layout cell around it.
local function shapeGeometry(definition, group)
    local size = definition and definition.shapeSize or { width = 220, height = 220 }
    local groupWidth = group and group.width or CELL_WIDTH
    local groupHeight = group and group.height or CELL_HEIGHT
    local scale = group and group.shapeScale or 1
    return {
        width = size.width * scale,
        height = size.height * scale,
        left = (groupWidth - size.width * scale) / 2,
        top = 44 + (groupHeight - 74 - size.height * scale) / 2,
    }
end

--- Packs one nebula's constellations into local shelves. Constellations keep
--- their normal cell gap here; the larger buffer is applied later between
--- complete nebula blocks.
local function packNebulaGroups(nebula)
    local aspect = math.max(0.75, dimensions.canvasWidth / math.max(1, dimensions.canvasHeight))
    local totalArea = 0
    local widestGroup = 0
    for _, group in ipairs(nebula.groups) do
        totalArea = totalArea + (group.width + CELL_GAP) * (group.height + CELL_GAP)
        widestGroup = math.max(widestGroup, group.width)
    end
    local targetWidth = math.max(widestGroup,
        dimensions.canvasWidth - WORLD_MARGIN * 2 - NEBULA_PADDING * 2,
        math.sqrt(totalArea * aspect))

    local x = NEBULA_PADDING
    local y = NEBULA_PADDING + NEBULA_TITLE_HEIGHT
    local rowHeight = 0
    local right = NEBULA_PADDING
    for _, group in ipairs(nebula.groups) do
        if x > NEBULA_PADDING and x + group.width > NEBULA_PADDING + targetWidth then
            x = NEBULA_PADDING
            y = y + rowHeight + CELL_GAP
            rowHeight = 0
        end
        group.nebulaOrigin = v2(x, y)
        x = x + group.width + CELL_GAP
        rowHeight = math.max(rowHeight, group.height)
        right = math.max(right, group.nebulaOrigin.x + group.width)
    end
    nebula.width = right + NEBULA_PADDING
    nebula.height = y + rowHeight + NEBULA_PADDING
end

--- Packs named nebula blocks into the pannable galaxy. The deliberately large
--- gap makes mod sections read as distinct regions while allowing an addon to
--- add dependency links between constellations in different nebulae.
local function packGalaxyNebulae(galaxy)
    local aspect = math.max(0.75, dimensions.canvasWidth / math.max(1, dimensions.canvasHeight))
    local totalArea = 0
    local widestNebula = 0
    for _, nebula in ipairs(galaxy.nebulae) do
        packNebulaGroups(nebula)
        totalArea = totalArea + (nebula.width + NEBULA_GAP) * (nebula.height + NEBULA_GAP)
        widestNebula = math.max(widestNebula, nebula.width)
    end
    local targetWidth = math.max(widestNebula,
        dimensions.canvasWidth - WORLD_MARGIN * 2,
        math.sqrt(totalArea * aspect))

    local x = WORLD_MARGIN
    local y = WORLD_MARGIN
    local rowHeight = 0
    local right = WORLD_MARGIN
    for _, nebula in ipairs(galaxy.nebulae) do
        if x > WORLD_MARGIN and x + nebula.width > WORLD_MARGIN + targetWidth then
            x = WORLD_MARGIN
            y = y + rowHeight + NEBULA_GAP
            rowHeight = 0
        end
        nebula.origin = v2(x, y)
        for _, group in ipairs(nebula.groups) do
            group.origin = nebula.origin + group.nebulaOrigin
        end
        x = x + nebula.width + NEBULA_GAP
        rowHeight = math.max(rowHeight, nebula.height)
        right = math.max(right, nebula.origin.x + nebula.width)
    end
    galaxy.width = math.max(dimensions.canvasWidth, right + WORLD_MARGIN)
    galaxy.height = math.max(dimensions.canvasHeight, y + rowHeight + WORLD_MARGIN)
end

local function layoutGalaxy(galaxy)
    galaxy.positions = {}
    for _, group in ipairs(galaxy.groups) do prepareGroupLayout(group) end
    packGalaxyNebulae(galaxy)

    for _, group in ipairs(galaxy.groups) do
        for levelIndex, level in ipairs(group.levels) do
            local entries = group.entriesByLevel[level]
            local y
            if #group.levels == 1 then
                y = group.origin.y + group.height * 0.55
            else
                y = group.origin.y + group.height - 56
                    - ((levelIndex - 1) / (#group.levels - 1)) * (group.height - 122)
            end
            for lane, entry in ipairs(entries) do
                local entryY = y
                local x = group.origin.x + 46 + lane * ((group.width - 92) / (#entries + 1))
                local registeredPosition = group.definition and group.definition.positions
                    and (group.definition.positions[entry.id] or group.definition.positions[entry.order])
                if group.rejectedPositions[entry.id] then registeredPosition = nil end
                if type(entry.graph.x) == "number" then
                    x = group.origin.x + entry.graph.x * group.width
                elseif registeredPosition then
                    local shape = shapeGeometry(group.definition, group)
                    x = group.origin.x + shape.left + registeredPosition.x * shape.width
                end
                if type(entry.graph.y) == "number" then
                    entryY = group.origin.y + entry.graph.y * group.height
                elseif registeredPosition then
                    local shape = shapeGeometry(group.definition, group)
                    entryY = group.origin.y + shape.top + registeredPosition.y * shape.height
                end
                galaxy.positions[entry.id] = v2(x, entryY)
            end
        end
    end
end

local function activeGalaxy()
    return activeMod and galaxies[activeMod] or nil
end

local function currentZoom()
    return zoomByMod[activeMod] or 1
end

local function worldToCanvas(point, pan, zoom)
    return point * zoom + pan
end

local function clampPan(galaxy, pan)
    if not galaxy then return v2(0, 0) end
    local zoom = currentZoom()
    local galaxyWidth = galaxy.width * zoom
    local galaxyHeight = galaxy.height * zoom
    local x
    local y
    if galaxyWidth <= dimensions.canvasWidth then
        x = (dimensions.canvasWidth - galaxyWidth) / 2
    else
        x = util.clamp(pan.x, dimensions.canvasWidth - galaxyWidth, 0)
    end
    if galaxyHeight <= dimensions.canvasHeight then
        y = (dimensions.canvasHeight - galaxyHeight) / 2
    else
        y = util.clamp(pan.y, dimensions.canvasHeight - galaxyHeight, 0)
    end
    return v2(x, y)
end

local function currentPan()
    local galaxy = activeGalaxy()
    local pan = panByMod[activeMod] or v2(0, 0)
    pan = clampPan(galaxy, pan)
    panByMod[activeMod] = pan
    return pan
end

local function pointVisible(point, margin)
    margin = margin or 0
    return point.x >= -margin and point.y >= -margin
        and point.x <= dimensions.canvasWidth + margin
        and point.y <= dimensions.canvasHeight + margin
end

local function nodeState(perk)
    if perk:active() then return "owned", COLOR_OWNED end
    local requirements = perk:evaluateRequirements().satisfied
    if not requirements then return "locked", COLOR_LOCKED end
    if not interfaces.ErnPerkFramework.canAffordPerk(perk) then
        return "unaffordable", COLOR_UNAFFORDABLE
    end
    return "available", COLOR_AVAILABLE
end

--- Applies only the explicit external-acquisition visibility rule. Ordinary
--- `hidden` predicates are intentionally ignored in constellation mode.
local function nodeVisible(perk)
    return not perk:constellationHidden()
end

-- A mutually exclusive branch counts as resolved once its alternative is
-- owned. Descendants of that blocked branch are exempt as well.
local function blockedByOwnedChoice(perk, groupIds, visiting)
    if perk:active() then return false end
    visiting = visiting or {}
    if visiting[perk:id()] then return false end
    visiting[perk:id()] = true
    for _, excludedId in ipairs(perk:mutuallyExclusiveWith()) do
        if interfaces.ErnPerkFramework.playerHasPerk(excludedId) then
            visiting[perk:id()] = nil
            return true
        end
    end
    for _, dependencyId in ipairs(perk:dependencies()) do
        if groupIds[dependencyId] and not interfaces.ErnPerkFramework.playerHasPerk(dependencyId) then
            local dependency = interfaces.ErnPerkFramework.getPerk(dependencyId)
            if dependency and blockedByOwnedChoice(dependency, groupIds, visiting) then
                visiting[perk:id()] = nil
                return true
            end
        end
    end
    visiting[perk:id()] = nil
    return false
end

--- Determines whether a symbol should remain fully lit. Every real route must
--- be owned; routes made impossible by an owned mutual choice are exempt.
local function groupComplete(group)
    local revision = interfaces.ErnPerkFramework.getPlayerPerkRevision()
    if group.completionRevision == revision then
        return group.completionResult
    end
    if #group.perks == 0 then return false end
    local groupIds = {}
    for _, entry in ipairs(group.perks) do groupIds[entry.id] = true end
    for _, entry in ipairs(group.perks) do
        if not entry.perk:active() and not blockedByOwnedChoice(entry.perk, groupIds, {}) then
            group.completionRevision = revision
            group.completionResult = false
            return false
        end
    end
    group.completionRevision = revision
    group.completionResult = true
    return true
end

--- Lazily atlases a mod-provided symbol once per texture path. Reusing the
--- resource avoids rebuilding texture registrations on every pan redraw.
local function shapeResource(path)
    if not path then return nil end
    if not shapeResources[path] then
        shapeResources[path] = ui.texture { path = path }
    end
    return shapeResources[path]
end

--- Adds one point of a constellation wireframe. Completed symbols use denser,
--- brighter points; incomplete outlines remain faint background guidance.
local function addWireframeDot(content, point, complete)
    if not pointVisible(point, 4) then return end
    local size = complete and 4 or 2
    content:add {
        type = ui.TYPE.Image,
        props = {
            position = point - v2(size / 2, size / 2),
            size = v2(size, size),
            resource = whiteTexture,
            color = complete and COLOR_AVAILABLE or COLOR_LINE,
            alpha = complete and 0.92 or 0.13,
        },
    }
end

--- Rasterizes a normalized straight segment as a sequence of star-like points.
--- This avoids rotated bitmap dependencies and retains clean diagonal shapes.
local function addWireframeSegment(content, from, to, complete)
    local delta = to - from
    local length = math.sqrt(delta.x * delta.x + delta.y * delta.y)
    local spacing = complete and 7 or 14
    local steps = math.max(1, math.ceil(length / spacing))
    for step = 0, steps do
        addWireframeDot(content, from + delta * (step / steps), complete)
    end
end

--- Renders every mod-owned normalized path inside the symbol rectangle.
local function addWireframe(content, group, pan, zoom, complete)
    local definition = group.definition
    local shape = shapeGeometry(definition, group)
    local origin = worldToCanvas(group.origin + v2(shape.left, shape.top), pan, zoom)
    for _, path in ipairs(definition.wireframe or {}) do
        for index = 2, #path do
            local previous = path[index - 1]
            local current = path[index]
            addWireframeSegment(content,
                origin + v2(previous.x * shape.width * zoom, previous.y * shape.height * zoom),
                origin + v2(current.x * shape.width * zoom, current.y * shape.height * zoom),
                complete)
        end
    end
end

local function addSegment(content, a, b, color)
    if a.x == b.x then
        if a.x < 0 or a.x > dimensions.canvasWidth then return end
        local top = math.min(a.y, b.y)
        local bottom = math.max(a.y, b.y)
        top = math.max(0, top)
        bottom = math.min(dimensions.canvasHeight, bottom)
        if bottom <= top then return end
        local height = math.max(2, bottom - top)
        content:add {
            type = ui.TYPE.Image,
            props = {
                position = v2(a.x - 1, top), size = v2(2, height),
                resource = verticalLine, tileV = true, color = color, alpha = 0.82,
            },
        }
    else
        if a.y < 0 or a.y > dimensions.canvasHeight then return end
        local left = math.min(a.x, b.x)
        local right = math.max(a.x, b.x)
        left = math.max(0, left)
        right = math.min(dimensions.canvasWidth, right)
        if right <= left then return end
        local width = math.max(2, right - left)
        content:add {
            type = ui.TYPE.Image,
            props = {
                position = v2(left, a.y - 1), size = v2(width, 2),
                resource = horizontalLine, tileH = true, color = color, alpha = 0.82,
            },
        }
    end
end

local function addConnection(content, from, to, color)
    if not pointVisible(from, 100) and not pointVisible(to, 100) then return end
    local middleY = (from.y + to.y) / 2
    addSegment(content, from, v2(from.x, middleY), color)
    addSegment(content, v2(from.x, middleY), v2(to.x, middleY), color)
    addSegment(content, v2(to.x, middleY), to, color)
end

--- Converts a validated registration colour into the UI colour type only when
--- it is rendered. Keeping plain numeric tables in the manifest makes the
--- public constellation metadata easy for perk mods to construct.
local function registeredColor(color)
    return util.color.rgb(color.r, color.g, color.b)
end

--- Adds a bright point over an authored texture without replacing its own
--- star shape. The broad, translucent square supplies glow while the compact
--- centre makes an acquired node remain legible at low zoom.
local function addOwnedStar(content, point, color, zoom)
    if not pointVisible(point, 20) then return end
    local glowSize = util.clamp(16 * zoom, 8, 22)
    local coreSize = util.clamp(5 * zoom, 3, 7)
    content:add {
        type = ui.TYPE.Image,
        props = {
            position = point - v2(glowSize / 2, glowSize / 2),
            size = v2(glowSize, glowSize),
            resource = whiteTexture,
            color = color,
            alpha = 0.16,
        },
    }
    content:add {
        type = ui.TYPE.Image,
        props = {
            position = point - v2(coreSize / 2, coreSize / 2),
            size = v2(coreSize, coreSize),
            resource = whiteTexture,
            color = color,
            alpha = 0.92,
        },
    }
end

--- Traces a lit, straight constellation segment between two owned stars. The
--- authored texture beneath it supplies the soft continuous glow; close-set
--- points provide the brighter acquired-state highlight without rotated UI
--- textures or mod-specific rendering code.
local function addOwnedLink(content, from, to, color, zoom)
    if not pointVisible(from, 80) and not pointVisible(to, 80) then return end
    local delta = to - from
    local length = math.sqrt(delta.x * delta.x + delta.y * delta.y)
    local spacing = util.clamp(5 * zoom, 3, 7)
    local steps = math.max(1, math.ceil(length / spacing))
    local size = util.clamp(3 * zoom, 2, 5)
    for step = 0, steps do
        local point = from + delta * (step / steps)
        if pointVisible(point, size) then
            content:add {
                type = ui.TYPE.Image,
                props = {
                    position = point - v2(size / 2, size / 2),
                    size = v2(size, size),
                    resource = whiteTexture,
                    color = color,
                    alpha = 0.86,
                },
            }
        end
    end
end

local function cancelHold()
    hold = nil
end

--- Measures holds against real time so UI capture and uneven frame callbacks
--- cannot leave pointer actions permanently at zero percent.
local function updateHoldElapsed()
    if not hold or not hold.startedAt then return end
    hold.elapsed = math.max(0, core.getRealTime() - hold.startedAt)
end

local function setHovered(perkId)
    hoveredPerkId = perkId
    if refreshHover then refreshHover() end
end

local function nodeLayout(entry, position, zoom)
    local state, color = nodeState(entry.perk)
    local sizeOffset = state == "available" and 6 or (state == "locked" and -4 or 0)
    local nodeSize = util.clamp(NODE_WIDTH * zoom + sizeOffset, 18, 48)
    local selected = controllerSelectedPerkId == entry.id
    local marker = state == "owned" and "O"
        or (state == "available" and "*"
        or (state == "unaffordable" and "!" or "."))
    local nodeContent = ui.content {}

    -- Shape, scale, and fill reinforce the colour coding. This keeps state
    -- readable for colour-blind players and when a distant galaxy is zoomed out.
    if state == "owned" then
        nodeContent:add {
            type = ui.TYPE.Image,
            props = {
                position = v2(6, 6), size = v2(nodeSize - 12, nodeSize - 12),
                resource = whiteTexture, color = COLOR_OWNED, alpha = 0.28,
            },
        }
    elseif state == "available" then
        for _, edge in ipairs({
            { position = v2(1, 1), size = v2(nodeSize - 2, 2) },
            { position = v2(1, nodeSize - 3), size = v2(nodeSize - 2, 2) },
            { position = v2(1, 1), size = v2(2, nodeSize - 2) },
            { position = v2(nodeSize - 3, 1), size = v2(2, nodeSize - 2) },
        }) do
            nodeContent:add {
                type = ui.TYPE.Image,
                props = {
                    position = edge.position, size = edge.size,
                    resource = whiteTexture, color = COLOR_AVAILABLE, alpha = 0.72,
                },
            }
        end
    end
    nodeContent:add {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            position = v2(0, math.max(1, (nodeSize - 18) / 2)),
            size = v2(nodeSize, 18),
            textAlignH = ui.ALIGNMENT.Center,
            text = marker,
            textColor = color,
        },
    }
    nodeContent:add {
        type = ui.TYPE.Image,
        props = {
            size = v2(nodeSize, nodeSize),
            alpha = 0,
            resource = transparentTexture,
        },
    }
    if selected then
        for _, corner in ipairs({
            v2(2, 2), v2(nodeSize - 5, 2),
            v2(2, nodeSize - 5), v2(nodeSize - 5, nodeSize - 5),
        }) do
            nodeContent:add {
                type = ui.TYPE.Image,
                props = {
                    position = corner,
                    size = v2(3, 3),
                    resource = whiteTexture,
                    color = COLOR_SELECTED,
                },
            }
        end
    end
    return {
        name = "node_" .. entry.id,
        type = ui.TYPE.Container,
        template = state ~= "locked" and myui.templates.boxButton or nil,
        props = {
            position = position - v2(nodeSize / 2, nodeSize / 2),
            size = v2(nodeSize, nodeSize),
        },
        userData = { perkId = entry.id },
        content = nodeContent,
        events = {
            focusGain = async:callback(function()
                setHovered(entry.id)
            end),
            focusLoss = async:callback(function()
                -- Rebuilding the independent tooltip can briefly change UI
                -- focus. Preserve an active pointer hold across that transition.
                if not hold or hold.perkId ~= entry.id then
                    if hoveredPerkId == entry.id then setHovered(nil) end
                end
            end),
            mousePress = async:callback(function(event)
                if event.button ~= 1 and event.button ~= 3 then return false end
                if event.button == 1 and state ~= "available" then return false end
                if event.button == 3 and state ~= "owned" then return false end
                -- UI mouse events are the authority for pointer holds. Polling
                -- the raw right-button state after UI capture is unreliable on
                -- some OpenMW input configurations and left refunds at 0%.
                hold = {
                    perkId = entry.id,
                    button = event.button,
                    source = "mouse",
                    startedAt = core.getRealTime(),
                    elapsed = 0,
                }
                ambient.playSound("Menu Click")
                refreshHover()
                return false
            end),
            mouseRelease = async:callback(function(event)
                if hold and hold.perkId == entry.id and hold.button == event.button then
                    updateHoldElapsed()
                    if hold.elapsed >= HOLD_SECONDS then
                        completeHold()
                    else
                        cancelHold()
                        refreshHover()
                    end
                end
                return false
            end),
            mouseMove = async:callback(function(event)
                if controllerSelectedPerkId then
                    controllerSelectedPerkId = nil
                    refreshDelay = 0.01
                end
                lastCursorPosition = event.position
                if hoveredPerkId == entry.id and moveHover then moveHover(event.position) end
            end),
        },
    }
end

--- Builds a stationary key beneath the galaxy viewport. The symbols match the
--- node markers, so state remains understandable without relying on colour.
local function stateLegendLayout()
    local items = {
        { marker = "O", key = "constellationLegendOwned", color = COLOR_OWNED },
        { marker = "*", key = "constellationLegendAvailable", color = COLOR_AVAILABLE },
        { marker = "!", key = "constellationLegendUnaffordable", color = COLOR_UNAFFORDABLE },
        { marker = ".", key = "constellationLegendLocked", color = COLOR_LOCKED },
    }
    local content = ui.content {}
    local itemWidth = dimensions.canvasWidth / #items
    for index, item in ipairs(items) do
        content:add {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                position = v2((index - 1) * itemWidth, 2), size = v2(itemWidth, 18),
                textAlignH = ui.ALIGNMENT.Center,
                text = item.marker .. "  " .. localization(item.key, {}),
                textColor = item.color,
            },
        }
    end
    return {
        type = ui.TYPE.Widget,
        props = { size = v2(dimensions.canvasWidth, 22) },
        content = content,
    }
end

local function buildCanvasContent()
    local content = ui.content {}
    local galaxy = activeGalaxy()
    if not galaxy then return content end
    local pan = currentPan()
    local zoom = currentZoom()

    -- Sparse deterministic stars give the canvas depth without requiring a
    -- mod-specific background texture.
    for x = 35, galaxy.width, 137 do
        local y = 25 + ((x * 37) % math.max(60, galaxy.height - 40))
        local point = worldToCanvas(v2(x, y), pan, zoom)
        if pointVisible(point, 10) then
            content:add {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textNormal,
                props = { position = point, text = ".", textColor = COLOR_STAR, alpha = 0.55 },
            }
        end
    end

    -- Category `type` is the nebula layer between a mod galaxy and its
    -- constellations. Its heading occupies the reserved top band inside the
    -- block; the larger empty margin around the block supplies visual grouping
    -- without enclosing every section in another panel.
    for _, nebula in ipairs(galaxy.nebulae) do
        local titlePosition = worldToCanvas(
            nebula.origin + v2(nebula.width / 2, NEBULA_PADDING / 2), pan, zoom)
        if pointVisible(titlePosition, 220) then
            content:add {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textHeader,
                props = {
                    position = titlePosition - v2(210, 0),
                    size = v2(420, 28),
                    textAlignH = ui.ALIGNMENT.Center,
                    text = nebula.name,
                    textColor = COLOR_AVAILABLE,
                },
            }
        end
    end

    for _, group in ipairs(galaxy.groups) do
        local complete = groupComplete(group)
        local definition = group.definition
        local texturePath = definition and complete and definition.completedTexture
            or (definition and definition.texture)
        if texturePath then
            local shape = shapeGeometry(definition, group)
            local position = worldToCanvas(group.origin + v2(shape.left, shape.top), pan, zoom)
            local scaledWidth = shape.width * zoom
            local scaledHeight = shape.height * zoom
            if pointVisible(position + v2(scaledWidth / 2, scaledHeight / 2), scaledWidth) then
                content:add {
                    type = ui.TYPE.Image,
                    props = {
                        position = position,
                        size = v2(scaledWidth, scaledHeight),
                        resource = shapeResource(texturePath),
                        -- A dedicated completed texture carries its authored
                        -- glow at full strength. Older registrations retain
                        -- the original opacity-based completion treatment.
                        alpha = complete and (definition.completedTexture and 1 or 0.96) or 0.55,
                    },
                }
            end
        elseif definition and #definition.wireframe > 0 then
            -- Coordinate wireframes remain a no-asset fallback for third-party
            -- packs and for constellations whose final artwork is unavailable.
            addWireframe(content, group, pan, zoom, complete)
        end
        local titlePosition = worldToCanvas(group.origin + v2(group.width / 2, 8), pan, zoom)
        if zoom >= 0.68 and pointVisible(titlePosition, 180) then
            content:add {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textHeader,
                props = {
                    position = titlePosition - v2(170, 0), size = v2(340, 24),
                    textAlignH = ui.ALIGNMENT.Center,
                    text = group.name,
                    textColor = complete and COLOR_AVAILABLE or myui.textColors.header,
                },
            }
        end
    end

    -- Mod-authored ownership overlays can follow curves or symbols embedded in
    -- a texture without forcing those decorative paths into perk requirements.
    -- A link illuminates only after both of its endpoint perks are owned.
    for _, group in ipairs(galaxy.groups) do
        local definition = group.definition
        local usingCompletedTexture = definition and definition.completedTexture
            and groupComplete(group)
        if definition and not usingCompletedTexture then
            for _, link in ipairs(definition.ownedLinks or {}) do
                local from = galaxy.positions[link.from]
                local to = galaxy.positions[link.to]
                if from and to
                    and interfaces.ErnPerkFramework.playerHasPerk(link.from)
                    and interfaces.ErnPerkFramework.playerHasPerk(link.to) then
                    addOwnedLink(content,
                        worldToCanvas(from, pan, zoom),
                        worldToCanvas(to, pan, zoom),
                        registeredColor(link.color), zoom)
                end
            end
            for perkId, color in pairs(definition.ownedNodeColors or {}) do
                local point = galaxy.positions[perkId]
                if point and interfaces.ErnPerkFramework.playerHasPerk(perkId) then
                    addOwnedStar(content, worldToCanvas(point, pan, zoom),
                        registeredColor(color), zoom)
                end
            end
        end
    end

    -- Connections are added before nodes so nodes remain readable on top.
    for _, group in ipairs(galaxy.groups) do
        local groupIds = {}
        for _, entry in ipairs(group.perks) do groupIds[entry.id] = true end
        local suppressInternal = group.definition
            and group.definition.suppressInternalDependencyLines
        for _, entry in ipairs(group.perks) do
            local toWorld = galaxy.positions[entry.id]
            if toWorld and nodeVisible(entry.perk) then
                local _, color = nodeState(entry.perk)
                for _, dependencyId in ipairs(entry.perk:dependencies()) do
                    local fromWorld = galaxy.positions[dependencyId]
                    local dependency = interfaces.ErnPerkFramework.getPerk(dependencyId)
                    -- Authored constellations can replace their internal graph
                    -- lines while preserving links added by another mod between
                    -- separate skills, factions, or perk packs.
                    local suppressed = suppressInternal and groupIds[dependencyId]
                    if not suppressed and fromWorld and dependency and nodeVisible(dependency) then
                        addConnection(content,
                            worldToCanvas(fromWorld, pan, zoom),
                            worldToCanvas(toWorld, pan, zoom),
                            color or COLOR_LINE)
                    end
                end
            end
        end
    end

    for _, group in ipairs(galaxy.groups) do
        for _, entry in ipairs(group.perks) do
            local point = worldToCanvas(galaxy.positions[entry.id], pan, zoom)
            if nodeVisible(entry.perk) and pointVisible(point, NODE_WIDTH * zoom) then
                content:add(nodeLayout(entry, point, zoom))
            end
        end
    end
    return content
end

local function holdPercent()
    if not hold then return 0 end
    updateHoldElapsed()
    return math.min(1, hold.elapsed / HOLD_SECONDS)
end

--- Positions the independent perk tooltip beside the cursor, flipping it to
--- the opposite side whenever the preferred placement would leave the screen.
local function tooltipPosition(cursor)
    local screen = layerSize("Notification")
    local width = dimensions.tooltipWidth
    local height = dimensions.tooltipHeight
    local x = cursor.x + 18
    local y = cursor.y + 18
    if x + width > screen.x - TOOLTIP_SCREEN_MARGIN then x = cursor.x - width - 18 end
    if y + height > screen.y - TOOLTIP_SCREEN_MARGIN then y = cursor.y - height - 18 end
    return v2(
        util.clamp(x, TOOLTIP_SCREEN_MARGIN,
            math.max(TOOLTIP_SCREEN_MARGIN, screen.x - width - TOOLTIP_SCREEN_MARGIN)),
        util.clamp(y, TOOLTIP_SCREEN_MARGIN,
            math.max(TOOLTIP_SCREEN_MARGIN, screen.y - height - TOOLTIP_SCREEN_MARGIN)))
end

--- Recalculates tooltip limits from the current logical screen dimensions.
--- This runs on every rebuild so resolution or UI-scale changes cannot leave
--- an old panel size extending beyond the viewport.
local function constrainTooltipDimensions()
    local screen = layerSize("Notification")
    dimensions.tooltipWidth = math.max(1,
        math.min(TOOLTIP_WIDTH, screen.x - TOOLTIP_SCREEN_MARGIN * 2))
    dimensions.tooltipMaxHeight = math.max(1,
        math.min(MAX_TOOLTIP_HEIGHT, screen.y - TOOLTIP_SCREEN_MARGIN * 2))
    dimensions.tooltipHeight = math.min(
        dimensions.tooltipHeight or dimensions.tooltipMaxHeight,
        dimensions.tooltipMaxHeight)
end

--- Estimates the vertical space required by wrapped text. OpenMW does not
--- expose text measurement here, so this deliberately uses a conservative
--- character width and honours explicit line breaks in perk descriptions.
local function wrappedLineCount(value, charsPerLine, maximum)
    local text = tostring(value or "")
    if text == "" then return 0 end
    local count = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        count = count + math.max(1, math.ceil(#line / charsPerLine))
    end
    return math.min(maximum, count)
end

moveHover = function(cursor)
    lastCursorPosition = cursor
    if not hoverElement then return end
    hoverElement.layout.props.position = tooltipPosition(cursor)
    hoverElement:update()
end

--- Builds a compact floating information window for the currently hovered
--- perk. Its height follows the wrapped content while remaining independent
--- from the fixed galaxy viewport.
local function buildHoverLayout()
    local perk = hoveredPerkId and interfaces.ErnPerkFramework.getPerk(hoveredPerkId) or nil
    if not perk or not lastCursorPosition then return nil end
    constrainTooltipDimensions()
    local tooltipShade = {
        type = ui.TYPE.Image,
        props = {
            position = v2(0, 0), size = v2(dimensions.tooltipWidth, dimensions.tooltipMaxHeight),
            resource = whiteTexture, color = COLOR_PANEL, alpha = 0.78,
        },
    }
    local content = ui.content { tooltipShade }
    local state = nodeState(perk)
    local resourceId = interfaces.ErnPerkFramework.getPerkCostResource(perk)
    local resource = interfaces.ErnPerkFramework.getPerkResource(resourceId)
    local costName = perk:cost() == 1 and resource.name or resource.pluralName
    local statusText = localization("constellationStatus_" .. state, {})
    if hold and hold.perkId == perk:id() then
        local action = hold.button == 1 and localization("constellationAcquiring", {})
            or localization("constellationRefunding", {})
        statusText = action .. " " .. tostring(math.floor(holdPercent() * 100)) .. "%"
    end

    local flavour = perk:flavour() or ""
    local effectText = "Effects\n" .. perk:description():gsub("\f", "\n")
    local costText = "Cost: " .. tostring(perk:cost()) .. " " .. costName .. "    " .. statusText
    local innerWidth = dimensions.tooltipWidth - 24
    local charsPerLine = math.max(24, math.floor(innerWidth / 7))
    local flavourHeight = wrappedLineCount(flavour, charsPerLine, 5) * 16
    local effectHeight = math.max(32, wrappedLineCount(effectText, charsPerLine, 10) * 16)
    local costHeight = math.max(20, wrappedLineCount(costText, charsPerLine, 2) * 16)
    local desiredHeight = 38 + (flavourHeight > 0 and flavourHeight + 8 or 0)
        + effectHeight + 8 + costHeight + 12
    local overflow = math.max(0, desiredHeight - dimensions.tooltipMaxHeight)
    local effectReduction = math.min(overflow, effectHeight - 32)
    effectHeight = effectHeight - effectReduction
    overflow = overflow - effectReduction
    if flavourHeight > 0 and overflow > 0 then
        flavourHeight = math.max(16, flavourHeight - overflow)
    end
    local cursorY = 38

    content:add {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textHeader,
        props = {
            position = v2(12, 10), size = v2(dimensions.tooltipWidth - 24, 22),
            autoSize = false, wordWrap = true, text = perk:name(),
        },
    }
    if flavourHeight > 0 then
        content:add {
            type = ui.TYPE.Text,
            template = interfaces.MWUI.templates.textNormal,
            props = {
                position = v2(12, cursorY), size = v2(innerWidth, flavourHeight),
                autoSize = false, wordWrap = true,
                textColor = COLOR_FLAVOUR,
                text = flavour,
            },
        }
        cursorY = cursorY + flavourHeight + 8
    end
    content:add {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            position = v2(12, cursorY), size = v2(innerWidth, effectHeight),
            autoSize = false, wordWrap = true,
            text = effectText,
        },
    }
    cursorY = cursorY + effectHeight + 8
    content:add {
        type = ui.TYPE.Text,
        template = interfaces.MWUI.templates.textNormal,
        props = {
            position = v2(12, cursorY), size = v2(innerWidth, costHeight),
            autoSize = false, wordWrap = true,
            text = costText,
        },
    }
    cursorY = cursorY + costHeight
    dimensions.tooltipHeight = math.min(dimensions.tooltipMaxHeight, cursorY + 12)
    tooltipShade.props.size = v2(dimensions.tooltipWidth, dimensions.tooltipHeight)
    content:add(fixedFrame(dimensions.tooltipWidth, dimensions.tooltipHeight))
    if hold and hold.perkId == perk:id() then
        content:add {
            type = ui.TYPE.Image,
            props = {
                position = v2(12, dimensions.tooltipHeight - 9),
                size = v2((dimensions.tooltipWidth - 24) * holdPercent(), 3),
                resource = horizontalLine,
                tileH = true,
                color = hold.button == 1 and COLOR_AVAILABLE or COLOR_OWNED,
            },
        }
    end
    return {
        name = "constellationPerkTooltip",
        layer = "Notification",
        type = ui.TYPE.Widget,
        props = {
            position = tooltipPosition(lastCursorPosition),
            size = v2(dimensions.tooltipWidth, dimensions.tooltipHeight),
        },
        content = content,
    }
end

refreshHover = function()
    local layout = buildHoverLayout()
    if not layout then
        if hoverElement then
            hoverElement:destroy()
            hoverElement = nil
        end
        return
    end
    if hoverElement then
        hoverElement.layout = layout
        hoverElement:update()
    else
        hoverElement = ui.create(layout)
    end
end

local function refreshCanvas()
    if not canvasElement then return end
    canvasElement.layout.content = buildCanvasContent()
    canvasElement:update()
    refreshHover()
end

local function canvasScreenOrigin()
    local screen = layerSize("Windows")
    return v2(
        (screen.x - dimensions.width) / 2 + 12,
        (screen.y - dimensions.height) / 2 + 44)
end

local refreshZoom

--- Changes zoom around a canvas point so the world location beneath the
--- cursor remains stationary. Button-driven zoom defaults to canvas centre.
local function setZoom(value, absoluteAnchor)
    local galaxy = activeGalaxy()
    if not galaxy then return end
    local oldZoom = currentZoom()
    local newZoom = util.clamp(value, MIN_ZOOM, MAX_ZOOM)
    if math.abs(newZoom - oldZoom) < 0.0001 then return end

    local anchor = v2(dimensions.canvasWidth / 2, dimensions.canvasHeight / 2)
    if absoluteAnchor then anchor = absoluteAnchor - canvasScreenOrigin() end
    local oldPan = currentPan()
    local world = v2(
        (anchor.x - oldPan.x) / oldZoom,
        (anchor.y - oldPan.y) / oldZoom)
    zoomByMod[activeMod] = newZoom
    panByMod[activeMod] = clampPan(galaxy, anchor - world * newZoom)
    refreshCanvas()
    if refreshZoom then refreshZoom() end
end

local function zoomButton(label, x, callback)
    return {
        type = ui.TYPE.Container,
        template = myui.templates.boxButton,
        props = { position = v2(x, 0), size = v2(28, 28) },
        content = ui.content {
            {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textNormal,
                props = { position = v2(0, 5), size = v2(28, 18), textAlignH = ui.ALIGNMENT.Center, text = label },
            },
            { type = ui.TYPE.Image, props = { size = v2(28, 28), alpha = 0, resource = transparentTexture } },
        },
        events = {
            mouseRelease = async:callback(function(event)
                if event.button == 1 then callback() end
            end),
        },
    }
end

local function buildZoomLayout()
    local percent = tostring(math.floor(currentZoom() * 100 + 0.5)) .. "%"
    return {
        type = ui.TYPE.Widget,
        props = { size = v2(116, 28) },
        content = ui.content {
            zoomButton("-", 0, function() setZoom(currentZoom() / ZOOM_STEP) end),
            {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textNormal,
                props = { position = v2(30, 5), size = v2(54, 18), textAlignH = ui.ALIGNMENT.Center, text = percent },
            },
            zoomButton("+", 86, function() setZoom(currentZoom() * ZOOM_STEP) end),
        },
    }
end

refreshZoom = function()
    if not zoomElement then return end
    zoomElement.layout = buildZoomLayout()
    zoomElement:update()
end

local function selectMod(modName)
    if not galaxies[modName] then return end
    activeMod = modName
    hoveredPerkId = nil
    controllerSelectedPerkId = nil
    cancelHold()
    refreshHover()
    refreshZoom()
    if tabsElement then
        tabsElement.layout.content = ui.content {}
        local buttonWidth = math.max(110, math.min(180, dimensions.canvasWidth / math.max(1, #modNames)))
        for index, name in ipairs(modNames) do
            local selected = name == activeMod
            tabsElement.layout.content:add {
                type = ui.TYPE.Container,
                props = { position = v2((index - 1) * buttonWidth, 0), size = v2(buttonWidth - 4, 28) },
                content = ui.content {
                    {
                        type = ui.TYPE.Text,
                        template = interfaces.MWUI.templates.textNormal,
                        props = {
                            position = v2(4, 5), size = v2(buttonWidth - 12, 18),
                            textAlignH = ui.ALIGNMENT.Center, text = name,
                            textColor = selected and COLOR_AVAILABLE or myui.textColors.header,
                        },
                    },
                    { type = ui.TYPE.Image, props = { size = v2(buttonWidth - 4, 28), alpha = 0, resource = transparentTexture } },
                },
                events = {
                    mouseRelease = async:callback(function(event)
                        if event.button == 1 then selectMod(name) end
                    end),
                },
            }
        end
        tabsElement:update()
    end
    refreshCanvas()
end

local function firstNavigableNode()
    local galaxy = activeGalaxy()
    if not galaxy then return nil end
    for _, group in ipairs(galaxy.groups) do
        for _, entry in ipairs(group.perks) do
            if nodeVisible(entry.perk) and galaxy.positions[entry.id] then
                return entry.id
            end
        end
    end
    return nil
end

--- Keeps the controller-selected node inside a comfortable canvas margin and
--- anchors its floating details window beside the selected star.
local function revealControllerNode(perkId)
    local galaxy = activeGalaxy()
    local worldPoint = galaxy and galaxy.positions[perkId]
    if not worldPoint then return end
    local zoom = currentZoom()
    local pan = currentPan()
    local point = worldToCanvas(worldPoint, pan, zoom)
    local margin = 64
    local adjusted = pan
    if point.x < margin then adjusted = adjusted + v2(margin - point.x, 0) end
    if point.x > dimensions.canvasWidth - margin then
        adjusted = adjusted - v2(point.x - (dimensions.canvasWidth - margin), 0)
    end
    if point.y < margin then adjusted = adjusted + v2(0, margin - point.y) end
    if point.y > dimensions.canvasHeight - margin then
        adjusted = adjusted - v2(0, point.y - (dimensions.canvasHeight - margin))
    end
    panByMod[activeMod] = clampPan(galaxy, adjusted)
    point = worldToCanvas(worldPoint, panByMod[activeMod], zoom)
    lastCursorPosition = canvasScreenOrigin() + point
end

local function selectControllerNode(perkId)
    if not perkId then return end
    controllerSelectedPerkId = perkId
    hoveredPerkId = perkId
    cancelHold()
    revealControllerNode(perkId)
    refreshCanvas()
end

--- Selects the closest node lying in a requested screen-space direction. The
--- perpendicular penalty favours intuitive neighbours over distant diagonal
--- jumps while still allowing navigation across separate constellations.
local function navigateControllerNode(directionX, directionY)
    local galaxy = activeGalaxy()
    if not galaxy then return end
    local currentId = controllerSelectedPerkId
    local current = currentId and galaxy.positions[currentId]
    if not current then
        selectControllerNode(firstNavigableNode())
        return
    end

    local bestId
    local bestScore
    for _, group in ipairs(galaxy.groups) do
        for _, entry in ipairs(group.perks) do
            local candidate = galaxy.positions[entry.id]
            if entry.id ~= currentId and candidate and nodeVisible(entry.perk) then
                local delta = candidate - current
                local forward = delta.x * directionX + delta.y * directionY
                if forward > 0.001 then
                    local perpendicular = math.abs(delta.x * directionY - delta.y * directionX)
                    local distance = math.sqrt(delta.x * delta.x + delta.y * delta.y)
                    local score = distance + perpendicular * 1.8
                    if not bestScore or score < bestScore then
                        bestScore = score
                        bestId = entry.id
                    end
                end
            end
        end
    end
    if bestId then selectControllerNode(bestId) end
end

local function navigateControllerMod(delta)
    if #modNames < 2 then return end
    local index = 1
    for candidate, name in ipairs(modNames) do
        if name == activeMod then index = candidate break end
    end
    index = ((index - 1 + delta) % #modNames) + 1
    selectMod(modNames[index])
    selectControllerNode(firstNavigableNode())
end

local function controllerNodeScreenPosition()
    local galaxy = activeGalaxy()
    local worldPoint = galaxy and controllerSelectedPerkId
        and galaxy.positions[controllerSelectedPerkId]
    if not worldPoint then return nil end
    return canvasScreenOrigin() + worldToCanvas(worldPoint, currentPan(), currentZoom())
end

local function processRepeatedInput(name, pressed, dt, action)
    local state = controllerRepeatState[name]
    if not state then
        state = { held = false, remaining = 0 }
        controllerRepeatState[name] = state
    end
    if not pressed then
        state.held = false
        state.remaining = 0
        return
    end
    if not state.held then
        state.held = true
        state.remaining = CONTROLLER_REPEAT_DELAY
        action()
        return
    end
    state.remaining = state.remaining - dt
    if state.remaining <= 0 then
        state.remaining = state.remaining + CONTROLLER_REPEAT_INTERVAL
        action()
    end
end

local function processReleasedInput(name, pressed, action)
    if pressed then
        controllerButtonState[name] = true
    elseif controllerButtonState[name] then
        controllerButtonState[name] = false
        action()
    end
end

local function beginControllerHold(controllerButton, logicalButton)
    local perk = controllerSelectedPerkId
        and interfaces.ErnPerkFramework.getPerk(controllerSelectedPerkId)
    if not perk then return end
    local state = nodeState(perk)
    if logicalButton == 1 and state ~= "available" then return end
    if logicalButton == 3 and state ~= "owned" then return end
    hold = {
        perkId = perk:id(),
        button = logicalButton,
        source = "controller",
        controllerButton = controllerButton,
        startedAt = core.getRealTime(),
        elapsed = 0,
    }
    ambient.playSound("Menu Click")
    refreshHover()
end

--- Handles all non-pointer interaction for the constellation menu. D-pad or
--- left stick navigates nodes, the right stick pans, shoulders change galaxy,
--- triggers zoom, A/X acquire or refund, and B exits.
local function processControllerInput(dt)
    local buttons = input.CONTROLLER_BUTTON
    local axes = input.CONTROLLER_AXIS
    local leftX = input.getAxisValue(axes.LeftX) or 0
    local leftY = input.getAxisValue(axes.LeftY) or 0
    local horizontalDominant = math.abs(leftX) >= math.abs(leftY)
    local verticalDominant = math.abs(leftY) > math.abs(leftX)

    processRepeatedInput("left",
        input.isKeyPressed(input.KEY.LeftArrow)
            or input.isControllerButtonPressed(buttons.DPadLeft)
            or (horizontalDominant and leftX < -CONTROLLER_DEADZONE),
        dt, function() navigateControllerNode(-1, 0) end)
    processRepeatedInput("right",
        input.isKeyPressed(input.KEY.RightArrow)
            or input.isControllerButtonPressed(buttons.DPadRight)
            or (horizontalDominant and leftX > CONTROLLER_DEADZONE),
        dt, function() navigateControllerNode(1, 0) end)
    processRepeatedInput("up",
        input.isKeyPressed(input.KEY.UpArrow)
            or input.isControllerButtonPressed(buttons.DPadUp)
            or (verticalDominant and leftY < -CONTROLLER_DEADZONE),
        dt, function() navigateControllerNode(0, -1) end)
    processRepeatedInput("down",
        input.isKeyPressed(input.KEY.DownArrow)
            or input.isControllerButtonPressed(buttons.DPadDown)
            or (verticalDominant and leftY > CONTROLLER_DEADZONE),
        dt, function() navigateControllerNode(0, 1) end)

    local rightX = input.getAxisValue(axes.RightX) or 0
    local rightY = input.getAxisValue(axes.RightY) or 0
    if math.abs(rightX) < CONTROLLER_DEADZONE then rightX = 0 end
    if math.abs(rightY) < CONTROLLER_DEADZONE then rightY = 0 end
    if rightX ~= 0 or rightY ~= 0 then
        local pan = currentPan() - v2(rightX, rightY) * (CONTROLLER_PAN_SPEED * dt)
        panByMod[activeMod] = clampPan(activeGalaxy(), pan)
        local selectedPosition = controllerNodeScreenPosition()
        if selectedPosition then lastCursorPosition = selectedPosition end
        refreshCanvas()
    end

    processReleasedInput("previousMod", input.isControllerButtonPressed(buttons.LeftShoulder),
        function() navigateControllerMod(-1) end)
    processReleasedInput("nextMod", input.isControllerButtonPressed(buttons.RightShoulder),
        function() navigateControllerMod(1) end)
    processRepeatedInput("zoomOut", (input.getAxisValue(axes.TriggerLeft) or 0) > CONTROLLER_DEADZONE,
        dt, function() setZoom(currentZoom() / ZOOM_STEP, controllerNodeScreenPosition()) end)
    processRepeatedInput("zoomIn", (input.getAxisValue(axes.TriggerRight) or 0) > CONTROLLER_DEADZONE,
        dt, function() setZoom(currentZoom() * ZOOM_STEP, controllerNodeScreenPosition()) end)

    local acquirePressed = input.isControllerButtonPressed(buttons.A)
    if acquirePressed and not controllerButtonState.acquire then
        controllerButtonState.acquire = true
        if not controllerSelectedPerkId then selectControllerNode(firstNavigableNode()) end
        beginControllerHold(buttons.A, 1)
    elseif not acquirePressed and controllerButtonState.acquire then
        controllerButtonState.acquire = false
        if hold and hold.source == "controller" and hold.controllerButton == buttons.A then
            cancelHold()
            refreshHover()
        end
    end

    local refundPressed = input.isControllerButtonPressed(buttons.X)
    if refundPressed and not controllerButtonState.refund then
        controllerButtonState.refund = true
        if not controllerSelectedPerkId then selectControllerNode(firstNavigableNode()) end
        beginControllerHold(buttons.X, 3)
    elseif not refundPressed and controllerButtonState.refund then
        controllerButtonState.refund = false
        if hold and hold.source == "controller" and hold.controllerButton == buttons.X then
            cancelHold()
            refreshHover()
        end
    end

    processReleasedInput("close", input.isControllerButtonPressed(buttons.B), close)
    return menu ~= nil
end

close = function()
    if hoverElement then
        hoverElement:destroy()
        hoverElement = nil
    end
    if menu then
        menu:destroy()
        menu = nil
        canvasElement = nil
        tabsElement = nil
        zoomElement = nil
        hold = nil
        dragging = nil
        hoveredPerkId = nil
        lastCursorPosition = nil
        controllerSelectedPerkId = nil
        controllerRepeatState = {}
        controllerButtonState = {}
        refreshDelay = nil
        interfaces.UI.removeMode("Interface")
    end
end

local function makeCanvasElement()
    local layout = {
        -- Widget is deliberately used here: Container always wraps transformed
        -- descendants and therefore changes the enclosing window during pan or
        -- zoom, even when an explicit size is supplied.
        type = ui.TYPE.Widget,
        props = { size = v2(dimensions.canvasWidth, dimensions.canvasHeight) },
        content = ui.content {},
        events = {
            mousePress = async:callback(function(event)
                if event.button ~= 1 then return end
                dragging = {
                    start = event.position,
                    pan = currentPan(),
                }
            end),
            mouseMove = async:callback(function(event)
                lastCursorPosition = event.position
                if hoveredPerkId and moveHover then moveHover(event.position) end
                if dragging and input.isMouseButtonPressed(1) and not hold then
                    panByMod[activeMod] = clampPan(activeGalaxy(), dragging.pan + (event.position - dragging.start))
                    refreshCanvas()
                end
            end),
            mouseRelease = async:callback(function(event)
                if event.button == 1 then dragging = nil end
                if hold and hold.source == "mouse" and hold.button == event.button then
                    updateHoldElapsed()
                    if hold.elapsed >= HOLD_SECONDS then
                        completeHold()
                    else
                        cancelHold()
                        refreshHover()
                    end
                end
            end),
            focusLoss = async:callback(function()
                dragging = nil
            end),
        },
    }
    return ui.create(layout)
end

local function show(data)
    data = data or {}
    close()
    visiblePerks = nil
    if type(data.visiblePerks) == "table" then
        visiblePerks = {}
        for _, id in ipairs(data.visiblePerks) do visiblePerks[id] = true end
    end

    local screen = layerSize("Windows")
    dimensions.width = math.max(1, math.min(1180, screen.x - 32))
    dimensions.height = math.max(1, math.min(760, screen.y - 32))
    dimensions.canvasWidth = dimensions.width - 24
    dimensions.canvasHeight = dimensions.height - 86
    constrainTooltipDimensions()

    -- Galaxy packing uses the real canvas aspect ratio, so dimensions must be
    -- established before registrations are converted into layout cells.
    buildGalaxyData()
    for _, galaxy in pairs(galaxies) do layoutGalaxy(galaxy) end
    activeMod = galaxies[activeMod] and activeMod or modNames[1]

    tabsElement = ui.create {
        type = ui.TYPE.Widget,
        props = { size = v2(dimensions.canvasWidth - 158, 30) },
    }
    canvasElement = makeCanvasElement()
    zoomElement = ui.create(buildZoomLayout())
    local menuFrame = fixedFrame(dimensions.width, dimensions.height)

    interfaces.UI.setMode("Interface", { windows = {} })
    menu = ui.create {
        layer = "Windows",
        type = ui.TYPE.Widget,
        props = {
            size = v2(dimensions.width, dimensions.height),
            position = v2((screen.x - dimensions.width) / 2, (screen.y - dimensions.height) / 2),
        },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                props = {
                    position = v2(0, 0), size = v2(dimensions.width, dimensions.height),
                    resource = whiteTexture, color = COLOR_PANEL, alpha = 0.72,
                },
            },
            -- Explicit edges avoid the clipping behaviour of the stock
            -- thick-box template inside this fixed, pannable Widget.
            menuFrame,
            {
                type = ui.TYPE.Widget,
                props = {
                    position = v2(12, 10), size = v2(dimensions.canvasWidth - 158, 30),
                },
                content = ui.content { tabsElement },
            },
            {
                type = ui.TYPE.Text,
                template = interfaces.MWUI.templates.textHeader,
                props = { position = v2(dimensions.width - 42, 14), size = v2(24, 20), textAlignH = ui.ALIGNMENT.Center, text = "X" },
                events = { mouseRelease = async:callback(function(event) if event.button == 1 then close() end end) },
            },
            {
                type = ui.TYPE.Widget,
                props = {
                    position = v2(dimensions.width - 158, 10), size = v2(116, 28),
                },
                content = ui.content { zoomElement },
            },
            {
                type = ui.TYPE.Widget,
                props = {
                    position = v2(12, 44), size = v2(dimensions.canvasWidth, dimensions.canvasHeight),
                },
                content = ui.content { canvasElement },
            },
            {
                type = ui.TYPE.Widget,
                props = {
                    position = v2(12, dimensions.height - 36),
                    size = v2(dimensions.canvasWidth, 22),
                },
                content = ui.content { stateLegendLayout() },
            },
        },
    }
    selectMod(activeMod)
end

completeHold = function()
    if not hold then return end
    local action = hold
    hold = nil
    local perk = interfaces.ErnPerkFramework.getPerk(action.perkId)
    if not perk then return end
    local sentAction = false
    if action.button == 1 then
        if not perk:active() and perk:evaluateRequirements().satisfied
            and interfaces.ErnPerkFramework.canAffordPerk(perk) then
            self:sendEvent(MOD_NAME .. "addPerk", { perkID = action.perkId })
            sentAction = true
        end
    elseif action.button == 3 and perk:active() then
        self:sendEvent(MOD_NAME .. "removePerk", { perkID = action.perkId })
        sentAction = true
    end
    if sentAction then
        -- Player events are processed in order. Queueing the redraw behind the
        -- mutation guarantees that perk ownership is current and also avoids
        -- rebuilding UI from inside a mouse callback.
        self:sendEvent(MOD_NAME .. "_internalConstellationRedraw", {})
    end
    refreshHover()
end

local function onFrame(dt)
    if not menu then return end
    if not processControllerInput(dt) then return end
    if hold then
        if hold.source == "controller" then
            if not input.isControllerButtonPressed(hold.controllerButton) then
                cancelHold()
                refreshHover()
            end
        end
        -- Mouse holds complete from real elapsed time and end through a UI
        -- release event. Controllers use the direct state check above because
        -- they have no UI release event.
        if hold then
            updateHoldElapsed()
            if hold.elapsed >= HOLD_SECONDS then
                completeHold()
            else
                refreshHover()
            end
        end
    end
    if refreshDelay then
        refreshDelay = refreshDelay - dt
        if refreshDelay <= 0 then
            refreshDelay = nil
            refreshCanvas()
            refreshHover()
        end
    end
    if input.isKeyPressed(input.KEY.Escape) then
        escapeHeld = true
    elseif escapeHeld then
        escapeHeld = false
        close()
    end
end

local function onMouseWheel(vertical, horizontal)
    if not menu then return end
    if vertical and vertical ~= 0 then
        local factor = vertical > 0 and ZOOM_STEP or (1 / ZOOM_STEP)
        setZoom(currentZoom() * factor, lastCursorPosition)
    elseif horizontal and horizontal ~= 0 then
        local pan = currentPan()
        panByMod[activeMod] = clampPan(activeGalaxy(), pan + v2(horizontal * 45, 0))
        refreshCanvas()
    end
end

--- Rebuilds node states after an ordered player event has added or removed a
--- perk. This entry point runs outside UI callbacks and is safe to call from
--- the framework's internal redraw event.
local function redraw()
    if not menu then return end
    refreshCanvas()
    refreshHover()
end

return {
    show = show,
    close = close,
    isOpen = function() return menu ~= nil end,
    redraw = redraw,
    onFrame = onFrame,
    onMouseWheel = onMouseWheel,
}
