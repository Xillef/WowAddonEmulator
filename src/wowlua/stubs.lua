-- Fallback for everything the emulator doesn't implement. Loaded last, after
-- generated/apinames.lua was passed in as Emu.api.
--
-- Real WoW API names (from the annotations) become logged no-op stubs returning nil:
--   - global functions (GetFoo), C_* namespace functions (C_Foo.Bar), widget methods
-- Names that don't exist in WoW stay nil, so calling them errors like in-game.
-- The page lists every stub that got called, with a count.

local Emu = __Emu
local api = Emu.api

-- Widget methods: object type -> set of method names (incl. inherited) in the real API.
local methodSets = {}
local function methodSet(typeName)
    local set = methodSets[typeName]
    if set then return set end
    set = {}
    methodSets[typeName] = set
    local seen = {}
    local function collect(name)
        if seen[name] then return end
        seen[name] = true
        local w = api.widgets[name]
        if not w then return end
        for _, m in ipairs(w.methods) do set[m] = true end
        for _, p in ipairs(w.parents) do collect(p) end
    end
    collect(typeName)
    return set
end

function Emu.MissingMethod(typeName, key)
    if type(key) ~= "string" then return nil end
    if methodSet(typeName)[key] then
        return Emu.Stub(typeName .. ":" .. key)
    end
    return nil
end

-- C_* namespaces: missing functions in partly emulated namespaces, and whole
-- namespaces that aren't emulated at all.
local function stubNamespace(nsName, tbl)
    local names = {}
    for _, f in ipairs(api.namespaces[nsName] or {}) do names[f] = true end
    return setmetatable(tbl or {}, {
        __index = function(_, k)
            if names[k] then return Emu.Stub(nsName .. "." .. k) end
        end,
    })
end

for nsName in pairs(api.namespaces) do
    local existing = rawget(_G, nsName)
    if type(existing) == "table" then
        if not getmetatable(existing) then stubNamespace(nsName, existing) end
    else
        rawset(_G, nsName, stubNamespace(nsName))
    end
end

local globalNames = {}
for _, f in ipairs(api.globals) do globalNames[f] = true end

setmetatable(_G, {
    __index = function(_, k)
        if globalNames[k] then return Emu.Stub(k) end
    end,
})
