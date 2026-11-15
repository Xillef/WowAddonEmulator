-- Widget objects (Region / Frame / Texture / FontString / Button / AnimationGroup ...)
-- and the anchor layout engine.
--
-- Objects are plain Lua tables like in WoW (addons put their own fields on them).
-- The emulator's internal state lives in a separate table S[obj], so it never shows
-- up in the addon's own fields.
--
-- Coordinates: "absolute" units have a screen height of 768 (WoW's base coordinate
-- space). A region's own units are absolute / effectiveScale. y grows upwards.

local Emu = __Emu
local S = {}
Emu.S = S

local Class = {}
Emu.Class = Class
-- Replaced by stubs.lua (logged stubs for real-but-unemulated methods).
function Emu.MissingMethod() return nil end
local metas = {}
Emu.metas = metas

local function define(name, parentName)
    local methods = setmetatable({}, parentName and { __index = Class[parentName] } or nil)
    Class[name] = methods
    metas[name] = {
        __index = function(_, k)
            local v = methods[k]
            if v ~= nil then return v end
            return Emu.MissingMethod(name, k)
        end,
        __tostring = function(o) return name .. ": " .. (S[o] and S[o].name or "(anonymous)") end,
    }
    return methods
end
Emu.DefineClass = define

local creationCounter = 0
local function newObject(className, state)
    creationCounter = creationCounter + 1
    state.id = creationCounter
    state.objectType = className
    local o = setmetatable({ [0] = newproxy() }, metas[className])
    S[o] = state
    return o
end
Emu.NewObject = newObject

-- Any visual change: re-render on the next opportunity and drop cached rects.
local layoutGen = 0
local function touch()
    layoutGen = layoutGen + 1
    Emu.dirty = true
end
Emu.Touch = touch

local POINTS = {
    TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
    LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
    BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}
Emu.POINTS = POINTS

local STRATA = { "WORLD", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local STRATA_INDEX = {}
for i, v in ipairs(STRATA) do STRATA_INDEX[v] = i end
Emu.STRATA_INDEX = STRATA_INDEX

local LAYERS = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
Emu.LAYERS = LAYERS

local function resolveObject(v)
    if type(v) == "string" then return _G[v] end
    return v
end

local function argError(level, fmt, ...)
    error(fmt:format(...), level + 1)
end

---------------------------------------------------------------------------
-- Object (every widget)
---------------------------------------------------------------------------
local Object = define("Object")

function Object:GetName() return S[self].name end
function Object:GetDebugName() return S[self].name or tostring(self) end
function Object:GetObjectType() return S[self].objectType end
function Object:IsObjectType(t)
    local mt = Class[S[self].objectType]
    while mt do
        if Class[t] == mt then return true end
        local m = getmetatable(mt)
        mt = m and m.__index
    end
    return false
end
function Object:GetParent() return S[self].parent end
function Object:IsForbidden() return false end
function Object:SetForbidden() end
function Object:GetParentKey() return S[self].parentKey end
function Object:SetParentKey(key)
    local p = S[self].parent
    S[self].parentKey = key
    if p then p[key] = self end
end
function Object:ClearParentKey() S[self].parentKey = nil end
function Object:HasAnySecretAspect() return false end
function Object:HasSecretAspect() return false end
function Object:HasSecretValues() return false end

---------------------------------------------------------------------------
-- Region (everything with a position)
---------------------------------------------------------------------------
local Region = define("Region", "Object")

function Region:SetPoint(point, a, b, c, d)
    local s = S[self]
    if type(point) ~= "string" or not POINTS[point:upper()] then
        argError(2, "%s:SetPoint(): Invalid region point '%s'", s.objectType, tostring(point))
    end
    point = point:upper()
    local rel, relPoint, x, y
    if type(a) == "number" or a == nil and b == nil then
        -- SetPoint(point [, x, y])
        x, y = a, b
    elseif type(b) == "number" or b == nil and c == nil then
        -- SetPoint(point, relativeTo, x, y)  (relativePoint defaults to point)
        rel, x, y = a, b, c
    else
        rel, relPoint, x, y = a, b, c, d
    end
    if rel ~= nil then
        rel = resolveObject(rel)
        if type(rel) ~= "table" or not S[rel] then
            argError(2, "%s:SetPoint(): Couldn't find region named '%s'", s.objectType, tostring(a))
        end
        if rel == self then argError(2, "%s:SetPoint(): Cannot anchor to itself", s.objectType) end
    end
    relPoint = relPoint and relPoint:upper() or point
    if not POINTS[relPoint] then
        argError(2, "%s:SetPoint(): Invalid relative point '%s'", s.objectType, tostring(relPoint))
    end
    local pts = s.points
    local entry = { point = point, rel = rel, relPoint = relPoint, x = x or 0, y = y or 0 }
    for i = 1, #pts do
        if pts[i].point == point then
            pts[i] = entry
            touch()
            return
        end
    end
    pts[#pts + 1] = entry
    touch()
end

function Region:SetAllPoints(rel, doResize)
    if rel == true or rel == nil then rel = S[self].parent end
    rel = resolveObject(rel)
    S[self].points = {}
    if rel then
        self:SetPoint("TOPLEFT", rel, "TOPLEFT", 0, 0)
        self:SetPoint("BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0)
    end
    touch()
end

function Region:ClearAllPoints()
    S[self].points = {}
    touch()
end

function Region:ClearPoint(point)
    local pts = S[self].points
    for i = #pts, 1, -1 do
        if pts[i].point == point then table.remove(pts, i) end
    end
    touch()
end

function Region:ClearPointsOffset()
    for _, p in ipairs(S[self].points) do p.x, p.y = 0, 0 end
    touch()
end

function Region:AdjustPointsOffset(dx, dy)
    for _, p in ipairs(S[self].points) do p.x, p.y = p.x + dx, p.y + dy end
    touch()
end

function Region:GetNumPoints() return #S[self].points end

function Region:GetPoint(i)
    local p = S[self].points[i or 1]
    if not p then return nil end
    return p.point, p.rel, p.relPoint, p.x, p.y
end
Region.GetPointByName = function(self, name)
    for _, p in ipairs(S[self].points) do
        if p.point == name then return p.point, p.rel, p.relPoint, p.x, p.y end
    end
end

function Region:SetSize(w, h)
    local s = S[self]
    s.width, s.height = w, h or w
    touch()
end
function Region:SetWidth(w) S[self].width = w; touch() end
function Region:SetHeight(h) S[self].height = h; touch() end

function Region:SetScale(scale)
    if not scale or scale <= 0 then argError(2, "%s:SetScale(): Scale must be > 0", S[self].objectType) end
    S[self].scale = scale
    touch()
end
function Region:GetScale() return S[self].scale or 1 end
function Region:SetIgnoreParentScale(v) S[self].ignoreParentScale = v and true or nil; touch() end
function Region:IsIgnoringParentScale() return S[self].ignoreParentScale or false end
function Region:SetIgnoreParentAlpha(v) S[self].ignoreParentAlpha = v and true or nil; touch() end
function Region:IsIgnoringParentAlpha() return S[self].ignoreParentAlpha or false end

local function effectiveScale(o)
    local s = S[o]
    local scale = s.scale or 1
    if s.isScreen then return scale end
    if s.ignoreParentScale then return scale end
    local p = s.parent
    if p then return scale * effectiveScale(p) end
    return scale * S[Emu.UIParent].scale -- unparented regions use UIParent's scale (UNVERIFIED)
end
Emu.EffectiveScale = effectiveScale
function Region:GetEffectiveScale() return effectiveScale(self) end

-- Width/height a region has without anchors stretching it: explicit size, or the
-- natural text size for a FontString without an explicit size.
local function axis(lo, hi, mid, size)
    if lo and hi then return lo, hi - lo end
    if lo then
        if size then return lo, size end
        if mid then return lo, 2 * (mid - lo) end
        return lo, 0
    end
    if hi then
        if size then return hi - size, size end
        if mid then return 2 * mid - hi, 2 * (hi - mid) end
        return hi, 0
    end
    if mid then
        size = size or 0
        return mid - size / 2, size
    end
end

-- Absolute rect: left, bottom, width, height (nil if it can't be resolved).
-- Per axis, edge anchors (LEFT/RIGHT, TOP/BOTTOM) win over center anchors when both
-- are present, then the explicit size, then the center anchor. (UNVERIFIED how the
-- client resolves over-constrained anchors; this matches the observed results.)
local function absRect(o)
    local s = S[o]
    if s.rectGen == layoutGen then
        if s.rectNil then return nil end
        return s.rl, s.rb, s.rw, s.rh
    end
    if s.isScreen then
        s.rectGen, s.rectNil = layoutGen, false
        s.rl, s.rb, s.rw, s.rh = 0, 0, Emu.screenW, Emu.screenH
        return 0, 0, Emu.screenW, Emu.screenH
    end
    if s.resolving then return nil end -- anchor cycle
    s.resolving = true
    local scale = effectiveScale(o)
    local L, R, CX, T, B, CY
    local ok = #s.points > 0
    for _, p in ipairs(s.points) do
        local rel = p.rel or s.parent or Emu.UIParent
        local rl, rb, rw, rh = absRect(rel)
        if not rl then ok = false break end
        local rf, f = POINTS[p.relPoint], POINTS[p.point]
        local x = rl + rf[1] * rw + p.x * scale
        local y = rb + rf[2] * rh + p.y * scale
        if f[1] == 0 then L = x elseif f[1] == 1 then R = x else CX = x end
        if f[2] == 0 then B = y elseif f[2] == 1 then T = y else CY = y end
    end
    local left, bottom, w, h
    if ok then
        local width = s.width and s.width > 0 and s.width * scale or nil
        if not width and s.objectType == "FontString" and not (L and R) then
            width = Emu.FontStringNaturalWidth(o) * scale
        end
        left, w = axis(L, R, CX, width)
        local height = s.height and s.height > 0 and s.height * scale or nil
        if not height and s.objectType == "FontString" and not (T and B) then
            height = Emu.FontStringNaturalHeight(o, w / scale) * scale
        end
        bottom, h = axis(B, T, CY, height)
        if not left or not bottom then ok = false end
    end
    s.resolving = false
    s.rectGen = layoutGen
    s.rectNil = not ok
    if not ok then return nil end
    s.rl, s.rb, s.rw, s.rh = left, bottom, w, h
    return left, bottom, w, h
end
Emu.AbsRect = absRect

function Region:GetRect()
    local l, b, w, h = absRect(self)
    if not l then return nil end
    local sc = effectiveScale(self)
    return l / sc, b / sc, w / sc, h / sc
end
function Region:GetLeft() local l = absRect(self) return l and l / effectiveScale(self) end
function Region:GetBottom() local _, b = absRect(self) return b and b / effectiveScale(self) end
function Region:GetRight()
    local l, _, w = absRect(self)
    return l and (l + w) / effectiveScale(self)
end
function Region:GetTop()
    local _, b, _, h = absRect(self)
    return b and (b + h) / effectiveScale(self)
end
function Region:GetCenter()
    local l, b, w, h = absRect(self)
    if not l then return nil end
    local sc = effectiveScale(self)
    return (l + w / 2) / sc, (b + h / 2) / sc
end
function Region:GetScaledRect() return absRect(self) end
function Region:IsRectValid() return absRect(self) ~= nil end
function Region:IsAnchoringRestricted() return false end
function Region:IsProtected() return false, false end
function Region:CanChangeProtectedState() return true end
function Region:IsDragging() return Emu.dragging == self end

-- GetWidth/GetHeight: the resolved size if anchors resolve, else the explicit size.
function Region:GetWidth()
    local l, _, w = absRect(self)
    if l then return w / effectiveScale(self) end
    local s = S[self]
    if s.width then return s.width end
    if s.objectType == "FontString" then return Emu.FontStringNaturalWidth(self) end
    return 0
end
function Region:GetHeight()
    local l, _, _, h = absRect(self)
    if l then return h / effectiveScale(self) end
    local s = S[self]
    if s.height then return s.height end
    if s.objectType == "FontString" then return Emu.FontStringNaturalHeight(self) end
    return 0
end
function Region:GetSize() return self:GetWidth(), self:GetHeight() end

-- Visibility -------------------------------------------------------------
local function isVisible(o)
    local s = S[o]
    while s do
        if not s.shown then return false end
        if s.isScreen then return true end
        local p = s.parent
        if not p then return true end
        s = S[p]
    end
    return true
end
Emu.IsVisible = isVisible

function Region:IsShown() return S[self].shown end
function Region:IsVisible() return isVisible(self) end

-- Fires OnShow/OnHide on o and on its shown descendant frames whose visibility changed.
local function propagateVisibility(o, visible)
    local s = S[o]
    if s.isFrame then
        Emu.RunScript(o, visible and "OnShow" or "OnHide")
        for _, child in ipairs(s.children) do
            if S[child].shown then propagateVisibility(child, visible) end
        end
        if not visible and Emu.OnFrameHidden then Emu.OnFrameHidden(o) end
    end
end

function Region:Show()
    local s = S[self]
    if s.shown then return end
    local parentVisible = not s.parent or isVisible(s.parent)
    s.shown = true
    touch()
    if parentVisible then propagateVisibility(self, true) end
end

function Region:Hide()
    local s = S[self]
    if not s.shown then return end
    local wasVisible = isVisible(self)
    s.shown = false
    touch()
    if wasVisible then propagateVisibility(self, false) end
end

function Region:SetShown(v)
    if v then self:Show() else self:Hide() end
end

-- Alpha ------------------------------------------------------------------
function Region:SetAlpha(a)
    S[self].alpha = math.max(0, math.min(1, tonumber(a) or 1))
    touch()
end
function Region:GetAlpha() return S[self].animAlpha or S[self].alpha end

local function effectiveAlpha(o)
    local s = S[o]
    local a = s.animAlpha or s.alpha
    if s.ignoreParentAlpha or not s.parent or s.isScreen then return a end
    return a * effectiveAlpha(s.parent)
end
Emu.EffectiveAlpha = effectiveAlpha
function Region:GetEffectiveAlpha() return effectiveAlpha(self) end

function Region:SetParent(parent)
    local s = S[self]
    parent = resolveObject(parent)
    if s.parent == parent then return end
    local old = s.parent
    if old and S[old].isFrame then
        local list = s.isFrame and S[old].children or S[old].regions
        for i = #list, 1, -1 do
            if list[i] == self then table.remove(list, i) end
        end
    end
    s.parent = parent
    if parent then
        local ps = S[parent]
        if s.isFrame then
            table.insert(ps.children, self)
            if not s.levelSet then s.level = (ps.level or 0) + 1 end
        else
            table.insert(ps.regions, self)
        end
    end
    touch()
end

function Region:IsMouseOver(top, bottom, left, right)
    local l, b, w, h = absRect(self)
    if not l or not isVisible(self) then return false end
    local sc = effectiveScale(self)
    local mx, my = Emu.mouseX, Emu.mouseY
    return mx >= l - (left or 0) * sc and mx <= l + w + (right or 0) * sc
        and my >= b - (bottom or 0) * sc and my <= b + h + (top or 0) * sc
end
function Region:IsMouseMotionFocus() return Emu.hovered == self end

-- Animations -------------------------------------------------------------
function Region:CreateAnimationGroup(name, template)
    local s = S[self]
    local ag = newObject("AnimationGroup", {
        name = name, parent = self, animations = {}, looping = "NONE", scripts = {},
        playing = false, elapsed = 0, speed = 1,
    })
    s.animGroups = s.animGroups or {}
    table.insert(s.animGroups, ag)
    if name then _G[name] = ag end
    return ag
end
function Region:GetAnimationGroups()
    return unpack(S[self].animGroups or {})
end
function Region:StopAnimating()
    for _, ag in ipairs(S[self].animGroups or {}) do ag:Stop() end
end

---------------------------------------------------------------------------
-- Layered regions: Texture, FontString, MaskTexture, Line
---------------------------------------------------------------------------
local Layered = define("LayeredRegion", "Region")

function Layered:SetDrawLayer(layer, sublevel)
    local s = S[self]
    if layer and not LAYERS[layer] then argError(2, "%s:SetDrawLayer(): Invalid layer '%s'", s.objectType, tostring(layer)) end
    s.layer = layer or s.layer
    s.sublevel = sublevel or 0
    touch()
end
function Layered:GetDrawLayer() return S[self].layer, S[self].sublevel end

function Layered:SetVertexColor(r, g, b, a)
    S[self].vertex = { r or 1, g or 1, b or 1, a or 1 }
    touch()
end
function Layered:GetVertexColor()
    local v = S[self].vertex
    if not v then return 1, 1, 1, 1 end
    return v[1], v[2], v[3], v[4]
end

local function newRegion(className, parent, name, layer, sublevel)
    local s = {
        parent = parent, points = {}, shown = true, alpha = 1,
        layer = layer or "ARTWORK", sublevel = sublevel or 0,
    }
    if name and parent then name = name:gsub("%$parent", S[parent].name or "") end
    s.name = name
    local o = newObject(className, s)
    if parent then table.insert(S[parent].regions, o) end
    if name then _G[name] = o end
    touch()
    return o
end
Emu.NewRegion = newRegion

-- Texture ---------------------------------------------------------------
local TextureBase = define("TextureBase", "LayeredRegion")
local Texture = define("Texture", "TextureBase")

function TextureBase:SetTexture(file, wrapH, wrapV, filter)
    local s = S[self]
    s.color, s.atlas, s.gradient = nil, nil, nil
    if file == nil or file == "" then
        s.file = nil
    else
        s.file = file
    end
    touch()
    return true
end
function TextureBase:GetTexture() return S[self].file or S[self].atlas end
function TextureBase:GetTextureFileID() local f = S[self].file return type(f) == "number" and f or nil end
function TextureBase:GetTextureFilePath() local f = S[self].file return type(f) == "string" and f or nil end

function TextureBase:SetColorTexture(r, g, b, a)
    local s = S[self]
    s.file, s.atlas, s.gradient = nil, nil, nil
    s.color = { r or 1, g or 1, b or 1, a or 1 }
    touch()
end

function TextureBase:SetAtlas(atlas, useAtlasSize, filter, resetTexCoords)
    local s = S[self]
    s.file, s.color, s.gradient = nil, nil, nil
    s.atlas = atlas
    if useAtlasSize then
        local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
        if info and info.width then s.width, s.height = info.width, info.height end
    end
    touch()
    return true
end
function TextureBase:GetAtlas() return S[self].atlas end

function TextureBase:SetTexCoord(...)
    local n = select("#", ...)
    local s = S[self]
    if n == 4 then
        local l, r, t, b = ...
        s.texCoord = { l, r, t, b }
    elseif n == 8 then
        local ulx, uly, llx, lly, urx, ury, lrx, lry = ...
        s.texCoord = { ulx, lrx, uly, lry }
    else
        argError(2, "Texture:SetTexCoord(): Usage: (left, right, top, bottom) or 8 coordinates")
    end
    touch()
end
function TextureBase:GetTexCoord()
    local c = S[self].texCoord or { 0, 1, 0, 1 }
    return c[1], c[3], c[1], c[4], c[2], c[3], c[2], c[4]
end

function TextureBase:SetDesaturated(v) S[self].desaturation = v and 1 or 0; touch() end
function TextureBase:SetDesaturation(v) S[self].desaturation = v or 0; touch() end
function TextureBase:IsDesaturated() return (S[self].desaturation or 0) > 0 end
function TextureBase:GetDesaturation() return S[self].desaturation or 0 end
function TextureBase:SetBlendMode(mode) S[self].blend = mode; touch() end
function TextureBase:GetBlendMode() return S[self].blend or "BLEND" end
function TextureBase:SetRotation(rad, origin) S[self].rotation = rad; touch() end
function TextureBase:GetRotation() return S[self].rotation or 0 end
function TextureBase:SetHorizTile() end
function TextureBase:SetVertTile() end
function TextureBase:SetSnapToPixelGrid() end
function TextureBase:SetTexelSnappingBias() end

-- SetGradient(orientation, minColor, maxColor): color objects (ColorMixin).
function TextureBase:SetGradient(orientation, minColor, maxColor)
    local s = S[self]
    s.gradient = {
        orientation = orientation,
        { minColor.r, minColor.g, minColor.b, minColor.a or 1 },
        { maxColor.r, maxColor.g, maxColor.b, maxColor.a or 1 },
    }
    touch()
end

function Texture:AddMaskTexture(mask)
    local s = S[self]
    s.masks = s.masks or {}
    table.insert(s.masks, mask)
end
function Texture:RemoveMaskTexture(mask)
    local masks = S[self].masks or {}
    for i = #masks, 1, -1 do if masks[i] == mask then table.remove(masks, i) end end
end
function Texture:GetNumMaskTextures() return #(S[self].masks or {}) end
function Texture:GetMaskTexture(i) return (S[self].masks or {})[i] end

define("MaskTexture", "TextureBase")
local Line = define("Line", "TextureBase")
function Line:SetStartPoint(relPoint, rel, x, y) S[self].lineStart = { relPoint, resolveObject(rel), x or 0, y or 0 }; touch() end
function Line:SetEndPoint(relPoint, rel, x, y) S[self].lineEnd = { relPoint, resolveObject(rel), x or 0, y or 0 }; touch() end
function Line:SetThickness(t) S[self].thickness = t; touch() end
function Line:GetThickness() return S[self].thickness or 1 end

-- Font / FontString -----------------------------------------------------
-- Font state shared by Font objects and FontStrings. A FontString inherits from its
-- font object until it sets a value itself (SetFont/SetTextColor/...), like in-game.
local FONT_FIELDS = { "fontFile", "fontSize", "fontFlags", "textColor", "shadowColor", "shadowOffset", "justifyH", "justifyV", "spacing" }

local function fontValue(o, field)
    local s = S[o]
    local v = s[field]
    if v ~= nil then return v end
    if s.fontObject then return fontValue(s.fontObject, field) end
end
Emu.FontValue = fontValue

local FontMethods = {}

function FontMethods:SetFont(file, size, flags)
    local s = S[self]
    if type(file) ~= "string" or file == "" then
        argError(2, "%s:SetFont(): Invalid font file", s.objectType)
    end
    s.fontFile, s.fontSize, s.fontFlags = file, tonumber(size) or 12, flags or ""
    touch()
    return true
end
function FontMethods:GetFont()
    return fontValue(self, "fontFile"), fontValue(self, "fontSize"), fontValue(self, "fontFlags") or ""
end
function FontMethods:SetFontObject(font)
    font = resolveObject(font)
    local s = S[self]
    s.fontObject = font
    for _, f in ipairs(FONT_FIELDS) do s[f] = nil end
    touch()
end
function FontMethods:GetFontObject() return S[self].fontObject end
function FontMethods:SetTextColor(r, g, b, a)
    S[self].textColor = { r or 1, g or 1, b or 1, a or 1 }
    touch()
end
function FontMethods:GetTextColor()
    local c = fontValue(self, "textColor") or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4]
end
function FontMethods:SetShadowColor(r, g, b, a) S[self].shadowColor = { r or 0, g or 0, b or 0, a or 1 }; touch() end
function FontMethods:GetShadowColor()
    local c = fontValue(self, "shadowColor") or { 0, 0, 0, 0 }
    return c[1], c[2], c[3], c[4]
end
function FontMethods:SetShadowOffset(x, y) S[self].shadowOffset = { x or 0, y or 0 }; touch() end
function FontMethods:GetShadowOffset()
    local o = fontValue(self, "shadowOffset") or { 0, 0 }
    return o[1], o[2]
end
function FontMethods:SetJustifyH(j) S[self].justifyH = j and j:upper(); touch() end
function FontMethods:GetJustifyH() return fontValue(self, "justifyH") or "CENTER" end
function FontMethods:SetJustifyV(j) S[self].justifyV = j and j:upper(); touch() end
function FontMethods:GetJustifyV() return fontValue(self, "justifyV") or "MIDDLE" end
function FontMethods:SetSpacing(sp) S[self].spacing = sp; touch() end
function FontMethods:GetSpacing() return fontValue(self, "spacing") or 0 end
function FontMethods:SetIndentedWordWrap(v) S[self].indentedWordWrap = v end
function FontMethods:GetIndentedWordWrap() return S[self].indentedWordWrap or false end

local Font = define("Font", "Object")
for k, v in pairs(FontMethods) do Font[k] = v end
function Font:CopyFontObject(src)
    src = resolveObject(src)
    local s, ss = S[self], S[src]
    for _, f in ipairs(FONT_FIELDS) do
        local v = fontValue(src, f)
        s[f] = type(v) == "table" and { unpack(v) } or v
    end
    touch()
end
function Font:SetAlpha(a) S[self].alpha = a end
function Font:GetAlpha() return S[self].alpha or 1 end

local fontObjects = {}
function CreateFont(name)
    if name and fontObjects[name] then return fontObjects[name] end
    local f = newObject("Font", { name = name })
    if name then
        fontObjects[name] = f
        _G[name] = f
    end
    return f
end
function GetFonts()
    local names = {}
    for n in pairs(fontObjects) do names[#names + 1] = n end
    return names
end

local FontString = define("FontString", "LayeredRegion")
for k, v in pairs(FontMethods) do FontString[k] = v end

function FontString:SetText(text)
    local s = S[self]
    if text ~= nil and type(text) ~= "string" then
        if type(text) == "number" then text = tostring(text)
        else argError(2, "FontString:SetText(): Usage: (text)") end
    end
    if s.text == text then return end
    s.text = text
    touch()
end
function FontString:GetText() return S[self].text end
function FontString:SetFormattedText(fmt, ...) self:SetText(fmt:format(...)) end
function FontString:SetWordWrap(v) S[self].wordWrap = v and true or false; touch() end
function FontString:CanWordWrap() return S[self].wordWrap ~= false end
function FontString:SetNonSpaceWrap(v) S[self].nonSpaceWrap = v and true or false; touch() end
function FontString:CanNonSpaceWrap() return S[self].nonSpaceWrap or false end
function FontString:SetMaxLines(n) S[self].maxLines = n; touch() end
function FontString:GetMaxLines() return S[self].maxLines or 0 end
function FontString:SetTextScale(sc) S[self].textScale = sc; touch() end
function FontString:GetTextScale() return S[self].textScale or 1 end
function FontString:SetTextToFit(text) self:SetText(text) end
function FontString:SetFixedColor(v) S[self].fixedColor = v end
function FontString:SetAlphaGradient() end
function FontString:ClearAlphaGradient() end

-- Text metrics come from the browser (canvas measureText) via JS; cached per key.
local measureCache = {}
local function fontKey(o)
    local file, size, flags = o:GetFont()
    return file or "", (size or 12) * (S[o].textScale or 1), flags or ""
end

-- Unbounded width (single line per explicit line break), in the font string's units.
local function textLayout(o, maxWidth)
    local s = S[o]
    local text = s.text
    if not text or text == "" then return 0, 0, 0 end
    local file, size, flags = fontKey(o)
    local wrap = (s.wordWrap ~= false) and maxWidth and maxWidth > 0 and maxWidth or 0
    local key = table.concat({ file, size, flags, wrap, s.nonSpaceWrap and 1 or 0, fontValue(o, "spacing") or 0, s.maxLines or 0, text }, "\1")
    local c = measureCache[key]
    if not c then
        local w, h, lines = __js("layoutText", file, size, flags, text, wrap, s.nonSpaceWrap or false,
            fontValue(o, "spacing") or 0, s.maxLines or 0)
        c = { w, h, lines }
        measureCache[key] = c
    end
    return c[1], c[2], c[3]
end
Emu.TextLayout = textLayout

function Emu.FontStringNaturalWidth(o)
    return (textLayout(o, nil))
end
function Emu.FontStringNaturalHeight(o, width)
    local _, h = textLayout(o, width)
    if h == 0 then
        local _, size = fontKey(o)
        return size
    end
    return h
end

-- The width of the text as laid out (widest line, after wrapping to the set width).
function FontString:GetStringWidth()
    return (textLayout(self, S[self].width))
end
function FontString:GetUnboundedStringWidth() return (textLayout(self, nil)) end
function FontString:GetStringHeight()
    local _, h = textLayout(self, self:GetWidth())
    return h
end
function FontString:GetNumLines()
    local _, _, lines = textLayout(self, self:GetWidth())
    return lines
end
function FontString:IsTruncated() return false end
function FontString:GetLineHeight() local _, size = fontKey(self) return size end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local Frame = define("Frame", "Region")
Emu.MOUSE_SCRIPTS = { OnEnter = true, OnLeave = true, OnMouseDown = true, OnMouseUp = true, OnMouseWheel = true }

local function newFrame(frameType, name, parent, id)
    local s = {
        parent = parent, points = {}, shown = true, alpha = 1, isFrame = true,
        children = {}, regions = {}, scripts = {}, hooks = {}, events = {}, attributes = {},
        level = parent and (S[parent].level or 0) + 1 or 0, id = nil, frameID = id or 0,
        mouse = false,
    }
    if name and parent then name = name:gsub("%$parent", S[parent].name or "") end
    s.name = name
    local o = newObject(frameType, s)
    if parent then table.insert(S[parent].children, o) end
    if name then _G[name] = o end
    table.insert(Emu.allFrames, o)
    touch()
    return o
end
Emu.NewFrame = newFrame

-- Scripts ----------------------------------------------------------------
-- UNVERIFIED (to check in-game): whether SetScript() drops hooks added earlier with
-- HookScript(). Emu.config.setScriptClearsHooks selects the behavior.
function Frame:SetScript(event, fn)
    local s = S[self]
    if fn ~= nil and type(fn) ~= "function" then
        argError(2, "%s:SetScript(): Usage: (\"type\", function)", s.objectType)
    end
    if not Emu.HasScriptType(self, event) then
        argError(2, "%s:SetScript(): %s doesn't have a \"%s\" script", s.objectType, s.name or "Frame", tostring(event))
    end
    s.scripts[event] = fn
    if Emu.config.setScriptClearsHooks then s.hooks[event] = nil end
    if fn and Emu.MOUSE_SCRIPTS[event] and Emu.config.mouseScriptsEnableMouse then s.mouse = true end
    if event == "OnUpdate" then Emu.UpdateOnUpdateList(self) end
end

function Frame:GetScript(event)
    return S[self].scripts[event]
end
function Frame:HasScript(event) return Emu.HasScriptType(self, event) end

function Frame:HookScript(event, fn)
    local s = S[self]
    if not Emu.HasScriptType(self, event) then
        argError(2, "%s:HookScript(): %s doesn't have a \"%s\" script", s.objectType, s.name or "Frame", tostring(event))
    end
    if not s.scripts[event] then
        s.scripts[event] = fn
    else
        s.hooks[event] = s.hooks[event] or {}
        table.insert(s.hooks[event], fn)
    end
    if Emu.MOUSE_SCRIPTS[event] and Emu.config.mouseScriptsEnableMouse then s.mouse = true end
    if event == "OnUpdate" then Emu.UpdateOnUpdateList(self) end
    return true
end

-- Calls a script handler + hooks, reporting errors like WoW's error handler
-- (the caller keeps running).
function Emu.RunScript(o, event, ...)
    local s = S[o]
    local fn = s.scripts and s.scripts[event]
    if not fn then return end
    -- Lua 5.1's xpcall doesn't forward arguments, so they're captured here.
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function() return fn(o, unpack(args, 1, n)) end, Emu.ErrorTraceback)
    if not ok then Emu.ReportError(err) end
    local hooks = s.hooks[event]
    if hooks then
        for _, h in ipairs(hooks) do
            ok, err = xpcall(function() return h(o, unpack(args, 1, n)) end, Emu.ErrorTraceback)
            if not ok then Emu.ReportError(err) end
        end
    end
end

-- Events -----------------------------------------------------------------
function Frame:RegisterEvent(event)
    if type(event) ~= "string" then argError(2, "Frame:RegisterEvent(): Usage: (\"event\")") end
    local s = S[self]
    if not s.events[event] then
        s.events[event] = true
        Emu.AddEventFrame(event, self)
    end
    return true
end
function Frame:RegisterUnitEvent(event, ...)
    local r = self:RegisterEvent(event)
    local units = { ... }
    S[self].unitEvents = S[self].unitEvents or {}
    S[self].unitEvents[event] = #units > 0 and units or nil
    return r
end
function Frame:UnregisterEvent(event)
    local s = S[self]
    if s.events[event] then
        s.events[event] = nil
        Emu.RemoveEventFrame(event, self)
    end
end
function Frame:UnregisterAllEvents()
    for event in pairs(S[self].events) do self:UnregisterEvent(event) end
end
function Frame:IsEventRegistered(event) return S[self].events[event] or false end
function Frame:RegisterAllEvents() end

-- Children / regions -----------------------------------------------------
function Frame:GetChildren() return unpack(S[self].children) end
function Frame:GetNumChildren() return #S[self].children end
function Frame:GetRegions() return unpack(S[self].regions) end
function Frame:GetNumRegions() return #S[self].regions end

function Frame:CreateTexture(name, layer, template, sublevel)
    if layer and not LAYERS[layer] then argError(2, "Frame:CreateTexture(): Invalid layer '%s'", tostring(layer)) end
    local t = newRegion("Texture", self, name, layer or "ARTWORK", sublevel)
    if template then Emu.ApplyTemplates(t, template) end
    return t
end
function Frame:CreateMaskTexture(name, layer, template, sublevel)
    local t = newRegion("MaskTexture", self, name, layer or "ARTWORK", sublevel)
    if template then Emu.ApplyTemplates(t, template) end
    return t
end
function Frame:CreateLine(name, layer, template, sublevel)
    local t = newRegion("Line", self, name, layer or "ARTWORK", sublevel)
    if template then Emu.ApplyTemplates(t, template) end
    return t
end
function Frame:CreateFontString(name, layer, template)
    local fs = newRegion("FontString", self, name, layer or "ARTWORK", 0)
    if template then
        local font = resolveObject(template)
        if type(font) == "table" and S[font] and S[font].objectType == "Font" then
            S[fs].fontObject = font
        else
            Emu.ApplyTemplates(fs, template)
        end
    end
    return fs
end

-- Strata / level -----------------------------------------------------------
local function effectiveStrata(o)
    local s = S[o]
    while s do
        if s.strata then return s.strata end
        if not s.parent then return "MEDIUM" end
        s = S[s.parent]
    end
    return "MEDIUM"
end
Emu.EffectiveStrata = effectiveStrata

function Frame:SetFrameStrata(strata)
    if not STRATA_INDEX[strata] then argError(2, "Frame:SetFrameStrata(): Unknown frame strata '%s'", tostring(strata)) end
    S[self].strata = strata
    touch()
end
function Frame:GetFrameStrata() return effectiveStrata(self) end
function Frame:SetFixedFrameStrata(v) S[self].fixedStrata = v end
function Frame:HasFixedFrameStrata() return S[self].fixedStrata or false end
function Frame:SetFixedFrameLevel(v) S[self].fixedLevel = v end
function Frame:HasFixedFrameLevel() return S[self].fixedLevel or false end

-- Raising a frame keeps its children above it (UNVERIFIED: exact client rule).
local function raiseChildren(o)
    local s = S[o]
    for _, child in ipairs(s.children) do
        local cs = S[child]
        if not cs.fixedLevel and cs.level <= s.level then
            cs.level = s.level + 1
            raiseChildren(child)
        end
    end
end
function Frame:SetFrameLevel(level)
    local s = S[self]
    s.level = math.max(0, math.floor(tonumber(level) or 0))
    s.levelSet = true
    raiseChildren(self)
    touch()
end
function Frame:GetFrameLevel() return S[self].level end
function Frame:Raise() S[self].raiseOrder = Emu.NextRaise(); touch() end
function Frame:Lower() S[self].raiseOrder = -Emu.NextRaise(); touch() end
function Frame:SetToplevel(v) S[self].toplevel = v end
function Frame:IsToplevel() return S[self].toplevel or false end
function Frame:SetClipsChildren(v) S[self].clips = v and true or false; touch() end
function Frame:DoesClipChildren() return S[self].clips or false end

-- Mouse ------------------------------------------------------------------
function Frame:EnableMouse(v) S[self].mouse = v and true or false end
function Frame:IsMouseEnabled() return S[self].mouse end
function Frame:EnableMouseMotion(v) S[self].mouse = v and true or false end
function Frame:IsMouseMotionEnabled() return S[self].mouse end
function Frame:EnableMouseClicks(v) S[self].mouse = v and true or false end
function Frame:IsMouseClickEnabled() return S[self].mouse end
function Frame:EnableMouseWheel(v) S[self].mouseWheel = v and true or false end
function Frame:IsMouseWheelEnabled() return S[self].mouseWheel or false end
function Frame:SetMouseClickEnabled(v) S[self].mouse = v and true or false end
function Frame:SetMouseMotionEnabled(v) S[self].mouse = v and true or false end
function Frame:SetPropagateMouseClicks(v) S[self].propagateClicks = v end
function Frame:SetPropagateMouseMotion(v) S[self].propagateMotion = v end
function Frame:SetHitRectInsets(l, r, t, b) S[self].hitInsets = { l or 0, r or 0, t or 0, b or 0 } end
function Frame:GetHitRectInsets()
    local h = S[self].hitInsets or { 0, 0, 0, 0 }
    return h[1], h[2], h[3], h[4]
end
function Frame:EnableKeyboard(v) S[self].keyboard = v end
function Frame:IsKeyboardEnabled() return S[self].keyboard or false end
function Frame:SetPropagateKeyboardInput() end
function Frame:EnableGamePadButton() end
function Frame:EnableGamePadStick() end

-- Moving -----------------------------------------------------------------
function Frame:SetMovable(v) S[self].movable = v and true or false end
function Frame:IsMovable() return S[self].movable or false end
function Frame:SetResizable(v) S[self].resizable = v and true or false end
function Frame:IsResizable() return S[self].resizable or false end
function Frame:SetClampedToScreen(v) S[self].clamped = v and true or false end
function Frame:IsClampedToScreen() return S[self].clamped or false end
function Frame:SetClampRectInsets() end
function Frame:SetUserPlaced(v) S[self].userPlaced = v end
function Frame:IsUserPlaced() return S[self].userPlaced or false end
function Frame:SetDontSavePosition() end
function Frame:RegisterForDrag(...)
    local s = S[self]
    s.dragButtons = {}
    for i = 1, select("#", ...) do
        local b = select(i, ...)
        s.dragButtons[(b:gsub("Up$", ""):gsub("Down$", ""))] = true
    end
end
function Frame:StartMoving()
    local s = S[self]
    if not s.movable then
        Emu.ReportError(("%s:StartMoving(): Frame is not movable"):format(s.name or "Frame"))
        return
    end
    local l, b = absRect(self)
    if not l then return end
    -- The point grabbed at mouse-down stays under the cursor (drag starts a few px later).
    local gx, gy = Emu.mouseX, Emu.mouseY
    if Emu.pressed then gx, gy = Emu.pressX, Emu.pressY end
    Emu.moving = { frame = self, dx = l - gx, dy = b - gy }
end
function Frame:StartSizing() end
function Frame:StopMovingOrSizing()
    if Emu.moving and Emu.moving.frame == self then Emu.moving = nil end
end
function Frame:SetResizeBounds() end
function Frame:GetResizeBounds() return 0, 0, 0, 0 end
function Frame:SetMinResize() end
function Frame:SetMaxResize() end

-- Misc ---------------------------------------------------------------------
function Frame:SetID(id) S[self].frameID = id end
function Frame:GetID() return S[self].frameID or 0 end
function Frame:SetAttribute(k, v) S[self].attributes[k] = v; Emu.RunScript(self, "OnAttributeChanged", k, v) end
function Frame:GetAttribute(k) return S[self].attributes[k] end
function Frame:SetAttributeNoHandler(k, v) S[self].attributes[k] = v end
function Frame:CanChangeAttribute() return true end
function Frame:IsVisibleInHierarchy() return isVisible(self) end
function Frame:GetEffectivelyFlattensRenderLayers() return false end
function Frame:SetFlattensRenderLayers() end
function Frame:SetFrameBuffer() end
function Frame:DesaturateHierarchy() end
function Frame:SetUsingParentLevel() end
function Frame:GetBoundsRect() return self:GetRect() end

---------------------------------------------------------------------------
-- Button / CheckButton
---------------------------------------------------------------------------
local Button = define("Button", "Frame")

function Button:RegisterForClicks(...)
    local s = S[self]
    s.clicks = {}
    for i = 1, select("#", ...) do s.clicks[select(i, ...)] = true end
end
function Button:RegisterForMouse(...) end
function Button:Enable() S[self].disabled = false; touch(); Emu.RunScript(self, "OnEnable") end
function Button:Disable() S[self].disabled = true; touch(); Emu.RunScript(self, "OnDisable") end
function Button:SetEnabled(v) if v then self:Enable() else self:Disable() end end
function Button:IsEnabled() return not S[self].disabled end
function Button:GetButtonState() return S[self].disabled and "DISABLED" or (S[self].pushed and "PUSHED" or "NORMAL") end
function Button:SetButtonState(state, locked) S[self].pushed = state == "PUSHED"; touch() end
function Button:LockHighlight() S[self].highlightLocked = true; touch() end
function Button:UnlockHighlight() S[self].highlightLocked = false; touch() end
function Button:SetMotionScriptsWhileDisabled(v) S[self].motionWhileDisabled = v end

-- Click(button, down): runs OnClick like a real mouse click would.
function Button:Click(button, down)
    Emu.DoClick(self, button or "LeftButton", down or false)
end

-- State textures: Normal/Pushed/Disabled/Highlight. A path creates (or retypes) a
-- texture child that fills the button.
local STATE_LAYER = { normal = "ARTWORK", pushed = "ARTWORK", disabled = "ARTWORK", highlight = "HIGHLIGHT", checked = "ARTWORK", disabledChecked = "ARTWORK" }
local function setStateTexture(self, key, tex, blend)
    local s = S[self]
    s.stateTextures = s.stateTextures or {}
    if tex == nil then
        local old = s.stateTextures[key]
        if old then old:Hide() end
        s.stateTextures[key] = nil
        touch()
        return
    end
    local t
    if type(tex) == "table" then
        t = tex
        if S[t].parent ~= self then t:SetParent(self) end
        S[t].layer = STATE_LAYER[key]
    else
        t = s.stateTextures[key] or newRegion("Texture", self, nil, STATE_LAYER[key], key == "checked" and 1 or 0)
        if type(tex) == "string" and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(tex) and not tex:find("[\\/]") then
            t:SetAtlas(tex)
        else
            t:SetTexture(tex)
        end
    end
    if #S[t].points == 0 then t:SetAllPoints(self) end
    if blend then t:SetBlendMode(blend) end
    S[t].stateKey = key
    s.stateTextures[key] = t
    t:Show()
    touch()
end
function Button:SetNormalTexture(t) setStateTexture(self, "normal", t) end
function Button:SetPushedTexture(t) setStateTexture(self, "pushed", t) end
function Button:SetDisabledTexture(t) setStateTexture(self, "disabled", t) end
function Button:SetHighlightTexture(t, blend) setStateTexture(self, "highlight", t, blend) end
function Button:SetNormalAtlas(a) setStateTexture(self, "normal", a) end
function Button:SetPushedAtlas(a) setStateTexture(self, "pushed", a) end
function Button:SetDisabledAtlas(a) setStateTexture(self, "disabled", a) end
function Button:SetHighlightAtlas(a, blend) setStateTexture(self, "highlight", a, blend) end
function Button:GetNormalTexture() return S[self].stateTextures and S[self].stateTextures.normal end
function Button:GetPushedTexture() return S[self].stateTextures and S[self].stateTextures.pushed end
function Button:GetDisabledTexture() return S[self].stateTextures and S[self].stateTextures.disabled end
function Button:GetHighlightTexture() return S[self].stateTextures and S[self].stateTextures.highlight end
function Button:ClearNormalTexture() setStateTexture(self, "normal", nil) end
function Button:ClearPushedTexture() setStateTexture(self, "pushed", nil) end
function Button:ClearDisabledTexture() setStateTexture(self, "disabled", nil) end
function Button:ClearHighlightTexture() setStateTexture(self, "highlight", nil) end
function Button:SetPushedTextOffset(x, y) S[self].pushedTextOffset = { x, y } end
function Button:GetPushedTextOffset() local o = S[self].pushedTextOffset or { 0, 0 } return o[1], o[2] end

function Button:SetFontString(fs)
    S[self].fontString = fs
    if fs and #S[fs].points == 0 then fs:SetPoint("CENTER") end
end
function Button:GetFontString() return S[self].fontString end
function Button:SetText(text)
    local s = S[self]
    if not s.fontString then
        local fs = self:CreateFontString(nil, "OVERLAY")
        S[fs].fontObject = s.normalFontObject or _G.GameFontNormal
        fs:SetPoint("CENTER")
        s.fontString = fs
    end
    s.fontString:SetText(text)
end
function Button:SetFormattedText(fmt, ...) self:SetText(fmt:format(...)) end
function Button:GetText() return S[self].fontString and S[self].fontString:GetText() end
function Button:GetTextWidth() return S[self].fontString and S[self].fontString:GetStringWidth() or 0 end
function Button:GetTextHeight() return S[self].fontString and S[self].fontString:GetStringHeight() or 0 end
function Button:SetNormalFontObject(f)
    f = resolveObject(f)
    S[self].normalFontObject = f
    if S[self].fontString then S[S[self].fontString].fontObject = f; touch() end
end
function Button:GetNormalFontObject() return S[self].normalFontObject end
function Button:SetHighlightFontObject(f) S[self].highlightFontObject = resolveObject(f) end
function Button:GetHighlightFontObject() return S[self].highlightFontObject end
function Button:SetDisabledFontObject(f) S[self].disabledFontObject = resolveObject(f) end
function Button:GetDisabledFontObject() return S[self].disabledFontObject end

local CheckButton = define("CheckButton", "Button")
function CheckButton:SetChecked(v) S[self].checked = v and true or false; touch() end
function CheckButton:GetChecked() return S[self].checked or false end
function CheckButton:SetCheckedTexture(t) setStateTexture(self, "checked", t) end
function CheckButton:GetCheckedTexture() return S[self].stateTextures and S[self].stateTextures.checked end
function CheckButton:SetDisabledCheckedTexture(t) setStateTexture(self, "disabledChecked", t) end
function CheckButton:GetDisabledCheckedTexture() return S[self].stateTextures and S[self].stateTextures.disabledChecked end

---------------------------------------------------------------------------
-- Other frame types (only what's needed; the rest are logged stubs)
---------------------------------------------------------------------------
local EditBox = define("EditBox", "Frame")
for k, v in pairs(FontMethods) do EditBox[k] = v end
function EditBox:SetText(t) S[self].text = tostring(t or ""); touch(); Emu.RunScript(self, "OnTextChanged", false) end
function EditBox:GetText() return S[self].text or "" end
function EditBox:SetNumber(n) self:SetText(tostring(n)) end
function EditBox:GetNumber() return tonumber(S[self].text) or 0 end
function EditBox:SetAutoFocus(v) S[self].autoFocus = v end
function EditBox:SetFocus() Emu.focus = self end
function EditBox:ClearFocus() if Emu.focus == self then Emu.focus = nil end end
function EditBox:HasFocus() return Emu.focus == self end
function EditBox:SetMultiLine(v) S[self].multiLine = v end
function EditBox:IsMultiLine() return S[self].multiLine or false end
function EditBox:SetMaxLetters(n) S[self].maxLetters = n end
function EditBox:SetNumeric(v) S[self].numeric = v end
function EditBox:HighlightText() end
function EditBox:SetCursorPosition() end
function EditBox:SetTextInsets() end
function EditBox:Insert(t) self:SetText((S[self].text or "") .. t) end

local ScrollFrame = define("ScrollFrame", "Frame")
function ScrollFrame:SetScrollChild(child)
    local s = S[self]
    s.scrollChild = child
    if child then
        child:SetParent(self)
        child:ClearAllPoints()
        child:SetPoint("TOPLEFT", self, "TOPLEFT", -(s.hScroll or 0), s.vScroll or 0)
    end
    s.clips = true
    touch()
end
function ScrollFrame:GetScrollChild() return S[self].scrollChild end
local function rescroll(self)
    local s = S[self]
    if s.scrollChild then
        S[s.scrollChild].points = {}
        s.scrollChild:SetPoint("TOPLEFT", self, "TOPLEFT", -(s.hScroll or 0), s.vScroll or 0)
    end
    Emu.RunScript(self, "OnVerticalScroll", s.vScroll or 0)
end
function ScrollFrame:SetVerticalScroll(v) S[self].vScroll = v; rescroll(self) end
function ScrollFrame:GetVerticalScroll() return S[self].vScroll or 0 end
function ScrollFrame:SetHorizontalScroll(v) S[self].hScroll = v; rescroll(self) end
function ScrollFrame:GetHorizontalScroll() return S[self].hScroll or 0 end
function ScrollFrame:GetVerticalScrollRange()
    local s = S[self]
    if not s.scrollChild then return 0 end
    return math.max(0, s.scrollChild:GetHeight() - self:GetHeight())
end
function ScrollFrame:GetHorizontalScrollRange()
    local s = S[self]
    if not s.scrollChild then return 0 end
    return math.max(0, s.scrollChild:GetWidth() - self:GetWidth())
end
function ScrollFrame:UpdateScrollChildRect() end

local Slider = define("Slider", "Frame")
function Slider:SetMinMaxValues(a, b) S[self].min, S[self].max = a, b end
function Slider:GetMinMaxValues() return S[self].min or 0, S[self].max or 0 end
function Slider:SetValue(v)
    local s = S[self]
    v = math.max(s.min or v, math.min(s.max or v, v))
    if s.value == v then return end
    s.value = v
    touch()
    Emu.RunScript(self, "OnValueChanged", v, false)
end
function Slider:GetValue() return S[self].value or 0 end
function Slider:SetValueStep(v) S[self].step = v end
function Slider:GetValueStep() return S[self].step or 0 end
function Slider:SetObeyStepOnDrag(v) end
function Slider:SetOrientation(o) S[self].orientation = o end
function Slider:GetOrientation() return S[self].orientation or "HORIZONTAL" end
function Slider:SetThumbTexture(t)
    local s = S[self]
    if type(t) == "table" then s.thumb = t
    else
        s.thumb = s.thumb or newRegion("Texture", self, nil, "ARTWORK")
        s.thumb:SetTexture(t)
    end
end
function Slider:GetThumbTexture() return S[self].thumb end
function Slider:Enable() S[self].disabled = false end
function Slider:Disable() S[self].disabled = true end
function Slider:IsEnabled() return not S[self].disabled end
function Slider:SetStepsPerPage() end

local StatusBar = define("StatusBar", "Frame")
function StatusBar:SetMinMaxValues(a, b) S[self].min, S[self].max = a, b; touch() end
function StatusBar:GetMinMaxValues() return S[self].min or 0, S[self].max or 1 end
function StatusBar:SetValue(v) S[self].value = v; touch() end
function StatusBar:GetValue() return S[self].value or 0 end
function StatusBar:SetStatusBarTexture(t)
    local s = S[self]
    if type(t) == "table" then s.bar = t
    else
        s.bar = s.bar or newRegion("Texture", self, nil, "ARTWORK")
        s.bar:SetTexture(t)
    end
    touch()
end
function StatusBar:GetStatusBarTexture() return S[self].bar end
function StatusBar:SetStatusBarColor(r, g, b, a) if S[self].bar then S[self].bar:SetVertexColor(r, g, b, a) end end
function StatusBar:SetOrientation(o) S[self].orientation = o end
function StatusBar:SetReverseFill(v) S[self].reverse = v end
function StatusBar:SetFillStyle() end

local Cooldown = define("Cooldown", "Frame")
function Cooldown:SetCooldown(start, duration) S[self].cdStart, S[self].cdDuration = start, duration end
function Cooldown:GetCooldownTimes() return (S[self].cdStart or 0) * 1000, (S[self].cdDuration or 0) * 1000 end
function Cooldown:Clear() S[self].cdStart, S[self].cdDuration = nil, nil end
function Cooldown:SetDrawEdge() end
function Cooldown:SetDrawSwipe() end
function Cooldown:SetDrawBling() end
function Cooldown:SetHideCountdownNumbers() end
function Cooldown:SetSwipeColor() end
function Cooldown:SetReverse() end

define("GameTooltip", "Frame")
define("Model", "Frame")
define("PlayerModel", "Model")
define("DressUpModel", "PlayerModel")
define("ModelScene", "Frame")
define("SimpleHTML", "Frame")
define("MessageFrame", "Frame")
define("ScrollingMessageFrame", "Frame")
define("ColorSelect", "Frame")
define("Minimap", "Frame")
define("MovieFrame", "Frame")
define("DropdownButton", "Button")
define("EventFrame", "Frame")

---------------------------------------------------------------------------
-- AnimationGroup / Animation
---------------------------------------------------------------------------
local AnimationGroup = define("AnimationGroup", "Object")
local Animation = define("Animation", "Object")

local ANIMATION_TYPES = {
    Alpha = true, Scale = true, LineScale = true, Translation = true, LineTranslation = true,
    Rotation = true, Path = true, FlipBook = true, TextureCoordTranslation = true, VertexColor = true,
    Animation = true,
}
for t in pairs(ANIMATION_TYPES) do
    if t ~= "Animation" then define(t, "Animation") end
end

function AnimationGroup:CreateAnimation(animType, name, template)
    animType = animType or "Animation"
    if not ANIMATION_TYPES[animType] then
        argError(2, "AnimationGroup:CreateAnimation(): Unknown animation type '%s'", tostring(animType))
    end
    local s = S[self]
    local a = newObject(animType, {
        name = name, parent = self, duration = 0, order = 1, startDelay = 0, endDelay = 0,
        smoothing = "NONE", scripts = {},
    })
    table.insert(s.animations, a)
    if name then _G[name] = a end
    return a
end
function AnimationGroup:GetAnimations() return unpack(S[self].animations) end
function AnimationGroup:SetLooping(l) S[self].looping = l or "NONE" end
function AnimationGroup:GetLooping() return S[self].looping end
function AnimationGroup:GetLoopState() return S[self].reverse and "REVERSE" or "FORWARD" end
function AnimationGroup:SetToFinalAlpha(v) S[self].toFinalAlpha = v end
function AnimationGroup:IsSetToFinalAlpha() return S[self].toFinalAlpha or false end
function AnimationGroup:SetAnimationSpeedMultiplier(m) S[self].speed = m end
function AnimationGroup:GetAnimationSpeedMultiplier() return S[self].speed end
function AnimationGroup:IsPlaying() return S[self].playing end
function AnimationGroup:IsPaused() return S[self].paused or false end
function AnimationGroup:IsDone() return S[self].done or false end
function AnimationGroup:IsPendingFinish() return false end
function AnimationGroup:IsReverse() return S[self].reverse or false end
function AnimationGroup:GetProgress()
    local d = Emu.AnimGroupDuration(self)
    return d > 0 and math.min(1, S[self].elapsed / d) or 0
end
function AnimationGroup:GetDuration() return Emu.AnimGroupDuration(self) end
function AnimationGroup:GetElapsed() return S[self].elapsed end
function AnimationGroup:SetScript(event, fn) S[self].scripts[event] = fn end
function AnimationGroup:GetScript(event) return S[self].scripts[event] end
function AnimationGroup:HookScript(event, fn)
    local old = S[self].scripts[event]
    S[self].scripts[event] = old and function(...) old(...) fn(...) end or fn
end
function AnimationGroup:HasScript() return true end

function AnimationGroup:Play(reverse, offset)
    local s = S[self]
    if s.playing and not s.paused then return end
    s.paused = false
    if not s.playing then
        s.elapsed = 0
        s.reverse = reverse and true or false
        s.bounceBack = false
    end
    s.playing = true
    s.done = false
    Emu.StartAnimGroup(self)
    Emu.RunAnimScript(self, "OnPlay")
end
function AnimationGroup:Restart(reverse) self:Stop() self:Play(reverse) end
function AnimationGroup:Pause() S[self].paused = true end
function AnimationGroup:Stop()
    local s = S[self]
    if not s.playing then return end
    s.playing, s.paused = false, false
    Emu.ResetAnimGroup(self)
    Emu.RunAnimScript(self, "OnStop", false)
end
function AnimationGroup:Finish() S[self].finishing = true end

function Animation:SetDuration(d) S[self].duration = d or 0 end
function Animation:GetDuration() return S[self].duration end
function Animation:SetStartDelay(d) S[self].startDelay = d or 0 end
function Animation:GetStartDelay() return S[self].startDelay end
function Animation:SetEndDelay(d) S[self].endDelay = d or 0 end
function Animation:GetEndDelay() return S[self].endDelay end
function Animation:SetOrder(o) S[self].order = o or 1 end
function Animation:GetOrder() return S[self].order end
function Animation:SetSmoothing(sm) S[self].smoothing = sm or "NONE" end
function Animation:GetSmoothing() return S[self].smoothing end
function Animation:SetSmoothProgress() end
function Animation:SetTarget(t) S[self].target = resolveObject(t) end
function Animation:GetTarget() return Emu.AnimTarget(self) end
function Animation:SetChildKey(k) S[self].childKey = k end
function Animation:SetTargetKey(k) S[self].childKey = k end
function Animation:SetTargetName(n) S[self].target = _G[n] end
function Animation:SetTargetParent() S[self].target = nil end
function Animation:GetRegionParent() return S[S[self].parent].parent end
function Animation:IsPlaying() return S[S[self].parent].playing end
function Animation:IsDone() return S[S[self].parent].done or false end
function Animation:IsStopped() return not S[S[self].parent].playing end
function Animation:IsPaused() return S[S[self].parent].paused or false end
function Animation:GetProgress() return S[self].progress or 0 end
function Animation:GetSmoothProgress() return S[self].progress or 0 end
function Animation:GetElapsed() return 0 end
function Animation:SetPlaying() end
function Animation:Play() end
function Animation:Stop() end
function Animation:Pause() end
function Animation:Restart() end
function Animation:SetScript(event, fn) S[self].scripts[event] = fn end
function Animation:GetScript(event) return S[self].scripts[event] end
function Animation:HookScript(event, fn) S[self].scripts[event] = fn end
function Animation:HasScript() return true end
function Animation:SetToFinalAlpha(v) S[self].toFinalAlpha = v end
function Animation:IsSetToFinalAlpha() return S[self].toFinalAlpha or false end

local Alpha = Class.Alpha
function Alpha:SetFromAlpha(a) S[self].fromAlpha = a end
function Alpha:GetFromAlpha() return S[self].fromAlpha or 0 end
function Alpha:SetToAlpha(a) S[self].toAlpha = a end
function Alpha:GetToAlpha() return S[self].toAlpha or 0 end
function Alpha:SetChange(c) S[self].fromAlpha, S[self].toAlpha = nil, nil; S[self].alphaChange = c end

local Scale = Class.Scale
function Scale:SetScaleFrom(x, y) S[self].scaleFrom = { x, y } end
function Scale:SetScaleTo(x, y) S[self].scaleTo = { x, y } end
function Scale:SetFromScale(x, y) S[self].scaleFrom = { x, y } end
function Scale:SetToScale(x, y) S[self].scaleTo = { x, y } end
function Scale:SetScale(x, y) S[self].scaleFrom = { 1, 1 }; S[self].scaleTo = { x, y } end
function Scale:GetScale() local t = S[self].scaleTo or { 1, 1 } return t[1], t[2] end
function Scale:SetOrigin(point, x, y) S[self].origin = { point, x or 0, y or 0 } end
function Scale:GetOrigin() local o = S[self].origin or { "CENTER", 0, 0 } return o[1], o[2], o[3] end
Class.LineScale.SetScaleFrom, Class.LineScale.SetScaleTo, Class.LineScale.SetOrigin = Scale.SetScaleFrom, Scale.SetScaleTo, Scale.SetOrigin

local Translation = Class.Translation
function Translation:SetOffset(x, y) S[self].offset = { x or 0, y or 0 } end
function Translation:GetOffset() local o = S[self].offset or { 0, 0 } return o[1], o[2] end
Class.LineTranslation.SetOffset = Translation.SetOffset

local Rotation = Class.Rotation
function Rotation:SetDegrees(d) S[self].degrees = d end
function Rotation:GetDegrees() return S[self].degrees or 0 end
function Rotation:SetRadians(r) S[self].degrees = math.deg(r) end
function Rotation:SetOrigin(point, x, y) S[self].origin = { point, x or 0, y or 0 } end

local FlipBook = Class.FlipBook
function FlipBook:SetFlipBookRows(n) S[self].rows = n end
function FlipBook:SetFlipBookColumns(n) S[self].columns = n end
function FlipBook:SetFlipBookFrames(n) S[self].frames = n end
function FlipBook:SetFlipBookFrameWidth(n) S[self].frameWidth = n end
function FlipBook:SetFlipBookFrameHeight(n) S[self].frameHeight = n end

local VertexColor = Class.VertexColor
function VertexColor:SetStartColor(c) S[self].startColor = c end
function VertexColor:SetEndColor(c) S[self].endColor = c end
