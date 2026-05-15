# ErnPerkFramework
OpenMW mod that adds a perk framework.

A perk selection window will pop up after your level up window (for NCGDMW users, the window will pop up after you rest). The window will not pop up if there are no available perks. The perk selection window is controller friendly: hit A to choose the current perk or B to cancel. You can save up your perk points for later. Perks might cost additional points, or might actually give you points (or be free). It all depends on the perk mods you add.

## Using the Framework

- You can adjust the perk points per level in the mod settings.
- If you no longer meet the requirements for a perk, it will be removed and you will be refunded.
- If you want to respec, bring up the console and type `lua perkrespec`.
- If you want to manually bring up the perk window, bring up the console and type `lua perks`.

## Installing

Download the [latest version here](https://github.com/erinpentecost/ErnPerkFramework/archive/refs/heads/main.zip).

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
- `category` is an optional section. It is a table consisting of two strings and an integer. The first string determines what tab at the top of the perk menu the perk belongs in. The second string determines the name of the dropdown menu the perk is in. The integer determines in what order (from lowest to highest) the perk is placed - should the default order not be suitable. Any perk without a category will be present in the "All" tab.
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
