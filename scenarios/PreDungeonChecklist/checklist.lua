-- Scenario: PreDungeonChecklist pre-pull checklist, opened with /pdc.
-- Fake game state for a Fire Mage in a 5-player group inside a Mythic+ dungeon:
-- flask active (with a low stock), no food buff, no augment rune, weapon oil about to
-- run out, one item at low durability. Runs before the addon's files load.
-- Item/spell IDs below are the addon's own (Core.lua / Detection.lua); names/icons are
-- scenario data, icons are placeholders unless you map them in assets-local/.

local Emu = __Emu

Emu.SetPlayer { name = "Emberlyn", realm = "EmulatorRealm", specID = 63, level = 90 }
Emu.SetGroup {
    { name = "Stonewall", class = "WARRIOR", role = "TANK" },
    { name = "Lightwell", class = "PRIEST", role = "HEALER" },
    { name = "Quickstep", class = "ROGUE", role = "DAMAGE" },
    { name = "Thornroot", class = "DRUID", role = "DAMAGE" },
}
Emu.SetInstance { name = "Emulated Dungeon", type = "party", difficultyID = 23, difficultyName = "Mythic", maxPlayers = 5 }

-- Consumables in the bags
Emu.AddItem(241322, { name = "Flask of the Magisters", count = 2, classID = 0, subclassID = 3, bag = 0, slot = 1 })
Emu.AddItem(242275, { name = "Royal Roast", count = 6, classID = 0, subclassID = 5, bag = 0, slot = 2 })
Emu.AddItem(241309, { name = "Light's Potential", count = 12, classID = 0, subclassID = 1, bag = 0, slot = 3 })
Emu.AddItem(243733, { name = "Thalassian Phoenix Oil", count = 4, classID = 0, subclassID = 8, bag = 0, slot = 4 })

-- Buffs on the player: a flask (name matched by substring in Detection.lua)
Emu.AddAura("player", { name = "Flask of the Magisters", spellId = 1235110, duration = 3600, expiresIn = 2400 })

-- Mainhand oil with 4 minutes left (warning range)
Emu.SetWeaponEnchant { mainHand = { expiresIn = 240, charges = 0 } }

-- Gear durability: slot 5 (chest) at 40 %
for slot = 1, 17 do
    Emu.SetInventorySlot(slot, { itemID = 100000 + slot, durability = { 100, 100 } })
end
Emu.SetInventorySlot(5, { itemID = 100005, durability = { 40, 100 } })

Emu.OnLogin(function()
    Emu.RunSlashCommand("/pdc")
end)
