-- Font objects, XML templates rebuilt in Lua, and the frames the game creates itself
-- (UIParent, WorldFrame, Minimap, GameTooltip, ...). Also object pools.
--
-- Sources: Gethe/wow-ui-source (live branch, checked 2026-11-04 at commit 297d7aaaa736):
--   Blizzard_Fonts_Shared/Shared/Fonts.xml + FontStyles.xml   (font objects)
--   Blizzard_SharedXML/Backdrop.lua + NineSlice.lua            (BackdropTemplate)
--   Blizzard_SharedXML/Shared/Button/CheckButtonTemplates.xml  (UICheckButtonTemplate)
-- Re-implemented here from their documented behavior, not copied.

local Emu = __Emu
local S = Emu.S
local T = Emu.templates

---------------------------------------------------------------------------
-- Screen frames
---------------------------------------------------------------------------
local function screenFrame(name)
    local f = Emu.NewFrame("Frame", name, nil)
    local s = S[f]
    s.isScreen = true
    s.scale = 1
    s.level = 0
    return f
end

WorldFrame = screenFrame("WorldFrame")
UIParent = screenFrame("UIParent")
Emu.UIParent = UIParent
S[WorldFrame].strata = "BACKGROUND"
S[UIParent].strata = "MEDIUM"

-- Called by JS when the canvas or the UI scale changes. Absolute units: height 768.
function Emu.SetScreen(absW, absH, uiScale, pixelsPerUnit)
    Emu.screenW, Emu.screenH = absW, absH
    Emu.pixelsPerUnit = pixelsPerUnit
    S[UIParent].scale = uiScale
    Emu.Touch()
end

function GetScreenWidth() return Emu.screenW / S[UIParent].scale end
function GetScreenHeight() return Emu.screenH / S[UIParent].scale end
function GetPhysicalScreenSize() return __js("physicalScreenSize") end
function GetScreenDPIScale() return 1 end

---------------------------------------------------------------------------
-- Font objects (sizes/colors/shadows from Blizzard_Fonts_Shared, see header)
---------------------------------------------------------------------------
local FRIZ = "Fonts\\FRIZQT__.TTF"
local ARIALN = "Fonts\\ARIALN.TTF"

local function font(name, file, size, color, shadow, justifyH, flags)
    local f = CreateFont(name)
    local s = S[f]
    s.fontFile, s.fontSize, s.fontFlags = file, size, flags or ""
    s.textColor = color and { color[1], color[2], color[3], color[4] or 1 } or { 1, 1, 1, 1 }
    if shadow then
        s.shadowColor = { 0, 0, 0, 1 }
        s.shadowOffset = { 1, -1 }
    end
    s.justifyH = justifyH
    return f
end

local GOLD = { 1.0, 0.82, 0.0 }
local WHITE = { 1, 1, 1 }
local GRAY = { 0.5, 0.5, 0.5 }

font("SystemFont_Shadow_Small", FRIZ, 10, nil, true)
font("SystemFont_Shadow_Med1", FRIZ, 12, nil, true)
font("SystemFont_Shadow_Large", FRIZ, 16, nil, true)
font("SystemFont_Small", FRIZ, 10)
font("SystemFont_Med1", FRIZ, 12)
font("SystemFont_Large", FRIZ, 16)
font("GameFontNormal", FRIZ, 12, GOLD, true)
font("GameFontNormalLeft", FRIZ, 12, GOLD, true, "LEFT")
font("GameFontNormalSmall", FRIZ, 10, GOLD, true)
font("GameFontNormalSmallLeft", FRIZ, 10, GOLD, true, "LEFT")
font("GameFontHighlight", FRIZ, 12, WHITE, true)
font("GameFontHighlightLeft", FRIZ, 12, WHITE, true, "LEFT")
font("GameFontHighlightSmall", FRIZ, 10, WHITE, true)
font("GameFontHighlightSmallLeft", FRIZ, 10, WHITE, true, "LEFT")
font("GameFontHighlightSmallRight", FRIZ, 10, WHITE, true, "RIGHT")
font("GameFontDisable", FRIZ, 12, GRAY, true)
font("GameFontDisableSmall", FRIZ, 10, GRAY, true)
font("GameFontRed", FRIZ, 12, { 1, 0.1, 0.1 }, true)
font("GameFontGreen", FRIZ, 12, { 0.1, 1, 0.1 }, true)
font("GameFontNormalLarge", FRIZ, 16, GOLD, true)
font("GameFontHighlightLarge", FRIZ, 16, WHITE, true)
font("GameFontWhiteLarge", FRIZ, 16, WHITE, true)
font("GameTooltipHeaderText", FRIZ, 14, WHITE, nil, "LEFT")
font("GameTooltipText", FRIZ, 12, WHITE, nil, "LEFT")
font("GameTooltipTextSmall", FRIZ, 10, WHITE, nil, "LEFT")
font("NumberFontNormal", ARIALN, 14, WHITE, nil, nil, "OUTLINE") -- UNVERIFIED size/font
font("ChatFontNormal", ARIALN, 14, WHITE, true) -- UNVERIFIED size/font

---------------------------------------------------------------------------
-- BackdropTemplate: 4 corners + 4 edges (BORDER layer) and Center (BACKGROUND),
-- real textures stored on the frame under those keys, like in-game.
---------------------------------------------------------------------------
BackdropTemplateMixin = {}
local DEFAULT_EDGE_SIZE = 39 -- the client's fallback when edgeSize is missing/0
local PIECES = {
    { "TopLeftCorner", "TOPLEFT", corner = true },
    { "TopRightCorner", "TOPRIGHT", corner = true },
    { "BottomLeftCorner", "BOTTOMLEFT", corner = true },
    { "BottomRightCorner", "BOTTOMRIGHT", corner = true },
    { "TopEdge", "TOPLEFT", "TOPRIGHT", "TopLeftCorner", "TopRightCorner", h = true },
    { "BottomEdge", "BOTTOMLEFT", "BOTTOMRIGHT", "BottomLeftCorner", "BottomRightCorner", h = true },
    { "LeftEdge", "TOPLEFT", "BOTTOMLEFT", "TopLeftCorner", "BottomLeftCorner", v = true },
    { "RightEdge", "TOPRIGHT", "BOTTOMRIGHT", "TopRightCorner", "BottomRightCorner", v = true },
    { "Center" },
}

function BackdropTemplateMixin:GetEdgeSize()
    local e = self.backdropInfo and self.backdropInfo.edgeSize
    if e and e > 0 then return e end
    return DEFAULT_EDGE_SIZE
end

function BackdropTemplateMixin:ApplyBackdrop()
    local info = self.backdropInfo
    local edge = self:GetEdgeSize()
    local x, y, x1, y1 = 0, 0, 0, 0
    if info.bgFile then
        local ins = info.insets or {}
        x, y = -edge + (ins.left or 0), edge - (ins.top or 0)
        x1, y1 = edge - (ins.right or 0), -edge + (ins.bottom or 0)
    end
    for _, p in ipairs(PIECES) do
        local name = p[1]
        local piece = self[name]
        if not piece then
            piece = self:CreateTexture()
            self[name] = piece
            piece:SetDrawLayer(name == "Center" and "BACKGROUND" or "BORDER")
        end
        piece:ClearAllPoints()
        if p.corner then
            piece:SetPoint(p[2], self, p[2])
        elseif name == "Center" then
            piece:SetPoint("TOPLEFT", self.TopLeftCorner, "BOTTOMRIGHT", x, y)
            piece:SetPoint("BOTTOMRIGHT", self.BottomRightCorner, "TOPLEFT", x1, y1)
        else
            piece:SetPoint(p[2], self[p[4]], p[3])
            piece:SetPoint(p[3], self[p[5]], p[2])
        end
        if name == "Center" then
            piece:SetTexture(info.bgFile)
            piece:SetSize(0, 0)
        else
            piece:SetTexture(info.edgeFile)
            piece:SetSize((p.corner or p.v) and edge or 0, (p.corner or p.h) and edge or 0)
        end
    end
    self:SetBackdropColor(1, 1, 1, 1)
    self:SetBackdropBorderColor(1, 1, 1, 1)
end

function BackdropTemplateMixin:SetBackdrop(info)
    if info then
        if self.backdropInfo == info then return end
        if not info.edgeFile and not info.bgFile then
            self:ClearBackdrop()
            return
        end
        self.backdropInfo = info
        self:ApplyBackdrop()
    else
        self:ClearBackdrop()
    end
end

function BackdropTemplateMixin:ClearBackdrop()
    if not self.backdropInfo then return end
    for _, p in ipairs(PIECES) do
        if self[p[1]] then self[p[1]]:SetTexture(nil) end
    end
    self.backdropInfo = nil
end

function BackdropTemplateMixin:GetBackdrop()
    if not self.backdropInfo then return nil end
    local b = CopyTable(self.backdropInfo)
    b.bgFile = b.bgFile or ""
    b.edgeFile = b.edgeFile or ""
    if b.tile == nil then b.tile = false end
    b.tileSize = b.tileSize or 0
    if b.tileEdge == nil then b.tileEdge = true end
    b.edgeSize = b.edgeSize or self:GetEdgeSize()
    b.insets = b.insets or {}
    for _, k in ipairs({ "left", "right", "top", "bottom" }) do b.insets[k] = b.insets[k] or 0 end
    return b
end

function BackdropTemplateMixin:SetBackdropColor(r, g, b, a)
    if not self.backdropInfo then return end
    if self.Center then self.Center:SetVertexColor(r, g, b, a or 1) end
end
function BackdropTemplateMixin:GetBackdropColor()
    if self.backdropInfo and self.Center then return self.Center:GetVertexColor() end
end
function BackdropTemplateMixin:SetBackdropBorderColor(r, g, b, a)
    if not self.backdropInfo then return end
    for _, p in ipairs(PIECES) do
        local piece = self[p[1]]
        if piece and p[1] ~= "Center" then piece:SetVertexColor(r, g, b, a or 1) end
    end
end
function BackdropTemplateMixin:GetBackdropBorderColor()
    if not self.backdropInfo then return end
    for _, p in ipairs(PIECES) do
        local piece = self[p[1]]
        if piece and p[1] ~= "Center" then return piece:GetVertexColor() end
    end
end
function BackdropTemplateMixin:SetBorderBlendMode(mode)
    if not self.backdropInfo then return end
    for _, p in ipairs(PIECES) do
        local piece = self[p[1]]
        if piece and p[1] ~= "Center" then piece:SetBlendMode(mode) end
    end
end
function BackdropTemplateMixin:HasBackdropInfo(info) return self.backdropInfo == info end
function BackdropTemplateMixin:OnBackdropLoaded()
    if self.backdropInfo then
        local info = self.backdropInfo
        self.backdropInfo = nil
        self:SetBackdrop(info)
    end
end
function BackdropTemplateMixin:OnBackdropSizeChanged() end
function BackdropTemplateMixin:SetupTextureCoordinates() end

T.BackdropTemplate = function(f)
    Mixin(f, BackdropTemplateMixin)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
T.UICheckButtonArtTemplate = function(f)
    f:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    f:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    f:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    f:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    f:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
end

T.UICheckButtonTemplate = function(f)
    T.UICheckButtonArtTemplate(f)
    f:SetSize(32, 32)
    local name = f:GetName()
    local text = f:CreateFontString(name and (name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", f, "RIGHT", -2, 0)
    f.Text = text
    f.text = text
end

-- Secure buttons: the protected click action isn't run; it's logged to the page instead.
T.SecureActionButtonTemplate = function(f)
    f:SetScript("OnClick", function(self, button, down)
        local attrs = S[self].attributes
        local parts = {}
        for _, k in ipairs({ "type", "item", "spell", "macrotext", "unit" }) do
            if attrs[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(attrs[k]):gsub("\n", "\\n") end
        end
        __js("secure", ("%s %s%s: %s"):format(Emu.DebugName(self), button or "LeftButton", down and " (down)" or "",
            #parts > 0 and table.concat(parts, ", ") or "(no action)"))
    end)
end
T.SecureHandlerBaseTemplate = function() end
T.SecureHandlerStateTemplate = function() end
T.SecureHandlerClickTemplate = function() end

-- Below: simplified stand-ins (look is a placeholder, structure follows the client's keys).
T.UIPanelButtonTemplate = function(f)
    f:SetSize(f:GetWidth() > 0 and f:GetWidth() or 80, f:GetHeight() > 0 and f:GetHeight() or 22)
    f:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    f:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
    f:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    f:SetFontString(text)
    f.Text = text
    f:SetNormalFontObject(GameFontNormal)
end

T.InputBoxTemplate = function(f)
    f:SetFontObject(ChatFontNormal)
    local left = f:CreateTexture(nil, "BACKGROUND")
    left:SetColorTexture(0, 0, 0, 0.5)
    left:SetAllPoints()
    f.Left = left
end

T.UIPanelScrollFrameTemplate = function(f)
    local name = f:GetName()
    local bar = CreateFrame("Slider", name and (name .. "ScrollBar") or nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPRIGHT", 6, -16)
    bar:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 6, 16)
    bar:SetWidth(16)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(self, value) f:SetVerticalScroll(value) end)
    f.ScrollBar = bar
end

---------------------------------------------------------------------------
-- GameTooltip
---------------------------------------------------------------------------
-- Look: placeholder (dark blue background, thin gray border); layout simplified.
-- UNVERIFIED: default colors of SetText/AddLine without a color (here: white / gold),
-- padding and the wrap width (here: 10 / 300).
local TOOLTIP_PAD = 10
local TOOLTIP_WRAP_WIDTH = 300

local Tooltip = Emu.Class.GameTooltip

local function tooltipLine(tt, i, side)
    local key = side .. i
    local lines = S[tt].ttLines
    if not lines[key] then
        local name = tt:GetName()
        local fs = tt:CreateFontString(name and (name .. "Text" .. (side == "L" and "Left" or "Right") .. i) or nil, "ARTWORK",
            i == 1 and "GameTooltipHeaderText" or "GameTooltipText")
        lines[key] = fs
    end
    return lines[key]
end

function Tooltip:SetOwner(owner, anchor, x, y)
    local s = S[self]
    s.ttOwner, s.ttAnchor, s.ttX, s.ttY = owner, anchor or "ANCHOR_LEFT", x or 0, y or 0
    self:ClearLines()
end
function Tooltip:GetOwner() return S[self].ttOwner end
function Tooltip:IsOwned(f) return S[self].ttOwner == f end
function Tooltip:SetAnchorType(anchor, x, y) S[self].ttAnchor, S[self].ttX, S[self].ttY = anchor, x or 0, y or 0 end
function Tooltip:GetAnchorType() return S[self].ttAnchor end
function Tooltip:ClearLines()
    local s = S[self]
    s.ttCount = 0
    for _, fs in pairs(s.ttLines) do fs:Hide() fs:SetText(nil) end
    Emu.Touch()
end
function Tooltip:NumLines() return S[self].ttCount end

local function addLine(self, left, right, lr, lg, lb, rr, rg, rb, wrap)
    local s = S[self]
    s.ttCount = s.ttCount + 1
    local i = s.ttCount
    local fs = tooltipLine(self, i, "L")
    fs:SetText(left and tostring(left) or "")
    fs:SetTextColor(lr, lg, lb)
    fs:Show()
    S[fs].ttWrap = wrap and true or false
    if right then
        local rfs = tooltipLine(self, i, "R")
        rfs:SetText(tostring(right))
        rfs:SetTextColor(rr, rg, rb)
        rfs:Show()
    end
    if self:IsShown() then self:Show() end
end

function Tooltip:SetText(text, r, g, b, a, wrap)
    self:ClearLines()
    addLine(self, text, nil, r or 1, g or 1, b or 1, nil, nil, nil, wrap)
end
function Tooltip:AddLine(text, r, g, b, wrap)
    addLine(self, text, nil, r or 1, g or 0.82, b or 0, nil, nil, nil, wrap)
end
function Tooltip:AddDoubleLine(l, rt, lr, lg, lb, rr, rg, rb)
    addLine(self, l, rt, lr or 1, lg or 0.82, lb or 0, rr or 1, rg or 0.82, rb or 0, false)
end
function Tooltip:AddTexture() end
function Tooltip:SetPadding() end
function Tooltip:SetMinimumWidth(w) S[self].ttMinWidth = w end
function Tooltip:FadeOut() self:Hide() end
function Tooltip:AppendText(t)
    local s = S[self]
    local fs = s.ttLines["L" .. s.ttCount]
    if fs then fs:SetText((fs:GetText() or "") .. t) end
end
for _, m in ipairs({ "SetSpellByID", "SetItemByID", "SetInventoryItem", "SetBagItem", "SetUnitAura",
    "SetUnitAuraByAuraInstanceID", "SetUnitBuff", "SetHyperlink", "SetUnit", "SetAction", "SetMountBySpellID",
    "SetCurrencyByID", "SetToyByItemID", "SetSpellBookItem", "SetTalent" }) do
    Tooltip[m] = function(self, ...)
        self:ClearLines()
        addLine(self, ("[%s %s]"):format(m, tostring((...))), nil, 1, 1, 1)
        __js("stub", "GameTooltip:" .. m .. " (shows a placeholder line)")
    end
end

local frameShow = Emu.Class.Frame.Show
function Tooltip:Show()
    local s = S[self]
    -- Width: widest non-wrapping line; wrapping lines are wrapped to max(that, 300).
    local widest = s.ttMinWidth or 0
    for i = 1, s.ttCount do
        local l, r = s.ttLines["L" .. i], s.ttLines["R" .. i]
        local w = l:GetUnboundedStringWidth() + (r and r:IsShown() and (r:GetUnboundedStringWidth() + 20) or 0)
        if not S[l].ttWrap then widest = math.max(widest, w) end
    end
    local wrapWidth = math.max(widest, TOOLTIP_WRAP_WIDTH)
    for i = 1, s.ttCount do
        local l = s.ttLines["L" .. i]
        if S[l].ttWrap then
            widest = math.max(widest, math.min(l:GetUnboundedStringWidth(), wrapWidth))
        end
    end
    local y = -TOOLTIP_PAD
    for i = 1, s.ttCount do
        local l, r = s.ttLines["L" .. i], s.ttLines["R" .. i]
        l:ClearAllPoints()
        l:SetPoint("TOPLEFT", self, "TOPLEFT", TOOLTIP_PAD, y)
        l:SetWidth(S[l].ttWrap and widest or 0)
        l:SetJustifyH("LEFT")
        if r and r:IsShown() then
            r:ClearAllPoints()
            r:SetPoint("TOPRIGHT", self, "TOPRIGHT", -TOOLTIP_PAD, y)
        end
        y = y - l:GetHeight() - 2
    end
    self:SetSize(widest + 2 * TOOLTIP_PAD, -y + TOOLTIP_PAD - 2)

    local owner, anchor = s.ttOwner, s.ttAnchor
    if owner and anchor ~= "ANCHOR_NONE" and anchor ~= "ANCHOR_PRESERVE" then
        self:ClearAllPoints()
        local x, yy = s.ttX or 0, s.ttY or 0
        if anchor == "ANCHOR_RIGHT" then self:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", x, yy)
        elseif anchor == "ANCHOR_LEFT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", x, yy)
        elseif anchor == "ANCHOR_TOP" then self:SetPoint("BOTTOM", owner, "TOP", x, yy)
        elseif anchor == "ANCHOR_BOTTOM" then self:SetPoint("TOP", owner, "BOTTOM", x, yy)
        elseif anchor == "ANCHOR_TOPLEFT" then self:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", x, yy)
        elseif anchor == "ANCHOR_TOPRIGHT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", x, yy)
        elseif anchor == "ANCHOR_BOTTOMLEFT" then self:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", x, yy)
        elseif anchor == "ANCHOR_BOTTOMRIGHT" then self:SetPoint("TOPLEFT", owner, "BOTTOMRIGHT", x, yy)
        elseif anchor == "ANCHOR_CURSOR" or anchor == "ANCHOR_CURSOR_RIGHT" then
            local sc = Emu.EffectiveScale(self)
            self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", Emu.mouseX / sc + 10 + x, Emu.mouseY / sc + 10 + yy)
        else self:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", x, yy) end
    end
    frameShow(self)
end

T.GameTooltipTemplate = function(f)
    local s = S[f]
    s.ttLines, s.ttCount = {}, 0
    Mixin(f, BackdropTemplateMixin)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.09, 0.09, 0.19, 0.95)
    f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    f:SetFrameStrata("TOOLTIP")
    f:SetClampedToScreen(true)
    f:Hide()
end

GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent, "GameTooltipTemplate")
ItemRefTooltip = CreateFrame("GameTooltip", "ItemRefTooltip", UIParent, "GameTooltipTemplate")
function GameTooltip_Hide() GameTooltip:Hide() end
function GameTooltip_SetDefaultAnchor(tt, parent)
    tt:SetOwner(parent, "ANCHOR_NONE")
    tt:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -100, 100)
end

---------------------------------------------------------------------------
-- Other frames the game provides
---------------------------------------------------------------------------
-- Minimap: an invisible stand-in at the top right (the map itself isn't drawn).
Minimap = CreateFrame("Minimap", "Minimap", UIParent)
Minimap:SetSize(198, 198)
Minimap:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -40)
MinimapCluster = CreateFrame("Frame", "MinimapCluster", UIParent)
MinimapCluster:SetAllPoints(Minimap)
function GetMinimapShape() return "ROUND" end

AddonCompartmentFrame = CreateFrame("Frame", "AddonCompartmentFrame", UIParent)
AddonCompartmentFrame.registeredAddons = {}
function AddonCompartmentFrame:RegisterAddon(info) table.insert(self.registeredAddons, info) end
function AddonCompartmentFrame:UpdateDisplay() end

ChatFrame1 = CreateFrame("Frame", "ChatFrame1", UIParent)
function ChatFrame1:AddMessage(text) Emu.Chat(tostring(text)) end
DEFAULT_CHAT_FRAME = ChatFrame1
SELECTED_CHAT_FRAME = ChatFrame1

---------------------------------------------------------------------------
-- Object pools (SharedXML Pools)
---------------------------------------------------------------------------
local Pool = {}
Pool.__index = Pool

function Pool:Acquire()
    local obj = table.remove(self.inactive)
    local isNew = false
    if not obj then
        obj = self.creator(self)
        isNew = true
    end
    self.active[obj] = true
    self.numActive = self.numActive + 1
    return obj, isNew
end
function Pool:Release(obj)
    if not self.active[obj] then return false end
    self.active[obj] = nil
    self.numActive = self.numActive - 1
    if self.resetter then self.resetter(self, obj, false) end
    table.insert(self.inactive, obj)
    return true
end
function Pool:ReleaseAll()
    for obj in pairs(self.active) do self:Release(obj) end
end
function Pool:EnumerateActive() return pairs(self.active) end
function Pool:EnumerateInactive() return ipairs(self.inactive) end
function Pool:GetNumActive() return self.numActive end
function Pool:IsActive(obj) return self.active[obj] or false end
function Pool:GetNextActive(current) return next(self.active, current) end

local function hideAndClear(_, obj)
    obj:Hide()
    obj:ClearAllPoints()
end

function CreateObjectPool(creator, resetter)
    return setmetatable({ creator = creator, resetter = resetter, active = {}, inactive = {}, numActive = 0 }, Pool)
end
function CreateTexturePool(parent, layer, subLayer, template, resetter)
    return CreateObjectPool(function()
        return parent:CreateTexture(nil, layer, template, subLayer)
    end, resetter or hideAndClear)
end
function CreateFontStringPool(parent, layer, subLayer, template, resetter)
    return CreateObjectPool(function()
        return parent:CreateFontString(nil, layer, template)
    end, resetter or hideAndClear)
end
function CreateFramePool(frameType, parent, template, resetter)
    return CreateObjectPool(function()
        return CreateFrame(frameType, nil, parent, template)
    end, resetter or hideAndClear)
end
function CreateMaskTexturePool(parent, layer, subLayer, template, resetter)
    return CreateObjectPool(function()
        return parent:CreateMaskTexture(nil, layer, template, subLayer)
    end, resetter or hideAndClear)
end
Pool_HideAndClearAnchors = hideAndClear
FramePool_HideAndClearAnchors = hideAndClear

-- Frame/UI helpers from FrameXML that addons call directly.
function ShowUIPanel(f) if f then f:Show() end end
function HideUIPanel(f) if f then f:Hide() end end
function CloseSpecialWindows()
    local closed = false
    for _, name in ipairs(UISpecialFrames) do
        local f = _G[name]
        if f and f:IsShown() then f:Hide() closed = true end
    end
    return closed
end
function PlaySound() return true end
function PlaySoundFile() return true end
function StopSound() end
