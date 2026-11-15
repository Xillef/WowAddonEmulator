-- WoW's additions to plain Lua 5.1: global aliases, string/table helpers, and the
-- sandbox (no io/os/require/loadfile, like the game client).
-- Runs first, before every other wowlua file.

local Emu = __Emu

-- Sandbox: the game client has no io/package/require/file access. os keeps only
-- time/date/clock/difftime. `debug` is mostly gone in-game (debugstack/debugprofilestop
-- exist as globals instead).
do
    local osTime, osDate, osClock, osDifftime = os.time, os.date, os.clock, os.difftime
    os = { time = osTime, date = osDate, clock = osClock, difftime = osDifftime }
    io, package, require, module, loadfile, dofile, debug = nil, nil, nil, nil, nil, nil, nil
    time, date, difftime = osTime, osDate, osDifftime
end

-- string library aliases
strlen, strsub, strfind, strmatch, gmatch, gsub = string.len, string.sub, string.find, string.match, string.gmatch, string.gsub
strupper, strlower, strrep, strbyte, strchar, strrev = string.upper, string.lower, string.rep, string.byte, string.char, string.reverse
format = string.format
string.gfind = string.gmatch

-- math aliases
abs, ceil, floor, max, min, sqrt, exp, log, log10 = math.abs, math.ceil, math.floor, math.max, math.min, math.sqrt, math.exp, math.log, math.log10
frexp, ldexp, random, mod = math.frexp, math.ldexp, math.random, math.fmod
PI = math.pi
-- WoW's trig globals take degrees.
sin = function(d) return math.sin(math.rad(d)) end
cos = function(d) return math.cos(math.rad(d)) end
tan = function(d) return math.tan(math.rad(d)) end
asin = function(x) return math.deg(math.asin(x)) end
acos = function(x) return math.deg(math.acos(x)) end
atan = function(x) return math.deg(math.atan(x)) end
atan2 = function(y, x) return math.deg(math.atan2(y, x)) end

-- table aliases
tinsert, tremove, sort, getn, foreach, foreachi = table.insert, table.remove, table.sort, table.getn, table.foreach, table.foreachi
tconcat = table.concat

function wipe(t)
    for k in pairs(t) do t[k] = nil end
    return t
end
table.wipe = wipe

function tContains(t, value)
    for _, v in pairs(t) do
        if v == value then return true end
    end
    return false
end

function tInvert(t)
    local out = {}
    for k, v in pairs(t) do out[v] = k end
    return out
end

function CopyTable(t, seen)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and CopyTable(v) or v
    end
    return out
end

function tIndexOf(t, value)
    for i = 1, #t do
        if t[i] == value then return i end
    end
end

-- strsplit(delimiters, str [, pieces]) -> ...  Each char of `delimiters` is a separator.
function strsplit(delim, str, pieces)
    local out, n = {}, 0
    local pattern = "[" .. delim:gsub("[%]%^%-%%]", "%%%0") .. "]"
    local pos = 1
    while true do
        if pieces and n == pieces - 1 then break end
        local s, e = str:find(pattern, pos)
        if not s then break end
        n = n + 1
        out[n] = str:sub(pos, s - 1)
        pos = e + 1
    end
    n = n + 1
    out[n] = str:sub(pos)
    return unpack(out, 1, n)
end
string.split = function(str, delim, pieces) return strsplit(delim, str, pieces) end

function strjoin(delim, ...)
    return table.concat({ ... }, delim)
end
string.join = strjoin

-- strtrim(str [, chars]) — default chars are whitespace.
function strtrim(str, chars)
    chars = chars or " \t\r\n"
    local set = "[" .. chars:gsub("[%]%^%-%%]", "%%%0") .. "]"
    return (str:gsub("^" .. set .. "+", ""):gsub(set .. "+$", ""))
end
string.trim = strtrim

function strconcat(...) return table.concat({ ... }) end
function tostringall(...)
    local n = select("#", ...)
    local t = { ... }
    for i = 1, n do t[i] = tostring(t[i]) end
    return unpack(t, 1, n)
end

function strcmputf8i(a, b)
    a, b = a:lower(), b:lower()
    if a == b then return 0 end
    return a < b and -1 or 1
end

function Round(v) return math.floor(v + 0.5) end
function Clamp(v, lo, hi) return math.min(hi, math.max(lo, v)) end
function Lerp(a, b, t) return a + (b - a) * t end
function Saturate(v) return Clamp(v, 0, 1) end

-- Mixins (SharedXML/Mixin.lua)
function Mixin(object, ...)
    for i = 1, select("#", ...) do
        local mixin = select(i, ...)
        for k, v in pairs(mixin) do object[k] = v end
    end
    return object
end

function CreateFromMixins(...)
    return Mixin({}, ...)
end

function CreateAndInitFromMixin(mixin, ...)
    local object = CreateFromMixins(mixin)
    object:Init(...)
    return object
end

-- Secure-call helpers: no taint model here, these just call through.
function securecall(fn, ...)
    if type(fn) == "string" then fn = _G[fn] end
    return fn(...)
end
function securecallfunction(fn, ...) return fn(...) end
function secureexecuterange(t, fn, ...)
    for k, v in pairs(t) do fn(k, v, ...) end
end
function issecure() return true end
function issecurevariable() return true, nil end
function forceinsecure() end
function issecretvalue() return false end
function canaccessvalue() return true end

-- hooksecurefunc([table,] name, hook): runs hook after the original, same args.
function hooksecurefunc(tbl, name, hook)
    if type(tbl) == "string" then
        tbl, name, hook = _G, tbl, name
    end
    local orig = tbl[name]
    if type(orig) ~= "function" then
        error("hooksecurefunc(): " .. tostring(name) .. " is not a function", 2)
    end
    tbl[name] = function(...)
        local r = { orig(...) }
        hook(...)
        return unpack(r, 1, table.maxn(r))
    end
end

-- Errors: geterrorhandler() returns the function WoW reports errors through.
-- Here it goes to the emulator's error panel (and doesn't stop the caller).
local errorHandler = function(msg)
    Emu.ReportError(msg, 2)
    return msg
end
function geterrorhandler() return errorHandler end
function seterrorhandler(fn) errorHandler = fn end

function debugstack() return "" end
function debugprofilestop() return Emu.Now() * 1000 end
function debuglocals() return "" end

-- print goes to the emulator's chat log panel.
function print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    Emu.Chat(table.concat(parts, " "))
end

-- GetTime(): seconds with ms precision since the emulator "client" started.
function GetTime() return Emu.Now() end
function GetServerTime() return os.time() end
function GetTimePreciseSec() return Emu.Now() end

function GetLocale() return "enUS" end
function GetBuildInfo() return "12.0.5", "65000", "Nov 1 2026", 120005, "", "", 120005 end
function IsLoggedIn() return Emu.loggedIn end

-- Color helpers (SharedXML/Color.lua)
ColorMixin = {}
function ColorMixin:OnLoad(r, g, b, a) self:SetRGBA(r, g, b, a) end
function ColorMixin:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
function ColorMixin:SetRGB(r, g, b) self:SetRGBA(r, g, b, nil) end
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
function ColorMixin:GetRGBAsBytes()
    return math.floor(self.r * 255 + 0.5), math.floor(self.g * 255 + 0.5), math.floor(self.b * 255 + 0.5), math.floor((self.a or 1) * 255 + 0.5)
end
function ColorMixin:IsEqualTo(o) return self.r == o.r and self.g == o.g and self.b == o.b and self.a == o.a end
function ColorMixin:GenerateHexColor() return ("ff%02x%02x%02x"):format(self:GetRGBAsBytes()) end
function ColorMixin:GenerateHexColorMarkup() return "|c" .. self:GenerateHexColor() end
function ColorMixin:WrapTextInColorCode(text) return "|c" .. self:GenerateHexColor() .. text .. "|r" end

function CreateColor(r, g, b, a)
    local c = CreateFromMixins(ColorMixin)
    c:OnLoad(r, g, b, a)
    return c
end

function WrapTextInColorCode(text, colorHex) return "|c" .. colorHex .. text .. "|r" end

NORMAL_FONT_COLOR = CreateColor(1.0, 0.82, 0.0)
HIGHLIGHT_FONT_COLOR = CreateColor(1.0, 1.0, 1.0)
RED_FONT_COLOR = CreateColor(1.0, 0.1, 0.1)
GREEN_FONT_COLOR = CreateColor(0.1, 1.0, 0.1)
GRAY_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
DISABLED_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
YELLOW_FONT_COLOR = CreateColor(1.0, 1.0, 0.0)
WHITE_FONT_COLOR = CreateColor(1.0, 1.0, 1.0)
LIGHTGRAY_FONT_COLOR = CreateColor(0.6, 0.6, 0.6)
NORMAL_FONT_COLOR_CODE = "|cffffd200"
HIGHLIGHT_FONT_COLOR_CODE = "|cffffffff"
RED_FONT_COLOR_CODE = "|cffff2020"
GREEN_FONT_COLOR_CODE = "|cff20ff20"
GRAY_FONT_COLOR_CODE = "|cff808080"
FONT_COLOR_CODE_CLOSE = "|r"

-- RAID_CLASS_COLORS (values from FrameXML ColorConstants; used for class names)
do
    local classColors = {
        HUNTER = { 0.67, 0.83, 0.45, "ffaad372" }, WARLOCK = { 0.53, 0.53, 0.93, "ff8788ee" },
        PRIEST = { 1.0, 1.0, 1.0, "ffffffff" }, PALADIN = { 0.96, 0.55, 0.73, "fff48cba" },
        MAGE = { 0.25, 0.78, 0.92, "ff3fc7eb" }, ROGUE = { 1.0, 0.96, 0.41, "fffff468" },
        DRUID = { 1.0, 0.49, 0.04, "ffff7c0a" }, SHAMAN = { 0.0, 0.44, 0.87, "ff0070dd" },
        WARRIOR = { 0.78, 0.61, 0.43, "ffc69b6d" }, DEATHKNIGHT = { 0.77, 0.12, 0.23, "ffc41e3a" },
        MONK = { 0.0, 1.0, 0.6, "ff00ff98" }, DEMONHUNTER = { 0.64, 0.19, 0.79, "ffa330c9" },
        EVOKER = { 0.2, 0.58, 0.5, "ff33937f" },
    }
    RAID_CLASS_COLORS = {}
    for class, c in pairs(classColors) do
        local color = CreateColor(c[1], c[2], c[3])
        color.colorStr = c[4]
        RAID_CLASS_COLORS[class] = color
    end
end

-- Misc constants addons commonly read.
UISpecialFrames = {}
SlashCmdList = {}
MAX_PARTY_MEMBERS = 4
MAX_RAID_MEMBERS = 40
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
UNIT_NAME_FONT = "Fonts\\FRIZQT__.TTF"
DAMAGE_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
NAMEPLATE_FONT = "Fonts\\FRIZQT__.TTF"
WOW_PROJECT_MAINLINE = 1
WOW_PROJECT_ID = 1
OKAY = "Okay"
CANCEL = "Cancel"
YES = "Yes"
NO = "No"
CLOSE = "Close"
ACCEPT = "Accept"
