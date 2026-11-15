-- Fake game state + the game APIs that read it. Scenario files fill Emu.state through
-- the Emu.Set*/Add* helpers at the bottom (or replace any API function outright).
-- Everything not here is either a logged stub (real API name) or nil (stubs.lua).

local Emu = __Emu

local CLASSES = {
    -- classID, classFile, name, specs { specID, name, role }
    { 1, "WARRIOR", "Warrior", { { 71, "Arms", "DAMAGE" }, { 72, "Fury", "DAMAGE" }, { 73, "Protection", "TANK" } } },
    { 2, "PALADIN", "Paladin", { { 65, "Holy", "HEALER" }, { 66, "Protection", "TANK" }, { 70, "Retribution", "DAMAGE" } } },
    { 3, "HUNTER", "Hunter", { { 253, "Beast Mastery", "DAMAGE" }, { 254, "Marksmanship", "DAMAGE" }, { 255, "Survival", "DAMAGE" } } },
    { 4, "ROGUE", "Rogue", { { 259, "Assassination", "DAMAGE" }, { 260, "Outlaw", "DAMAGE" }, { 261, "Subtlety", "DAMAGE" } } },
    { 5, "PRIEST", "Priest", { { 256, "Discipline", "HEALER" }, { 257, "Holy", "HEALER" }, { 258, "Shadow", "DAMAGE" } } },
    { 6, "DEATHKNIGHT", "Death Knight", { { 250, "Blood", "TANK" }, { 251, "Frost", "DAMAGE" }, { 252, "Unholy", "DAMAGE" } } },
    { 7, "SHAMAN", "Shaman", { { 262, "Elemental", "DAMAGE" }, { 263, "Enhancement", "DAMAGE" }, { 264, "Restoration", "HEALER" } } },
    { 8, "MAGE", "Mage", { { 62, "Arcane", "DAMAGE" }, { 63, "Fire", "DAMAGE" }, { 64, "Frost", "DAMAGE" } } },
    { 9, "WARLOCK", "Warlock", { { 265, "Affliction", "DAMAGE" }, { 266, "Demonology", "DAMAGE" }, { 267, "Destruction", "DAMAGE" } } },
    { 10, "MONK", "Monk", { { 268, "Brewmaster", "TANK" }, { 270, "Mistweaver", "HEALER" }, { 269, "Windwalker", "DAMAGE" } } },
    { 11, "DRUID", "Druid", { { 102, "Balance", "DAMAGE" }, { 103, "Feral", "DAMAGE" }, { 104, "Guardian", "TANK" }, { 105, "Restoration", "HEALER" } } },
    { 12, "DEMONHUNTER", "Demon Hunter", { { 577, "Havoc", "DAMAGE" }, { 581, "Vengeance", "TANK" } } },
    { 13, "EVOKER", "Evoker", { { 1467, "Devastation", "DAMAGE" }, { 1468, "Preservation", "HEALER" }, { 1473, "Augmentation", "DAMAGE" } } },
}
local CLASS_BY_FILE, CLASS_BY_ID, SPEC_BY_ID = {}, {}, {}
for _, c in ipairs(CLASSES) do
    CLASS_BY_FILE[c[2]] = c
    CLASS_BY_ID[c[1]] = c
    for i, sp in ipairs(c[4]) do SPEC_BY_ID[sp[1]] = { class = c, index = i, spec = sp } end
end

local QUESTION_MARK_ICON = 134400 -- fileID of Interface\Icons\INV_Misc_QuestionMark (drawn as a placeholder)

Emu.state = {
    player = { name = "Player", realm = "EmulatorRealm", class = "MAGE", specIndex = 1, level = 90, guid = "Player-0000-00000001" },
    group = {},          -- { { unit = "party1", name = "...", class = "WARRIOR", role = "TANK" }, ... }
    auras = {},          -- [unit] = { helpful = { aura, ... }, harmful = { ... } }
    items = {},          -- [itemID] = { name, icon, count, quality, classID, subclassID, equipLoc, cooldown = { start, duration } }
    bags = {},           -- [bag] = { [slot] = itemID }, bag 0..4 (numSlots defaults to the highest used slot)
    inventory = {},      -- [slotID] = { itemID = n, durability = { cur, max }, link = "..." }
    spells = {},         -- [spellID] = { name, icon, known = bool, cooldown = { start, duration } }
    weaponEnchant = nil, -- { mainHand = { expiresIn = sec, charges = n, enchantID = n }, offHand = {...} }
    instance = { name = "Emulator Zone", type = "none", difficultyID = 0, difficultyName = "", maxPlayers = 0, instanceID = 0 },
    uiMapID = 0,
    challengeMaps = {},  -- [mapID] = { name, timeLimit, texture }
    keystone = nil,      -- { mapID = n, level = n }
    inCombat = false,
    cvars = {},
    equipmentSets = {},  -- { { id, name, icon, isEquipped } }
}
local state = Emu.state

---------------------------------------------------------------------------
-- Units / group
---------------------------------------------------------------------------
local function unitInfo(unit)
    if not unit then return nil end
    unit = unit:lower()
    if unit == "player" then return state.player end
    for _, m in ipairs(state.group) do
        if m.unit == unit then return m end
    end
end

function UnitExists(unit) return unitInfo(unit) ~= nil end
function UnitName(unit)
    local u = unitInfo(unit)
    if not u then return nil end
    return u.name, u.realm ~= state.player.realm and u.realm or nil
end
function UnitNameUnmodified(unit) return UnitName(unit) end
function UnitFullName(unit)
    local u = unitInfo(unit)
    if not u then return nil end
    return u.name, u.realm or state.player.realm
end
function UnitClass(unit)
    local u = unitInfo(unit)
    if not u then return nil end
    local c = CLASS_BY_FILE[u.class]
    return c[3], c[2], c[1]
end
function UnitClassBase(unit)
    local _, file, id = UnitClass(unit)
    return file, id
end
function UnitLevel(unit) local u = unitInfo(unit) return u and (u.level or state.player.level) or -1 end
function UnitGUID(unit) local u = unitInfo(unit) return u and (u.guid or ("Player-0000-" .. (u.unit or "x"))) end
function UnitIsUnit(a, b) return unitInfo(a) ~= nil and unitInfo(a) == unitInfo(b) end
function UnitIsPlayer(unit) return unitInfo(unit) ~= nil end
function UnitIsConnected(unit) return unitInfo(unit) ~= nil end
function UnitIsDeadOrGhost(unit) local u = unitInfo(unit) return u and u.dead or false end
function UnitIsDead(unit) return UnitIsDeadOrGhost(unit) end
function UnitInParty(unit) return unitInfo(unit) ~= nil end
function UnitInRaid(unit) return nil end
function UnitAffectingCombat(unit) return state.inCombat end
function UnitGroupRolesAssigned(unit)
    local u = unitInfo(unit)
    if not u then return "NONE" end
    if u == state.player then
        local c = CLASS_BY_FILE[u.class]
        local sp = c[4][u.specIndex or 1]
        return sp and sp[3] or "NONE"
    end
    return u.role or "NONE"
end
function UnitRace(unit) return "Human", "Human", 1 end
function UnitFactionGroup(unit) return "Alliance", "Alliance" end
function UnitHealth() return 100 end
function UnitHealthMax() return 100 end

function IsInGroup() return #state.group > 0 end
function IsInRaid() return false end
function GetNumGroupMembers() return #state.group > 0 and (#state.group + 1) or 0 end
function GetNumSubgroupMembers() return #state.group end
function UnitIsGroupLeader(unit) return unit == "player" end
function InCombatLockdown() return state.inCombat end
function GetRealmName() return state.player.realm end
function GetNormalizedRealmName() return (state.player.realm:gsub("[%s%-]", "")) end

-- Classes / specs
function GetNumClasses() return #CLASSES end
function GetClassInfo(classID)
    local c = CLASS_BY_ID[classID]
    if c then return c[3], c[2], c[1] end
end
function GetSpecialization() return state.player.specIndex end
function GetNumSpecializations() return #CLASS_BY_FILE[state.player.class][4] end
function GetNumSpecializationsForClassID(classID)
    local c = CLASS_BY_ID[classID]
    return c and #c[4] or 0
end
local function specReturns(sp, classID)
    -- id, name, description, icon, role, primaryStat (icon: placeholder fileID)
    return sp[1], sp[2], "", QUESTION_MARK_ICON, sp[3], 4
end
function GetSpecializationInfo(index)
    local sp = CLASS_BY_FILE[state.player.class][4][index]
    if sp then return specReturns(sp) end
end
function GetSpecializationInfoForClassID(classID, index)
    local c = CLASS_BY_ID[classID]
    local sp = c and c[4][index]
    if sp then return specReturns(sp) end
end
function GetSpecializationInfoByID(specID)
    local e = SPEC_BY_ID[specID]
    if e then
        local id, name, desc, icon, role = specReturns(e.spec)
        return id, name, desc, icon, role, e.class[2], e.class[3]
    end
end
function GetSpecializationRole(index)
    local sp = CLASS_BY_FILE[state.player.class][4][index]
    return sp and sp[3]
end

C_ClassColor = {}
function C_ClassColor.GetClassColor(classFile) return RAID_CLASS_COLORS[classFile] end
function GetClassColor(classFile)
    local c = RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b, c.colorStr end
    return 1, 1, 1, "ffffffff"
end

---------------------------------------------------------------------------
-- Auras
---------------------------------------------------------------------------
C_UnitAuras = {}
local function auraList(unit, filter)
    local u = unitInfo(unit)
    local key = u and (u == state.player and "player" or u.unit)
    local a = key and state.auras[key]
    if not a then return {} end
    if filter and filter:find("HARMFUL") then return a.harmful or {} end
    return a.helpful or {}
end
function C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
    return auraList(unit, filter)[index]
end
function C_UnitAuras.GetBuffDataByIndex(unit, index) return auraList(unit, "HELPFUL")[index] end
function C_UnitAuras.GetDebuffDataByIndex(unit, index) return auraList(unit, "HARMFUL")[index] end
function C_UnitAuras.GetPlayerAuraBySpellID(spellID)
    for _, a in ipairs(auraList("player", "HELPFUL")) do
        if a.spellId == spellID then return a end
    end
end
function C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id)
    for _, a in ipairs(auraList(unit, "HELPFUL")) do if a.auraInstanceID == id then return a end end
    for _, a in ipairs(auraList(unit, "HARMFUL")) do if a.auraInstanceID == id then return a end end
end
function C_UnitAuras.GetAuraDataBySpellName(unit, name, filter)
    for _, a in ipairs(auraList(unit, filter)) do if a.name == name then return a end end
end

---------------------------------------------------------------------------
-- Items / bags / inventory
---------------------------------------------------------------------------
C_Item = {}
local function item(id)
    if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) or id end
    return state.items[id], id
end
function C_Item.GetItemCount(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
    local it = item(itemID)
    return it and it.count or 0
end
GetItemCount = C_Item.GetItemCount
function C_Item.GetItemInfo(itemID)
    local it, id = item(itemID)
    if not it then return nil end
    return it.name, ("|cffffffff|Hitem:%d::::::::|h[%s]|h|r"):format(id, it.name or "?"), it.quality or 1, it.itemLevel or 1,
        1, it.itemType or "", it.itemSubType or "", it.stackCount or 20, it.equipLoc or "", it.icon or QUESTION_MARK_ICON,
        0, it.classID or 0, it.subclassID or 0, 1, 10, nil, false
end
GetItemInfo = C_Item.GetItemInfo
function C_Item.GetItemInfoInstant(itemID)
    local it, id = item(itemID)
    if not it then return nil end
    return id, it.itemType or "", it.itemSubType or "", it.equipLoc or "", it.icon or QUESTION_MARK_ICON, it.classID or 0, it.subclassID or 0
end
GetItemInfoInstant = C_Item.GetItemInfoInstant
function C_Item.GetItemIconByID(itemID)
    local it = item(itemID)
    return it and it.icon or QUESTION_MARK_ICON
end
GetItemIcon = C_Item.GetItemIconByID
function C_Item.GetItemNameByID(itemID) local it = item(itemID) return it and it.name end
function C_Item.GetItemCooldown(itemID)
    local it = item(itemID)
    local cd = it and it.cooldown
    if cd then return cd[1], cd[2], 1 end
    return 0, 0, 1
end
GetItemCooldown = C_Item.GetItemCooldown
function C_Item.IsItemDataCachedByID() return true end
function C_Item.RequestLoadItemDataByID() end
function C_Item.DoesItemExistByID(itemID) return item(itemID) ~= nil end

C_Container = {}
function C_Container.GetContainerNumSlots(bag)
    local b = state.bags[bag]
    if not b then return (bag >= 0 and bag <= 4) and 16 or 0 end
    local n = b.numSlots or 0
    for slot in pairs(b) do if type(slot) == "number" and slot > n then n = slot end end
    return n
end
function C_Container.GetContainerItemID(bag, slot)
    local b = state.bags[bag]
    return b and b[slot] or nil
end
function C_Container.GetContainerItemInfo(bag, slot)
    local id = C_Container.GetContainerItemID(bag, slot)
    if not id then return nil end
    local it = state.items[id] or {}
    return { iconFileID = it.icon or QUESTION_MARK_ICON, stackCount = 1, itemID = id, hyperlink = select(2, C_Item.GetItemInfo(id)), quality = it.quality or 1 }
end
function C_Container.GetContainerNumFreeSlots(bag) return 0, 0 end

local function inv(slot) return state.inventory[slot] end
function GetInventoryItemID(unit, slot)
    if unit ~= "player" then return nil end
    local s = inv(slot)
    return s and s.itemID
end
function GetInventoryItemLink(unit, slot)
    if unit ~= "player" then return nil end
    local s = inv(slot)
    if not s then return nil end
    return s.link or select(2, C_Item.GetItemInfo(s.itemID)) or ("|Hitem:%d::::::::|h[Item]|h"):format(s.itemID)
end
function GetInventoryItemTexture(unit, slot)
    local s = unit == "player" and inv(slot)
    return s and (state.items[s.itemID] and state.items[s.itemID].icon or QUESTION_MARK_ICON)
end
function GetInventoryItemDurability(slot)
    local s = inv(slot)
    if s and s.durability then return s.durability[1], s.durability[2] end
end
function GetInventorySlotInfo(name) return 0 end

-- hasMainHandEnchant, mainHandExpiration (ms), mainHandCharges, mainHandEnchantID, hasOffHand...
function GetWeaponEnchantInfo()
    local w = state.weaponEnchant
    if not w then return false, 0, 0, 0, false, 0, 0, 0 end
    local function part(p)
        if not p then return false, 0, 0, 0 end
        return true, (p.expiresIn or 0) * 1000, p.charges or 0, p.enchantID or 0
    end
    local a, b, c, d = part(w.mainHand)
    local e, f, g, h = part(w.offHand)
    return a, b, c, d, e, f, g, h
end

C_EquipmentSet = {}
function C_EquipmentSet.GetEquipmentSetIDs()
    local ids = {}
    for _, s in ipairs(state.equipmentSets) do ids[#ids + 1] = s.id end
    return ids
end
function C_EquipmentSet.GetEquipmentSetInfo(setID)
    for _, s in ipairs(state.equipmentSets) do
        if s.id == setID then return s.name, s.icon or QUESTION_MARK_ICON, setID, s.isEquipped or false, 0, 0, 0, 0, 0 end
    end
end
function C_EquipmentSet.GetNumEquipmentSets() return #state.equipmentSets end

---------------------------------------------------------------------------
-- Spells
---------------------------------------------------------------------------
C_Spell = {}
local function spellByNameOrID(s)
    if type(s) == "number" then return state.spells[s], s end
    if type(s) == "string" then
        local n = tonumber(s)
        if n then return state.spells[n], n end
        for id, sp in pairs(state.spells) do
            if sp.name == s then return sp, id end
        end
    end
end
-- Unknown spell IDs get generic data (in-game, any valid ID returns info).
function C_Spell.GetSpellInfo(spell)
    local sp, id = spellByNameOrID(spell)
    if not sp then
        if type(id) ~= "number" then return nil end
        return { name = "Spell " .. id, iconID = QUESTION_MARK_ICON, originalIconID = QUESTION_MARK_ICON, castTime = 0, minRange = 0, maxRange = 0, spellID = id }
    end
    return { name = sp.name, iconID = sp.icon or QUESTION_MARK_ICON, originalIconID = sp.icon or QUESTION_MARK_ICON, castTime = 0, minRange = 0, maxRange = 0, spellID = id }
end
function C_Spell.GetSpellName(spell) local i = C_Spell.GetSpellInfo(spell) return i and i.name end
function C_Spell.GetSpellTexture(spell) local i = C_Spell.GetSpellInfo(spell) return i and i.iconID, i and i.originalIconID end
function C_Spell.GetSpellCooldown(spell)
    local sp = spellByNameOrID(spell)
    local cd = sp and sp.cooldown
    return { startTime = cd and cd[1] or 0, duration = cd and cd[2] or 0, isEnabled = true, modRate = 1 }
end
function C_Spell.DoesSpellExist(spell) return true end
function C_Spell.IsSpellUsable(spell) return true, false end
function C_Spell.GetSpellCharges(spell) return nil end
function C_Spell.GetSpellDescription(spell) return "" end

C_SpellBook = {}
function C_SpellBook.IsSpellKnown(spellID)
    local sp = state.spells[spellID]
    return sp and sp.known or false
end
function C_SpellBook.IsSpellInSpellBook(spellID) return C_SpellBook.IsSpellKnown(spellID) end
function C_SpellBook.GetNumSpellBookSkillLines() return 0 end
IsSpellKnown = C_SpellBook.IsSpellKnown
IsPlayerSpell = C_SpellBook.IsSpellKnown

---------------------------------------------------------------------------
-- Instance / M+
---------------------------------------------------------------------------
function GetInstanceInfo()
    local i = state.instance
    return i.name, i.type, i.difficultyID, i.difficultyName or "", i.maxPlayers or 5, 0, false, i.instanceID or 0, i.groupSize or 5, i.lfgDungeonID
end
function IsInInstance()
    local t = state.instance.type
    return t ~= "none", t
end
function GetZoneText() return state.instance.name end
function GetRealZoneText() return state.instance.name end
function GetSubZoneText() return "" end
function GetMinimapZoneText() return state.instance.name end

C_Map = {}
function C_Map.GetBestMapForUnit(unit) return state.uiMapID end
function C_Map.GetMapInfo(mapID) return { mapID = mapID, name = state.instance.name, mapType = 4, parentMapID = 0 } end

C_ChallengeMode = {}
function C_ChallengeMode.GetMapUIInfo(mapID)
    local m = state.challengeMaps[mapID]
    if not m then return nil end
    return m.name, mapID, m.timeLimit or 1800, m.texture or QUESTION_MARK_ICON, m.background or QUESTION_MARK_ICON, m.uiMapID
end
function C_ChallengeMode.GetMapTable()
    local ids = {}
    for id in pairs(state.challengeMaps) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end
function C_ChallengeMode.IsChallengeModeActive() return state.challengeModeActive or false end
function C_ChallengeMode.GetActiveChallengeMapID() return state.challengeModeActive and state.activeChallengeMapID or nil end
function C_ChallengeMode.GetSlottedKeystoneInfo() return nil end

C_MythicPlus = {}
function C_MythicPlus.GetOwnedKeystoneChallengeMapID() return state.keystone and state.keystone.mapID end
function C_MythicPlus.GetOwnedKeystoneLevel() return state.keystone and state.keystone.level end

---------------------------------------------------------------------------
-- CVars, addons, misc
---------------------------------------------------------------------------
function GetCVar(name) return state.cvars[name] end
function GetCVarBool(name) local v = state.cvars[name] return v == "1" or v == true end
function GetCVarDefault(name) return state.cvars[name] end
function SetCVar(name, value) state.cvars[name] = value ~= nil and tostring(value) or nil return true end
function CVarExists(name) return state.cvars[name] ~= nil end
C_CVar = {
    GetCVar = GetCVar, SetCVar = SetCVar, GetCVarBool = GetCVarBool, GetCVarDefault = GetCVarDefault,
    GetCVarInfo = function(name)
        local v = state.cvars[name]
        if v == nil then return nil end
        return v, v, false, false, false, false, false
    end,
}

C_AddOns = {}
function C_AddOns.GetAddOnMetadata(addon, field) return Emu.AddonMetadata(addon, field) end
function C_AddOns.IsAddOnLoaded(addon) return Emu.IsAddonLoaded(addon), Emu.IsAddonLoaded(addon) end
function C_AddOns.GetNumAddOns() return #Emu.addons end
function C_AddOns.LoadAddOn(addon) return Emu.IsAddonLoaded(addon), nil end
function C_AddOns.GetAddOnInfo(addon)
    local a = Emu.FindAddon(addon)
    if not a then return nil end
    return a.name, a.metadata.Title or a.name, a.metadata.Notes or "", true, "INSECURE", nil, false
end
function C_AddOns.GetAddOnEnableState() return 2 end
GetAddOnMetadata = C_AddOns.GetAddOnMetadata
IsAddOnLoaded = C_AddOns.IsAddOnLoaded

C_Texture = {}
-- Atlas data isn't available: any atlas name gets generic info (placeholder size).
function C_Texture.GetAtlasInfo(atlas)
    if type(atlas) ~= "string" or atlas == "" then return nil end
    return { width = 32, height = 32, leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1,
        tilesHorizontally = false, tilesVertically = false, file = nil, filename = nil }
end

C_DateAndTime = {}
function C_DateAndTime.GetSecondsUntilWeeklyReset() return 3 * 24 * 3600 end
function C_DateAndTime.GetCurrentCalendarTime()
    local t = os.date("*t")
    return { year = t.year, month = t.month, monthDay = t.day, weekday = t.wday, hour = t.hour, minute = t.min }
end

function SendChatMessage(msg, chatType, language, target)
    Emu.Chat(("[SendChatMessage %s%s] %s"):format(tostring(chatType), target and (" " .. tostring(target)) or "", tostring(msg)))
end
function ReloadUI() __js("reload") end
function GetFramerate() return 60 end
function GetNetStats() return 0, 0, 20, 20 end
function IsPlayerInWorld() return Emu.loggedIn end

---------------------------------------------------------------------------
-- Scenario helpers
---------------------------------------------------------------------------
-- Emu.SetPlayer { name =, realm =, class = "MAGE", specID = 63 | specIndex = 2, level = }
function Emu.SetPlayer(p)
    for k, v in pairs(p) do state.player[k] = v end
    if p.specID then
        local e = SPEC_BY_ID[p.specID]
        assert(e, "Emu.SetPlayer: unknown specID " .. tostring(p.specID))
        state.player.class = e.class[2]
        state.player.specIndex = e.index
    end
    assert(CLASS_BY_FILE[state.player.class], "Emu.SetPlayer: unknown class " .. tostring(state.player.class))
end

-- Emu.SetGroup { { name =, class =, role = }, ... }  -> party1..4
function Emu.SetGroup(members)
    state.group = {}
    for i, m in ipairs(members) do
        m.unit = m.unit or ("party" .. i)
        state.group[i] = m
    end
end

local auraInstance = 0
-- Emu.AddAura("player", { name =, spellId =, icon =, duration = sec, expiresIn = sec, harmful = bool, ... })
function Emu.AddAura(unit, a)
    auraInstance = auraInstance + 1
    local list = state.auras[unit] or { helpful = {}, harmful = {} }
    state.auras[unit] = list
    local aura = {
        name = a.name, spellId = a.spellId, icon = a.icon or QUESTION_MARK_ICON, applications = a.applications or 0,
        duration = a.duration or 0, expirationTime = a.expiresIn and (GetTime() + a.expiresIn) or 0,
        sourceUnit = a.sourceUnit or unit, isHelpful = not a.harmful, isHarmful = a.harmful or false,
        auraInstanceID = auraInstance, isFromPlayerOrPlayerPet = a.sourceUnit == "player",
        dispelName = a.dispelName, points = a.points or {},
    }
    table.insert(a.harmful and list.harmful or list.helpful, aura)
    return aura
end

-- Emu.AddItem(itemID, { name =, icon =, count =, quality =, classID =, subclassID =, equipLoc =, cooldown = { start, duration }, bag =, slot = })
function Emu.AddItem(itemID, it)
    state.items[itemID] = it
    if it.bag then
        state.bags[it.bag] = state.bags[it.bag] or {}
        state.bags[it.bag][it.slot or 1] = itemID
    end
end

-- Emu.SetInventorySlot(slotID, { itemID =, durability = { cur, max } })
function Emu.SetInventorySlot(slotID, s) state.inventory[slotID] = s end

-- Emu.AddSpell(spellID, { name =, icon =, known = true, cooldown = { start, duration } })
function Emu.AddSpell(spellID, sp) state.spells[spellID] = sp end

function Emu.SetInstance(i) for k, v in pairs(i) do state.instance[k] = v end end
function Emu.SetWeaponEnchant(w) state.weaponEnchant = w end
function Emu.AddChallengeMap(mapID, m) state.challengeMaps[mapID] = m end
function Emu.SetKeystone(k) state.keystone = k end
function Emu.SetCVars(t) for k, v in pairs(t) do state.cvars[k] = tostring(v) end end
