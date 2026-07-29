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
local core = require("openmw.core")
local pself = require("openmw.self")
local types = require("openmw.types")
local calculation = require("scripts.ErnPerkFramework.calculation")

local DEFAULT_PRIORITY = 1000
local HIT_DIRECTION = calculation.DIRECTION
local HIT_DAMAGE_CALCULATION = {
    health = calculation.CALCULATION.HIT_DAMAGE_HEALTH,
    fatigue = calculation.CALCULATION.HIT_DAMAGE_FATIGUE,
    magicka = calculation.CALCULATION.HIT_DAMAGE_MAGICKA,
}

local handlers = {}
local nextOrder = 0
local rawObservers = {}
local nextRawObserverOrder = 0
local hookInstalled = false
local lastDispatch = nil
local DUPLICATE_WINDOW = 0.15
local HIT_BRIDGE_REVISION = 6

--- Recognizes a Player GameObject through the engine type field, while also
--- accepting wrapper variants supported by the type API predicate.
local function isPlayerObject(object)
    if object == nil then
        return false
    end
    local fieldOk, objectType = pcall(function() return object.type end)
    if fieldOk and objectType == types.Player then
        return true
    end
    local predicateOk, isPlayer = pcall(types.Player.objectIsInstance, object)
    return predicateOk and isPlayer == true
end

--- Returns true when two OpenMW object handles identify the same world object.
--- Local-script boundaries can produce distinct userdata wrappers, while the
--- documented GameObject.id remains stable and unique.
--- @param left GameObject|nil First object handle.
--- @param right GameObject|nil Second object handle.
--- @return boolean same
local function sameObject(left, right)
    if left == nil or right == nil then
        return false
    end
    if left == right then
        return true
    end

    local leftOk, leftId = pcall(function() return left.id end)
    local rightOk, rightId = pcall(function() return right.id end)
    if leftOk and rightOk and leftId ~= nil and leftId == rightId then
        return true
    end

    -- A player handle forwarded across local-script boundaries may use a
    -- different userdata wrapper and hide its object id. OpenMW is
    -- single-player, so two Player instances still identify the same actor.
    return isPlayerObject(left) and isPlayerObject(right)
end

--- Compares optional object handles while preserving nil-to-nil equality.
--- Hit payloads can omit the attacker or weapon, so duplicate detection must
--- distinguish two absent handles from one absent and one present handle.
--- @param left GameObject|nil First optional object handle.
--- @param right GameObject|nil Second optional object handle.
--- @return boolean same
local function sameOptionalObject(left, right)
    if left == nil or right == nil then
        return left == nil and right == nil
    end
    return sameObject(left, right)
end

--- Adds a perk's arithmetic contribution to the current hit. Contributions
--- are collected during on-hit observation and resolved together after every
--- handler has run, preventing each perk from sending its own damage event.
--- @param attack table OpenMW combat attack table.
--- @param resource string "health", "fatigue", or "magicka".
--- @param amount number Non-negative amount to add.
--- @param metadata table|nil Optional source details retained for diagnostics.
--- @return boolean added True when a positive contribution was recorded.
local function addHitDamage(attack, resource, amount, metadata)
    if type(attack) ~= "table" then
        error("addHitDamage() requires an attack table.", 2)
    end
    if HIT_DAMAGE_CALCULATION[resource] == nil then
        error("addHitDamage() resource must be health, fatigue, or magicka.", 2)
    end
    amount = tonumber(amount) or 0
    if amount <= 0 then
        return false
    end

    attack.perkFrameworkDamageAdditions = attack.perkFrameworkDamageAdditions or {}
    local additions = attack.perkFrameworkDamageAdditions
    additions[resource] = (tonumber(additions[resource]) or 0) + amount

    if metadata ~= nil then
        attack.perkFrameworkDamageContributors = attack.perkFrameworkDamageContributors or {}
        table.insert(attack.perkFrameworkDamageContributors, {
            resource = resource,
            amount = amount,
            metadata = metadata,
        })
    end
    return true
end

--- Returns additions collected by on-hit handlers at the Addition stage.
local function accumulatedHitDamage(resource)
    return function(data)
        local attack = data.context
        local additions = attack and attack.perkFrameworkDamageAdditions
        return additions and additions[resource] or nil
    end
end

for resource, channel in pairs(HIT_DAMAGE_CALCULATION) do
    calculation.registerCalculationHandler({
        id = "ErnPerkFramework_accumulated_hit_damage_" .. resource,
        calculation = channel,
        operation = calculation.OPERATION.Addition,
        priority = DEFAULT_PRIORITY,
    }, accumulatedHitDamage(resource))
end

--- Classifies a hit relative to this script context's actor.
--- Forwarders should provide `options.direction` when the source actor lives
--- in another local-script context.
local function getHitDirection(attack, options)
    options = options or {}
    if options.direction ~= nil then
        return options.direction
    end
    if attack.skillPerksPlayerOwned == true or sameObject(attack.attacker, pself) then
        return HIT_DIRECTION.Outgoing
    end
    local target = attack.target or attack.victim or attack.defender
    if isPlayerObject(pself) and target ~= nil and not sameObject(target, pself) then
        -- Some OpenMW unarmed payloads omit the attacker. In the player-local
        -- Combat context, a hit whose target is another actor is still
        -- unambiguously outgoing.
        return HIT_DIRECTION.Outgoing
    end
    if target == nil or sameObject(target, pself) then
        return HIT_DIRECTION.Incoming
    end
    return HIT_DIRECTION.Other
end

--- Sorts on-hit event handlers by priority and registration order.
local function sortHandlers()
    table.sort(handlers, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)
end

--- Sorts raw hit observers by priority and registration order.
local function sortRawObservers()
    table.sort(rawObservers, function(a, b)
        if a.priority == b.priority then
            return a.order < b.order
        end
        return a.priority < b.priority
    end)
end

--- Returns one damage component without assuming the payload contains damage.
local function damageValue(attack, resource)
    return attack and attack.damage and attack.damage[resource] or nil
end

--- Captures an actor's dynamic resources before hit arithmetic or engine
--- damage changes them. The snapshot travels with bridged hit payloads so
--- player-local perk handlers can make reliable threshold and kill decisions.
--- @param actor GameObject|nil Actor about to receive the hit.
--- @return table resources Health, fatigue, and magicka snapshots when readable.
local function snapshotDynamicResources(actor)
    local resources = {}
    if not actor or not actor:isValid() then
        return resources
    end
    for _, resource in ipairs({ "health", "fatigue", "magicka" }) do
        local getter = types.Actor.stats.dynamic[resource]
        if getter then
            local ok, stat = pcall(getter, actor)
            if ok and stat then
                local maximum = math.max(0, (tonumber(stat.base) or 0) + (tonumber(stat.modifier) or 0))
                local current = tonumber(stat.current) or 0
                resources[resource] = {
                    base = tonumber(stat.base) or 0,
                    modifier = tonumber(stat.modifier) or 0,
                    current = current,
                    maximum = maximum,
                    ratio = maximum > 0 and current / maximum or 0,
                }
            end
        end
    end
    return resources
end

--- Detects the same engine hit arriving through both a local hook and a
--- target-to-player bridge. The narrow time window is shorter than a normal
--- weapon follow-up while still covering next-frame event delivery.
local function isDuplicateHit(attack, now)
    local previous = lastDispatch
    if not previous or now - previous.time > DUPLICATE_WINDOW then
        return false
    end
    return sameOptionalObject(previous.attacker, attack.attacker)
        and sameOptionalObject(previous.target, attack.target or attack.victim or attack.defender)
        and sameOptionalObject(previous.weapon, attack.weapon)
        and previous.successful == attack.successful
        and previous.attackType == attack.type
        and previous.strength == attack.strength
        and previous.health == damageValue(attack, "health")
        and previous.fatigue == damageValue(attack, "fatigue")
        and previous.magicka == damageValue(attack, "magicka")
end

--- Remembers enough of a hit to suppress a duplicate delivery route.
local function rememberHit(attack, now)
    lastDispatch = {
        time = now,
        attacker = attack.attacker,
        target = attack.target or attack.victim or attack.defender,
        weapon = attack.weapon,
        successful = attack.successful,
        attackType = attack.type,
        strength = attack.strength,
        health = damageValue(attack, "health"),
        fatigue = damageValue(attack, "fatigue"),
        magicka = damageValue(attack, "magicka"),
    }
end

--- Runs registered on-hit event handlers, then optionally resolves standard
--- damage fields. A forwarded observation can resolve its copied damage when
--- its bridge applies only the difference from the completed engine hit.
--- Event handlers are for detection and side effects; damage-affecting changes
--- should use calculation handlers so the final value is resolved once.
--- @param attack table OpenMW combat attack table.
--- @param options table|nil Forwarding context.
--- @return boolean processed False when a duplicate delivery was suppressed.
local function dispatchOnHit(attack, options)
    if type(attack) ~= "table" then
        return false
    end
    options = options or {}

    -- Raw observers are the earliest extension point in the single engine
    -- hook. They receive every payload before deduplication or direction
    -- filtering, which is necessary for bridges and diagnostics that must
    -- establish ownership from the original attacker data.
    local rawTarget = options.target or attack.target or attack.victim or attack.defender or pself
    attack.perkFrameworkPreHitResources = attack.perkFrameworkPreHitResources
        or snapshotDynamicResources(rawTarget)
    local rawDirection = getHitDirection(attack, options)
    local rawContext = {
        self = pself,
        target = rawTarget,
        source = options.source or "engine",
        forwarded = options.forwarded == true,
        direction = rawDirection,
    }
    for _, entry in ipairs(rawObservers) do
        local ok, err = pcall(entry.observer, attack, rawContext)
        if not ok then
            print("ErnPerkFramework raw onHit observer failed (" .. tostring(entry.id) .. "): " .. tostring(err))
        end
    end

    local now = core.getSimulationTime()
    if options.deduplicate ~= false and isDuplicateHit(attack, now) then
        return false
    end
    rememberHit(attack, now)
    local direction = getHitDirection(attack, options)
    attack.perkFrameworkHitDirection = direction

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
        target = options.target or attack.target or attack.victim or attack.defender or pself,
        originalDamage = originalDamage,
        source = options.source or "engine",
        forwarded = options.forwarded == true,
        direction = direction,
        stop = false,
    }
    -- Preserve an earlier target-side snapshot when this hit has crossed a
    -- bridge; otherwise this is the authoritative pre-engine-damage capture.
    context.preHitResources = attack.perkFrameworkPreHitResources
    local afterResolution = {}

    --- Defers observation until every hit calculation has resolved.
    --- This is useful for target bridges and diagnostics that need the final
    --- attack values but must not install another engine-level hit hook.
    context.afterResolve = function(callback)
        if type(callback) ~= "function" then
            error("on-hit context.afterResolve() requires a function.", 2)
        end
        table.insert(afterResolution, callback)
    end

    for _, entry in ipairs(handlers) do
        if entry.direction == HIT_DIRECTION.Any or entry.direction == direction then
            local ok, err = pcall(entry.handler, attack, context)
            if not ok then
                print("ErnPerkFramework onHit handler failed (" .. tostring(entry.id) .. "): " .. tostring(err))
            end
            if context.stop then
                break
            end
        end
    end

    if options.resolveDamage ~= false then
        attack.damage = attack.damage or {}
        local additions = attack.perkFrameworkDamageAdditions or {}
        for resource, channel in pairs(HIT_DAMAGE_CALCULATION) do
            if attack.damage[resource] ~= nil or (tonumber(additions[resource]) or 0) > 0 then
                attack.damage[resource] = calculation.resolveCalculation({
                    calculation = channel,
                    baseValue = tonumber(attack.damage[resource]) or 0,
                    min = 0,
                    actor = context.target,
                    source = attack.attacker,
                    context = attack,
                    direction = direction,
                })
            end
        end
    end

    for _, callback in ipairs(afterResolution) do
        local ok, err = pcall(callback, attack, context)
        if not ok then
            print("ErnPerkFramework after-hit callback failed: " .. tostring(err))
        end
    end
    return true
end

--- Installs the underlying OpenMW Combat hook once for this script context.
local function ensureHookInstalled()
    if hookInstalled then
        return
    end
    hookInstalled = true
    interfaces.Combat.addOnHitHandler(function(attack)
        -- dispatchOnHit returns whether the Framework processed the payload.
        -- That internal result must not be returned to OpenMW: returning false
        -- from an engine handler prevents other mods' handlers from running.
        dispatchOnHit(attack)
    end)
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
    if data.direction ~= nil
            and data.direction ~= HIT_DIRECTION.Any
            and data.direction ~= HIT_DIRECTION.Incoming
            and data.direction ~= HIT_DIRECTION.Outgoing
            and data.direction ~= HIT_DIRECTION.Other then
        error("registerOnHitHandler() direction must be any, incoming, outgoing, or other.", 3)
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

--- Unregisters every raw observer with the given id.
--- @param id string Observer id.
local function unregisterRawOnHitObserver(id)
    if type(id) ~= "string" then
        error("unregisterRawOnHitObserver() requires a string id.", 2)
    end
    for i = #rawObservers, 1, -1 do
        if rawObservers[i].id == id then
            table.remove(rawObservers, i)
        end
    end
end

--- Registers an observer at the entrance of the Framework's sole engine hit
--- hook. Raw observers cannot alter ordering or stop resolution; use them for
--- ownership bridges and diagnostics that must see unfiltered engine payloads.
--- @param data table|function|nil Registration data or callback.
--- @param observer function|nil Optional callback when data is a table.
--- @return boolean success
local function registerRawOnHitObserver(data, observer)
    data, observer = validateHandler(data, observer)
    ensureHookInstalled()

    if data.id ~= nil then
        unregisterRawOnHitObserver(data.id)
    end

    nextRawObserverOrder = nextRawObserverOrder + 1
    table.insert(rawObservers, {
        id = data.id or ("anonymous_raw_" .. tostring(nextRawObserverOrder)),
        priority = data.priority or DEFAULT_PRIORITY,
        order = nextRawObserverOrder,
        observer = observer,
    })
    sortRawObservers()
    return true
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
        direction = data.direction or HIT_DIRECTION.Any,
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
            direction = entry.direction,
        })
    end
    return out
end

--- Returns raw observer metadata for diagnostics.
--- @return table observers
local function getRawOnHitObservers()
    local out = {}
    for _, entry in ipairs(rawObservers) do
        table.insert(out, {
            id = entry.id,
            priority = entry.priority,
        })
    end
    return out
end

-- Install at module load so the shared hook keeps the Framework's load-order
-- position instead of waiting for the first perk mod to register a listener.
ensureHookInstalled()

return {
    HIT_BRIDGE_REVISION = HIT_BRIDGE_REVISION,
    DEFAULT_ON_HIT_PRIORITY = DEFAULT_PRIORITY,
    HIT_DIRECTION = HIT_DIRECTION,
    getHitDirection = getHitDirection,
    registerOnHitHandler = registerOnHitHandler,
    unregisterOnHitHandler = unregisterOnHitHandler,
    getOnHitHandlers = getOnHitHandlers,
    registerRawOnHitObserver = registerRawOnHitObserver,
    unregisterRawOnHitObserver = unregisterRawOnHitObserver,
    getRawOnHitObservers = getRawOnHitObservers,
    dispatchOnHit = dispatchOnHit,
    addHitDamage = addHitDamage,
}
