# ErnPerkFramework
OpenMW mod that adds a perk framework.

A perk selection window will pop up after your level up window (for NCGDMW users, the window will pop up after you rest). The window will not pop up if there are no available perks. The perk selection window is controller friendly: hit A to choose the current perk or B to cancel. You can save up your perk points for later. Perks might cost additional points, or might actually give you points (or be free). It all depends on the perk mods you add.

## Using the Framework

- You can adjust the perk points per level in the mod settings.
- If you no longer meet the requirements for a perk, it will be removed and you will be refunded.
- If you want to respec, bring up the console and type `luaperks respec`.
- If you want to manually bring up the perk window, bring up the console and type `luaperks menu`.

## Installing

Download the [latest version here](https://github.com/TyrusDalet/ErnPerkFramework---Tyrus-Revision/archive/refs/heads/main.zip).

Extract to your `mods/` folder. In your `openmw.cfg` file, add these lines in the correct spots:

```ini
data="/wherevermymodsare/mods/ErnPerkFramework-main"
content=ErnPerkFramework.omwscripts
```

Mods that add perks *must be loaded after this mod*.

An example perk will be installed if you add this to your `openmw.cfg`:
```ini
content=ErnCultistPerk.omwscripts
```

## Credits

This project uses code from [Potential Character Progression](https://github.com/Qlonever/PCP-OpenMW), licensed under the MIT License and copyright (c) 2024 Qlonever.

Special thanks to ownlyme for help with the UI.

## Making New Perks

You must register perks in the body of a `PLAYER` script.
When you register a perk, you supply information about the perk that the framework needs. The framework expects the following fields in the table passed into `interfaces.ErnPerkFramework.registerPerk({...})`:

- `id` is a globally unique, stable identifier for your perk. Including your mod name in this field is a good way to prevent collisions with other mods.
- `requirements` is a list of `requirement` tables. We'll get into these later. This can be an empty list.
- `onAdd` is a function that the framework will invoke. It will be invoked when the player adds the perk, and also whenever the game starts up (if the player still has the perk).
- `onRemove` is a function that the framework will invoke. It will be invoked when the player respecs or when the requirements are no longer satisified.
- `localizedName` is a string or a function that returns a string. This is the player-visible name for the perk.
- `localizedFlavour` is a string or a function that returns a string. It displays below the requirements and above the description and is always visible. `localizedFlavor` is also an acceptable entry.
- `localizedDescription` is a string or a function that returns a string. This is the player-visible description for the perk that appears inside the perk detail pane, this will automatically subdivide into pages should the description get too long (520 characters by default). Pages can be manually added by adding a flow form character to the string "\f".
- `category` is an optional section. The preferred shape is `{ mod="MyPerkMod", type="Magic", group="Alteration", order=1 }`. The perk menu shows `mod` as the top-level tab, `type` as a section header, and `group` as the collapsible perk chain. `order` sorts perks inside the group from lowest to highest. The array shape `{ "MyPerkMod", "Magic", "Alteration", 1 }` is also supported. Legacy categories shaped like `{ "Magic", "Alteration", 1 }` still work and are placed under the `"Unsorted"` mod tab. Any perk without a category remains present in the `"All"` tab only.
- `art` is a string or a function that returns a string. This is a path to a texture file that appears inside the perk detail pane. It should be 256x128 pixels, which matches the vanilla class levelup textures. You can use those textures if you don't have art for your perk like this: `art = "textures\\levelup\\sorcerer"`. If you don't specify art, you will see the placeholder art in the detail pane.
- `hidden` is a boolean or a function that returns a boolean. This will cause the perk to not appear by default in the perk window.
- `cost` is a number or a function that returns a number. By default, this is 1. This is the number of perk points the perk costs to add to the player. This can be a negative value, which allows you to make flaw or handicap perks.

### Requirements

Now let's talk about requirements. These are tables with the following fields:

- `id` is a globally unique, stable identifier for your requirement. Including your mod name in this field is a good way to prevent collisions with other mods.
- `check` is a function that returns a boolean. This should return true if the requirement is satisfied.
- `localizedName` is a string or a function that returns a string. This is the player-visible name for the requirement. It should be short and descriptive.

There are a bunch of built-in requirements you can use in `interfaces.ErnPerkFramework.requirements()`. Here's a complicated example for a requirement that is `true` if the player has at least 30 Mysticism or 30 Destruction:

```lua
interfaces.ErnPerkFramework.requirements().
  orGroup(
    interfaces.ErnPerkFramework.requirements().minimumSkillLevel('mysticism', 30),
    interfaces.ErnPerkFramework.requirements().minimumSkillLevel('destruction', 30)
    )
```

Check out `requirements.lua` for more built-ins.

### Cross-Mod Perk Checks

Use `isPerkRegistered(perkID)` when you need to know whether another loaded mod
registered a perk at all. This checks installed/loaded capability, not whether
the player owns that perk:

```lua
if interfaces.ErnPerkFramework.isPerkRegistered("OtherMod_special_perk") then
    -- Register compatibility content, add extra requirements, or alter text.
end
```

For requirement lists, prefer the built-in optional requirement when you want a
perk to depend on another mod's perk only if that other mod is installed:

```lua
local R = interfaces.ErnPerkFramework.requirements()

requirements = {
    R.minimumLevel(10),
    R.hasPerkIfRegistered("OtherMod_special_perk"),
}
```

If `OtherMod_special_perk` is not registered, the optional requirement is
treated as satisfied and hidden from the requirements list. If it is registered,
the player must own that perk.

Use `registeredPerk(...)` when the perk should only be available if another
perk mod is installed, regardless of whether the player owns the perk.

For player-owned perks, the framework maintains both the original ordered list
and a cached set. Use `playerHasPerk(perkID)` for repeated checks instead of
scanning `getPlayerPerks()`:

```lua
if interfaces.ErnPerkFramework.playerHasPerk("MyMod_perk") then
    -- fast ownership check
end
```

`getPlayerPerkRevision()` changes whenever the owned-perk list changes, which
lets UI or cached logic invalidate ownership-dependent state.

### Custom Perk Resources

By default, all perks use the framework's generic level-based perk points. If
the player enables **Allow Custom Perk Acquisition Methods**, perk packs can
register their own point/token resources and assign perks to those resources.

```lua
interfaces.ErnPerkFramework.registerPerkResource({
    id = "FactionPerks_factionTokens",
    name = "Faction Token",
    pluralName = "Faction Tokens",
})

interfaces.ErnPerkFramework.addPerkResource("FactionPerks_factionTokens", 1)
```

Perks opt into a resource with `costResource`:

```lua
interfaces.ErnPerkFramework.registerPerk({
    id = "MyMod_faction_power",
    cost = 1,
    costResource = "FactionPerks_factionTokens",
    requirements = {},
    onAdd = function() end,
    onRemove = function() end,
})
```

Resource totals are persisted by the framework. Spending is derived from the
owned perk list, so a respec returns those tokens to the available pool.

Useful helpers:

```lua
interfaces.ErnPerkFramework.availablePoints("FactionPerks_factionTokens")
interfaces.ErnPerkFramework.availablePointsForPerk(perk)
interfaces.ErnPerkFramework.canAffordPerk(perk)
```

### Direct Perk Grants

Dialogue, trainer, quest, or compatibility rewards can grant a perk without
routing through the perk menu purchase flow:

```lua
local ok, reason = interfaces.ErnPerkFramework.grantPerk("MyMod_special_perk", {
    checkRequirements = true,
    checkCost = false,
})
```

By default `grantPerk` bypasses both requirements and point cost. Set
`checkRequirements` or `checkCost` when a reward path still needs framework
validation. It updates the persistent player perk list and calls the perk's
`onAdd` handler exactly like a normal purchase.

### Runtime Interop Hooks

Perk mods should register combat hit effects through the framework instead of
calling `interfaces.Combat.addOnHitHandler` directly. This gives all perk mods
one ordered event pipeline for the same attack record:

```lua
interfaces.ErnPerkFramework.registerOnHitHandler({
    id = "MyMod_my_hit_effect",
    priority = 200,
}, function(attack, context)
    -- inspect or modify attack here
end)
```

Lower priority values run earlier. Use this to put mitigation before reactive
counterattacks, and final feedback or proc effects later. The same API is
available in `PLAYER`, `NPC`, and `CREATURE` scripts when this framework's
omwscripts file is loaded.

Hit event handlers are for detection and side effects. Actor-affecting values
that multiple mods may change should use the calculation resolver below.

### Calculation Resolver

Use calculations when several mods may affect one final value. The framework
applies contributors in this order:

```text
Multiplier -> Divider -> Subtraction -> Addition -> Modifier
```

`Divider` is where "% less" effects belong. For example, "25% less damage"
should divide by `1.25`, not multiply by `0.75`. `Modifier` is for final
post-resolution effects or exact final-value overrides.

Register a contribution like this:

```lua
interfaces.ErnPerkFramework.registerCalculationHandler({
    id = "MyMod_damage_reduction",
    calculation = "hit.damage.health",
    operation = "Divider",
    priority = 100,
}, function(data)
    if data.actor == nil then return end
    return 1.25
end)
```

Resolve a value like this:

```lua
local finalDamage = interfaces.ErnPerkFramework.resolveCalculation({
    calculation = "direct.damage.health",
    baseValue = damage,
    min = 0,
    actor = target,
    source = attacker,
    context = {
        sourceEffect = "MyMod_special_damage",
    },
})
```

The framework automatically resolves standard combat hit damage fields through:

```text
hit.damage.health
hit.damage.fatigue
hit.damage.magicka
```

Separate flat damage effects should resolve through:

```text
direct.damage.health
direct.damage.fatigue
direct.damage.magicka
direct.restore.health
direct.restore.fatigue
direct.restore.magicka
```

For direct dynamic-stat changes, prefer the framework helper so all mods share
the same calculation channel before the stat is changed:

```lua
local I = interfaces.ErnPerkFramework

local applied = I.applyActorResourceDelta({
    actor = target,
    resource = "fatigue",
    operation = I.RESOURCE_OPERATION.Damage,
    amount = 25,
    source = attacker,
    sourceEffect = "MyMod_fatigue_strike",
})
```

### Skill-Use Hooks

Use `registerSkillUseHandler` instead of registering separate
`SkillProgression.addSkillUsedHandler` callbacks in every perk script. The
framework captures the current spell-cast context once and dispatches an event
to matching handlers:

```lua
interfaces.ErnPerkFramework.registerSkillUseHandler({
    id = "MyMod_alteration_refund",
    skill = "alteration",
    playerCastOnly = true,
    priority = 200,
}, function(event)
    -- event.skillId
    -- event.spell
    -- event.cost
    -- event.sourceType = "spell", "enchantment", or "unknown"
    -- event.isPlayerCast
    -- event.enchantedItem
end)
```

Lower priority values run earlier. `playerCastOnly = true` excludes enchanted
item casts and unknown sources, which is useful for perks that should only
reward spells the player actually knows and casts themselves.

Enchant effects can resolve self-targeting magnitude through:

```text
enchant.castOnUse.selfEffectMagnitude
enchant.constantEffect.selfEffectMagnitude
```

For optional AbilitiesAsModifiers support, report modifier tables through:

```lua
interfaces.ErnPerkFramework.reportExternalModifiers("My Perk Source", {
    attributes = { strength = 5 },
    skills = { longblade = 10 },
})
```

Passing `nil` as the second argument clears that source. The framework stores
the normalized report even when AbilitiesAsModifiers is not present, then
forwards it to AAM when available for tooltip display.

Other mods can read the framework-owned registry:

```lua
local sourceReport = interfaces.ErnPerkFramework.getExternalModifierReport("My Perk Source")
local allReports = interfaces.ErnPerkFramework.getExternalModifierReports()
local strengthSources = interfaces.ErnPerkFramework.getExternalModifierSources("strength")
local totalStrength = interfaces.ErnPerkFramework.getExternalModifierTotal("strength")
```

These APIs return the currently reported framework modifiers only. They do not
read OpenMW's live final stat object, and they do not include effects that never
reported through `reportExternalModifiers`.
