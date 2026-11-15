-- Scenario: PaladinBuffs centre button + minimap icon, with switchable targets.
-- Player is a level 60 Paladin who knows Kings, Might and Wisdom (top ranks).
-- Starts with a Warrior target that already has Kings from another Paladin -> expect Might.
--
-- Switch the target from the Lua console at the bottom of the page:
--   /pbt warrior   Warrior, Kings from someone else       -> Blessing of Might
--   /pbt mage      Mage, no buffs                         -> Blessing of Kings
--   /pbt priest    Priest, Kings from someone else        -> Blessing of Wisdom
--   /pbt rogue     Rogue, Kings + Might from others       -> Blessing of Wisdom
--   /pbt mine      Mage with MY Wisdom on it              -> button disappears
--   /pbt full      Warrior with Kings, Might, Wisdom      -> "Nothing left to give"
--   /pbt none      no target                              -> "No target"
-- Clicking the button lists the cast in "Secure actions" (type=spell, spell=<ID>).
-- /pb macro uses a fake macro store below and prints the macro text to chat.

local Emu = __Emu

Emu.SetPlayer { name = "Aldric", class = "PALADIN", level = 60 }

-- Highest ranks the addon looks for (PaladinBuffs.lua KINGS / MIGHT / WISDOM).
local KINGS, MIGHT, WISDOM = 20217, 25291, 25290
Emu.AddSpell(KINGS,  { name = "Blessing of Kings",  known = true })
Emu.AddSpell(MIGHT,  { name = "Blessing of Might",  known = true })
Emu.AddSpell(WISDOM, { name = "Blessing of Wisdom", known = true })

-- Not emulated by default: everyone in this scenario is a friendly player.
function UnitCanAssist(_, unit) return UnitExists(unit) end

-- Fake macro store, so /pb macro and the self-updating macro can be watched in chat.
local macro -- { name, icon, body }
function GetNumMacros() return 0, macro and 1 or 0 end
function GetMacroIndexByName(name) return (macro and macro.name == name) and 121 or 0 end
function CreateMacro(name, icon, body) macro = { name = name, icon = icon, body = body } return 121 end
function EditMacro(_, name, icon, body)
    macro = { name = name, icon = icon, body = body }
    Emu.Chat("[fake macro] " .. body:gsub("\n", " | "))
    return 121
end
function PickupMacro() Emu.Chat("[fake macro] picked up onto the cursor") end

local TARGETS = {
    warrior = { class = "WARRIOR", name = "Brakka",  auras = { KINGS } },
    mage    = { class = "MAGE",    name = "Ilyra",   auras = {} },
    priest  = { class = "PRIEST",  name = "Selwyn",  auras = { KINGS } },
    rogue   = { class = "ROGUE",   name = "Vexx",    auras = { KINGS, MIGHT } },
    mine    = { class = "MAGE",    name = "Ilyra",   auras = {}, mine = WISDOM },
    full    = { class = "WARRIOR", name = "Brakka",  auras = { KINGS, MIGHT, WISDOM } },
}

local function setTarget(key)
    local t = TARGETS[key]
    Emu.state.auras.target = nil
    if not t then
        Emu.SetGroup {}
    else
        Emu.SetGroup { { unit = "target", name = t.name, class = t.class } }
        for _, id in ipairs(t.auras) do
            Emu.AddAura("target", { name = C_Spell.GetSpellName(id), spellId = id, sourceUnit = "party1" })
        end
        if t.mine then
            Emu.AddAura("target", { name = C_Spell.GetSpellName(t.mine), spellId = t.mine, sourceUnit = "player" })
        end
    end
    Emu.FireEvent("PLAYER_TARGET_CHANGED")
    Emu.Chat("Target: " .. (t and (t.name .. " (" .. t.class .. ")") or "none"))
end

-- Same pattern as an addon slash command: SLASH_<KEY>1 + SlashCmdList[KEY].
SLASH_PBTEST1 = "/pbt"
SlashCmdList.PBTEST = function(msg) setTarget((msg or ""):lower()) end

setTarget("warrior")
