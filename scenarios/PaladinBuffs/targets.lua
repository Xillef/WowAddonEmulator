-- Scenario: PaladinBuffs centre button, mouseover key and minimap icon, with switchable
-- target and mouseover players.
-- Player is a level 60 Paladin who knows Kings, Might and Wisdom (top ranks).
-- Starts with a Warrior target that already has Kings from another Paladin -> expect Might,
-- and nobody under the mouse.
--
-- Switch from the Lua console at the bottom of the page:
--   /pbt <case>   set the TARGET            /pbm <case>   set the player under the MOUSE
-- Cases:
--   warrior   Warrior, Kings from someone else       -> Blessing of Might
--   mage      Mage, no buffs                         -> Blessing of Kings
--   priest    Priest, Kings from someone else        -> Blessing of Wisdom
--   rogue     Rogue, Kings + Might from others       -> Blessing of Wisdom
--   mine      Mage with MY Wisdom on it              -> nothing (centre button disappears)
--   full      Warrior with Kings, Might, Wisdom      -> "Nothing left to give"
--   kw        Warrior, Kings + Wisdom from others    -> Blessing of Might
--   low25     level 25 Warrior with Kings            -> Blessing of Might(Rank 4)
--   low15     level 15 Mage with Kings               -> Blessing of Wisdom(Rank 2)
--   low3      level 3 Mage with Kings                -> nothing (no Wisdom rank fits)
--   none      nobody
-- Target: clicking the button lists the cast in "Secure actions" (type=spell, spell=<ID>).
-- Mouseover: run  PaladinBuffsMouseoverButton:Click()  in the console; "Secure actions"
-- shows the macro it would run (type=macro, macrotext=/cast [@mouseover,...] <Blessing>).
-- /pb macro uses a fake macro store below and prints the macro text to chat.

local Emu = __Emu

Emu.SetPlayer { name = "Aldric", class = "PALADIN", level = 60 }

-- Every rank the addon knows about (PaladinBuffs.lua KINGS / MIGHT / WISDOM), all learned.
-- KINGS, MIGHT, WISDOM below are the top ranks, used for the test players' buffs.
local KINGS, MIGHT, WISDOM = 20217, 25291, 25290
local RANKS = {
    ["Blessing of Kings"]  = { 20217 },
    ["Blessing of Might"]  = { 19740, 19834, 19835, 19836, 19837, 19838, 25291 },
    ["Blessing of Wisdom"] = { 19742, 19850, 19852, 19853, 19854, 25290 },
}
local RANK_TEXT = {} -- spellID -> "Rank N"
for name, ids in pairs(RANKS) do
    for i, id in ipairs(ids) do
        Emu.AddSpell(id, { name = name, known = true })
        RANK_TEXT[id] = "Rank " .. i
    end
end
-- Not emulated by default: the rank text the addon puts into /cast.
function C_Spell.GetSpellSubtext(id) return RANK_TEXT[id] end

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

-- The test players. Auras without "mine" come from another Paladin (party1).
local CASES = {
    warrior = { class = "WARRIOR", name = "Brakka",  auras = { KINGS } },
    mage    = { class = "MAGE",    name = "Ilyra",   auras = {} },
    priest  = { class = "PRIEST",  name = "Selwyn",  auras = { KINGS } },
    rogue   = { class = "ROGUE",   name = "Vexx",    auras = { KINGS, MIGHT } },
    mine    = { class = "MAGE",    name = "Ilyra",   auras = {}, mine = WISDOM },
    full    = { class = "WARRIOR", name = "Brakka",  auras = { KINGS, MIGHT, WISDOM } },
    kw      = { class = "WARRIOR", name = "Brakka",  auras = { KINGS, WISDOM } },
    -- Low-level players: a rank lands on players down to 10 levels below its own level.
    low25   = { class = "WARRIOR", name = "Grub",    auras = { KINGS }, level = 25 }, -- Might rank 4 (lvl 32)
    low15   = { class = "MAGE",    name = "Pip",     auras = { KINGS }, level = 15 }, -- Wisdom rank 2 (lvl 24)
    low3    = { class = "MAGE",    name = "Tiny",    auras = { KINGS }, level = 3 },  -- no Wisdom rank fits -> nothing
}

-- Who is currently the target and who is under the mouse (case keys or nil).
local current = { target = nil, mouseover = nil }

-- Rebuilds the fake units "target" and "mouseover" with their buffs.
local function rebuild()
    local members = {}
    Emu.state.auras.target, Emu.state.auras.mouseover = nil, nil
    for _, unit in ipairs({ "target", "mouseover" }) do
        local c = CASES[current[unit] or ""]
        if c then
            members[#members + 1] = { unit = unit, name = c.name, class = c.class, level = c.level or 60 }
        end
    end
    Emu.SetGroup(members)
    for _, unit in ipairs({ "target", "mouseover" }) do
        local c = CASES[current[unit] or ""]
        if c then
            for _, id in ipairs(c.auras) do
                Emu.AddAura(unit, { name = C_Spell.GetSpellName(id), spellId = id, sourceUnit = "party1" })
            end
            if c.mine then
                Emu.AddAura(unit, { name = C_Spell.GetSpellName(c.mine), spellId = c.mine, sourceUnit = "player" })
            end
        end
    end
end

-- Sets one unit to a case and fires the event the game would fire.
local function setUnit(unit, key, event)
    current[unit] = CASES[key] and key or nil
    rebuild()
    Emu.FireEvent(event)
    local c = CASES[key]
    Emu.Chat(unit .. ": " .. (c and (c.name .. " (" .. c.class .. ")") or "none"))
end

-- Same pattern as an addon slash command: SLASH_<KEY>1 + SlashCmdList[KEY].
SLASH_PBTEST1 = "/pbt"
SlashCmdList.PBTEST = function(msg) setUnit("target", (msg or ""):lower(), "PLAYER_TARGET_CHANGED") end
SLASH_PBMOUSE1 = "/pbm"
SlashCmdList.PBMOUSE = function(msg) setUnit("mouseover", (msg or ""):lower(), "UPDATE_MOUSEOVER_UNIT") end

current.target = "warrior"
rebuild()
