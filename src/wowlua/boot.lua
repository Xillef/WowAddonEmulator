-- Addon loading and the login event sequence, driven by toc.js:
--   Emu.BeginAddon(name, metadata) -> each file runs with ... = Emu.AddonArgs()
--   -> Emu.FinishAddon(name) (SavedVariables + ADDON_LOADED) -> Emu.Login()

local Emu = __Emu

Emu.addons = {}
local byName = {}
local current

function Emu.FindAddon(name)
    return byName[tostring(name):lower()]
end

function Emu.AddonMetadata(name, field)
    local a = Emu.FindAddon(name)
    if not a then return nil end
    for k, v in pairs(a.metadata) do
        if k:lower() == tostring(field):lower() then return v end
    end
end

function Emu.IsAddonLoaded(name)
    local a = Emu.FindAddon(name)
    return a ~= nil and a.loaded
end

-- metadata: "key\tvalue\n..." lines from the .toc header (## Key: Value).
function Emu.BeginAddon(name, metadataText)
    local meta = {}
    for line in tostring(metadataText or ""):gmatch("[^\n]+") do
        local k, v = line:match("^([^\t]+)\t(.*)$")
        if k then meta[k] = v end
    end
    local a = { name = name, ns = {}, metadata = meta, loaded = false }
    table.insert(Emu.addons, a)
    byName[name:lower()] = a
    current = a
end

-- The two values every addon file receives as `...`.
function Emu.AddonArgs()
    return current.name, current.ns
end

-- Scenario files can preset SavedVariables (as the game would load them from disk).
-- They're assigned after the addon's files ran and before ADDON_LOADED, like in-game.
Emu.savedVariables = {}
function Emu.SetSavedVariables(t)
    for k, v in pairs(t) do Emu.savedVariables[k] = v end
end

function Emu.FinishAddon(name, savedVariableNames)
    local a = Emu.FindAddon(name)
    for sv in tostring(savedVariableNames or ""):gmatch("[^,%s]+") do
        _G[sv] = Emu.savedVariables[sv]
    end
    a.loaded = true
    Emu.FireEvent("ADDON_LOADED", a.name, false)
end

local loginCallbacks = {}
-- fn runs after PLAYER_ENTERING_WORLD (the scenario's "now open the window" step).
function Emu.OnLogin(fn) table.insert(loginCallbacks, fn) end

function Emu.Login()
    Emu.loggedIn = true
    Emu.FireEvent("SPELLS_CHANGED")
    Emu.FireEvent("PLAYER_LOGIN")
    Emu.FireEvent("PLAYER_ENTERING_WORLD", true, false)
    for _, fn in ipairs(loginCallbacks) do Emu.SafeCall(fn) end
end

-- Runs a slash command the way typing it into chat does, e.g. "/pdc config".
function Emu.RunSlashCommand(text)
    local cmd, rest = text:match("^(/%S+)%s*(.-)%s*$")
    if not cmd then error("Emu.RunSlashCommand: not a slash command: " .. tostring(text), 2) end
    cmd = cmd:lower()
    for key, fn in pairs(SlashCmdList) do
        local i = 1
        while true do
            local alias = rawget(_G, "SLASH_" .. key .. i)
            if not alias then break end
            if alias:lower() == cmd then
                fn(rest, nil)
                return true
            end
            i = i + 1
        end
    end
    Emu.Chat("Unknown slash command: " .. cmd)
    return false
end
