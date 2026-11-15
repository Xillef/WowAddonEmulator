-- CreateFrame, templates, events, timers, animation driver, OnUpdate, input, rendering.

local Emu = __Emu
local S = Emu.S
local touch = Emu.Touch
local absRect = Emu.AbsRect
local isVisible = Emu.IsVisible

---------------------------------------------------------------------------
-- CreateFrame / templates
---------------------------------------------------------------------------
local FRAME_TYPES = {
    Frame = true, Button = true, CheckButton = true, EditBox = true, ScrollFrame = true, Slider = true,
    StatusBar = true, Cooldown = true, GameTooltip = true, Model = true, PlayerModel = true,
    DressUpModel = true, ModelScene = true, SimpleHTML = true, MessageFrame = true,
    ScrollingMessageFrame = true, ColorSelect = true, Minimap = true, MovieFrame = true,
    DropdownButton = true, EventFrame = true,
}

-- Templates: name -> function(obj). Unknown templates are logged (the frame is still
-- created, without whatever that template would add).
Emu.templates = {}

function Emu.ApplyTemplates(obj, templateList)
    for name in tostring(templateList):gmatch("[^,%s]+") do
        local apply = Emu.templates[name]
        if apply then
            apply(obj)
        else
            __js("stub", "template " .. name)
        end
    end
end

function CreateFrame(frameType, name, parent, template, id)
    if type(frameType) ~= "string" then
        error("CreateFrame(): Usage: (\"frameType\" [, \"name\"] [, parent] [, \"template\"] [, id])", 2)
    end
    local canonical
    for t in pairs(FRAME_TYPES) do
        if t:lower() == frameType:lower() then canonical = t break end
    end
    if not canonical then error("CreateFrame(): Unknown frame type '" .. frameType .. "'", 2) end
    if type(parent) == "string" then parent = _G[parent] end
    if parent ~= nil and (type(parent) ~= "table" or not S[parent] or not S[parent].isFrame) then
        error("CreateFrame(): Couldn't find parent frame", 2)
    end
    local f = Emu.NewFrame(canonical, name, parent, id)
    local s = S[f]
    if canonical == "Button" or canonical == "CheckButton" or canonical == "DropdownButton" then
        s.mouse = true
        s.clicks = { LeftButtonUp = true }
    elseif canonical == "EditBox" or canonical == "Slider" then
        s.mouse = true
    elseif canonical == "GameTooltip" then
        s.ttLines, s.ttCount = {}, 0
    end
    if template then Emu.ApplyTemplates(f, template) end
    Emu.RunScript(f, "OnLoad")
    return f
end

-- Any "On..." name is accepted as a script type (the client knows the exact set per type).
function Emu.HasScriptType(o, event)
    return type(event) == "string" and event:match("^On%u") ~= nil
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrames = {}

function Emu.AddEventFrame(event, f)
    local list = eventFrames[event]
    if not list then
        list = {}
        eventFrames[event] = list
    end
    list[#list + 1] = f
end

function Emu.RemoveEventFrame(event, f)
    local list = eventFrames[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == f then table.remove(list, i) end
    end
end

function Emu.FireEvent(event, ...)
    local list = eventFrames[event]
    if not list then return end
    local copy = { unpack(list) }
    for _, f in ipairs(copy) do
        local s = S[f]
        if s.events[event] then
            local units = s.unitEvents and s.unitEvents[event]
            local pass = true
            if units then
                pass = false
                local unit = ...
                for _, u in ipairs(units) do
                    if u == unit then pass = true break end
                end
            end
            if pass then Emu.RunScript(f, "OnEvent", event, ...) end
        end
    end
end

---------------------------------------------------------------------------
-- Timers (C_Timer)
---------------------------------------------------------------------------
local timers = {}

local TimerHandle = {}
TimerHandle.__index = TimerHandle
function TimerHandle:Cancel() self._cancelled = true end
function TimerHandle:IsCancelled() return self._cancelled or false end
function TimerHandle:Invoke(...) self._fn(self, ...) end

local function addTimer(seconds, fn, handle, iterations)
    local t = { due = Emu.Now() + math.max(0, seconds or 0), interval = seconds, fn = fn, handle = handle, iterations = iterations }
    timers[#timers + 1] = t
    return t
end

C_Timer = {}
function C_Timer.After(seconds, fn)
    if type(fn) ~= "function" then error("C_Timer.After(): Usage: (seconds, callback)", 2) end
    addTimer(seconds, fn)
end
function C_Timer.NewTimer(seconds, fn)
    local h = setmetatable({ _fn = fn }, TimerHandle)
    addTimer(seconds, fn, h, 1)
    return h
end
function C_Timer.NewTicker(seconds, fn, iterations)
    local h = setmetatable({ _fn = fn }, TimerHandle)
    addTimer(seconds, fn, h, iterations)
    return h
end

local function runTimers(now)
    local due = {}
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t.handle and t.handle._cancelled then
            table.remove(timers, i)
        elseif t.due <= now then
            table.remove(timers, i)
            due[#due + 1] = t
        end
    end
    table.sort(due, function(a, b) return a.due < b.due end)
    for _, t in ipairs(due) do
        if not (t.handle and t.handle._cancelled) then
            if t.handle then
                Emu.SafeCall(t.fn, t.handle)
                if t.iterations then t.iterations = t.iterations - 1 end
                if (not t.iterations or t.iterations > 0) and not t.handle._cancelled then
                    t.due = now + math.max(t.interval or 0, 0.001)
                    timers[#timers + 1] = t
                end
            else
                Emu.SafeCall(t.fn)
            end
        end
    end
end

-- Debug: one line per pending timer.
function Emu.DescribeTimers()
    local out = {}
    for _, t in ipairs(timers) do
        local kind = not t.handle and "once" or ("every %ss, %s left"):format(tostring(t.interval), tostring(t.iterations or "unlimited"))
        out[#out + 1] = ("%s, due in %.2fs"):format(kind, t.due - Emu.Now())
    end
    return table.concat(out, "\n")
end

local function nextTimerDue()
    local best
    for _, t in ipairs(timers) do
        if not (t.handle and t.handle._cancelled) and (not best or t.due < best) then best = t.due end
    end
    return best
end

---------------------------------------------------------------------------
-- Animations
---------------------------------------------------------------------------
local playingGroups = {}

function Emu.StartAnimGroup(ag) playingGroups[ag] = true end

function Emu.AnimTarget(a)
    local s = S[a]
    if s.target then return s.target end
    local owner = S[s.parent].parent
    if s.childKey then return owner[s.childKey] end
    return owner
end

-- Each SetOrder() value is a phase; phases run one after the other.
local function phases(ag)
    local byOrder, orders = {}, {}
    for _, a in ipairs(S[ag].animations) do
        local o = S[a].order
        if not byOrder[o] then
            byOrder[o] = {}
            orders[#orders + 1] = o
        end
        table.insert(byOrder[o], a)
    end
    table.sort(orders)
    local list, start = {}, 0
    for _, o in ipairs(orders) do
        local len = 0
        for _, a in ipairs(byOrder[o]) do
            local as = S[a]
            len = math.max(len, as.startDelay + as.duration + as.endDelay)
        end
        list[#list + 1] = { start = start, anims = byOrder[o] }
        start = start + len
    end
    return list, start
end

function Emu.AnimGroupDuration(ag)
    local _, total = phases(ag)
    return total
end

local SMOOTH = {
    NONE = function(p) return p end,
    IN = function(p) return p * p end,
    OUT = function(p) return 1 - (1 - p) * (1 - p) end,
    IN_OUT = function(p) return p < 0.5 and 2 * p * p or 1 - 2 * (1 - p) * (1 - p) end,
}

local function applyAnim(a, p)
    local s = S[a]
    local target = Emu.AnimTarget(a)
    if not target or not S[target] then return end
    local ts = S[target]
    local e = (SMOOTH[s.smoothing] or SMOOTH.NONE)(p)
    local t = s.objectType
    if t == "Alpha" then
        local from = s.fromAlpha or ts.alpha
        local to = s.toAlpha or (from + (s.alphaChange or 0))
        ts.animAlpha = from + (to - from) * e
    elseif t == "Translation" or t == "LineTranslation" then
        local o = s.offset or { 0, 0 }
        ts.animOffset = { o[1] * e, o[2] * e }
    elseif t == "Scale" or t == "LineScale" then
        local from = s.scaleFrom or { 1, 1 }
        local to = s.scaleTo or { 1, 1 }
        ts.animScale = {
            from[1] + (to[1] - from[1]) * e, from[2] + (to[2] - from[2]) * e,
            origin = s.origin,
        }
    end
    s.progress = p
end

local function clearAnimEffects(ag, keepFinalAlpha)
    for _, a in ipairs(S[ag].animations) do
        local target = Emu.AnimTarget(a)
        local ts = target and S[target]
        if ts then
            local s = S[a]
            if s.objectType == "Alpha" then
                if keepFinalAlpha or s.toFinalAlpha then
                    ts.alpha = ts.animAlpha or ts.alpha
                end
                ts.animAlpha = nil
            elseif s.objectType == "Translation" or s.objectType == "LineTranslation" then
                ts.animOffset = nil
            elseif s.objectType == "Scale" or s.objectType == "LineScale" then
                ts.animScale = nil
            end
        end
        S[a].progress = 0
    end
    touch()
end

function Emu.ResetAnimGroup(ag)
    playingGroups[ag] = nil
    clearAnimEffects(ag, S[ag].toFinalAlpha)
end

function Emu.RunAnimScript(obj, event, ...)
    local fn = S[obj].scripts[event]
    if fn then Emu.SafeCall(fn, obj, ...) end
end

-- Applies the group's state at time t (0..total) of the current cycle.
local function applyGroupAt(ag, t, reverse)
    local list, total = phases(ag)
    if reverse then t = total - t end
    for _, ph in ipairs(list) do
        for _, a in ipairs(ph.anims) do
            local as = S[a]
            local local_t = t - ph.start - as.startDelay
            if local_t >= 0 then
                local p = as.duration > 0 and math.min(1, local_t / as.duration) or 1
                applyAnim(a, p)
            end
        end
    end
end

local function advanceGroup(ag, dt)
    local s = S[ag]
    if s.paused then return end
    -- Groups on hidden regions don't advance (UNVERIFIED: the client also pauses them).
    if not isVisible(s.parent) then return end
    local total = Emu.AnimGroupDuration(ag)
    s.elapsed = s.elapsed + dt * (s.speed or 1)
    local backwards = s.reverse ~= (s.bounceBack or false)
    if s.elapsed >= total or total <= 0 then
        if s.looping == "REPEAT" then
            s.elapsed = total > 0 and (s.elapsed % total) or 0
            Emu.RunAnimScript(ag, "OnLoop", "FORWARD")
        elseif s.looping == "BOUNCE" then
            s.elapsed = total > 0 and (s.elapsed % total) or 0
            s.bounceBack = not s.bounceBack
            Emu.RunAnimScript(ag, "OnLoop", s.bounceBack and "REVERSE" or "FORWARD")
        else
            applyGroupAt(ag, total, backwards)
            s.playing = false
            s.done = true
            playingGroups[ag] = nil
            clearAnimEffects(ag, s.toFinalAlpha)
            Emu.RunAnimScript(ag, "OnFinished", false)
            return
        end
        backwards = s.reverse ~= (s.bounceBack or false)
    end
    applyGroupAt(ag, s.elapsed, backwards)
    touch()
end

---------------------------------------------------------------------------
-- OnUpdate + tick
---------------------------------------------------------------------------
local onUpdateFrames = {}
function Emu.UpdateOnUpdateList(f)
    onUpdateFrames[f] = S[f].scripts.OnUpdate and true or nil
end

local lastTick
-- Called by JS. Returns: needsAnimationFrame (bool), seconds until the next timer (or nil).
function Emu.Tick()
    local now = Emu.Now()
    local dt = lastTick and (now - lastTick) or 0
    lastTick = now
    runTimers(now)
    local busy = false
    for ag in pairs(playingGroups) do
        advanceGroup(ag, dt)
        -- Groups on hidden regions are paused, so they don't keep animation frames coming.
        if playingGroups[ag] and isVisible(S[ag].parent) then busy = true end
    end
    local updates = {}
    for f in pairs(onUpdateFrames) do
        if isVisible(f) then updates[#updates + 1] = f end
    end
    table.sort(updates, function(a, b) return S[a].id < S[b].id end)
    for _, f in ipairs(updates) do
        if S[f].scripts.OnUpdate then
            Emu.RunScript(f, "OnUpdate", dt)
            busy = true
        end
    end
    if not busy then lastTick = nil end
    Emu.RefreshHover()
    local due = nextTimerDue()
    return busy, due and math.max(0, due - Emu.Now()) or nil
end

---------------------------------------------------------------------------
-- Draw order
---------------------------------------------------------------------------
local raiseCounter = 0
function Emu.NextRaise()
    raiseCounter = raiseCounter + 1
    return raiseCounter
end

local orderedFrames, orderedGen = {}, -1

-- Visible frames, bottom to top.
local function frameOrder()
    local list = {}
    local function visit(f)
        local s = S[f]
        if not s.shown then return end
        list[#list + 1] = f
        for _, c in ipairs(s.children) do visit(c) end
    end
    for _, f in ipairs(Emu.allFrames) do
        if not S[f].parent then visit(f) end
    end
    local strataIndex, effectiveStrata = Emu.STRATA_INDEX, Emu.EffectiveStrata
    local key = {}
    for _, f in ipairs(list) do
        local s = S[f]
        key[f] = { strataIndex[effectiveStrata(f)], s.level or 0, s.raiseOrder or 0, s.id }
    end
    table.sort(list, function(a, b)
        local ka, kb = key[a], key[b]
        for i = 1, 4 do
            if ka[i] ~= kb[i] then return ka[i] < kb[i] end
        end
        return false
    end)
    return list
end
Emu.FrameOrder = frameOrder

---------------------------------------------------------------------------
-- Rendering: Lua walks the scene and sends draw commands to JS (render.js).
---------------------------------------------------------------------------
local LAYERS = Emu.LAYERS

-- Animation translation/scale of o and its ancestors, applied to an absolute rect.
local function animTransform(o, l, b, w, h)
    local node = o
    while node do
        local s = S[node]
        if s.animScale or s.animOffset then
            local nl, nb, nw, nh = absRect(node)
            local sc = Emu.EffectiveScale(node)
            if s.animScale and nl then
                local ox, oy = nl + nw / 2, nb + nh / 2
                local origin = s.animScale.origin
                if origin then
                    local f = Emu.POINTS[origin[1]] or { 0.5, 0.5 }
                    ox, oy = nl + f[1] * nw + origin[2] * sc, nb + f[2] * nh + origin[3] * sc
                end
                local sx, sy = s.animScale[1], s.animScale[2]
                l, b = ox + (l - ox) * sx, oy + (b - oy) * sy
                w, h = w * sx, h * sy
            end
            if s.animOffset then
                l, b = l + s.animOffset[1] * sc, b + s.animOffset[2] * sc
            end
        end
        node = s.parent
    end
    return l, b, w, h
end

-- Intersection of the rects of every ancestor that clips its children.
local function clipRect(f)
    local cl, cb, cr, ct
    local node = S[f].parent
    while node do
        local s = S[node]
        if s.clips then
            local l, b, w, h = absRect(node)
            if l then
                if not cl then cl, cb, cr, ct = l, b, l + w, b + h
                else
                    cl, cb = math.max(cl, l), math.max(cb, b)
                    cr, ct = math.min(cr, l + w), math.min(ct, b + h)
                end
            end
        end
        node = s.parent
    end
    return cl, cb, cr, ct
end

-- Button state textures: which of normal/pushed/disabled/highlight/checked show now.
local function stateTextureVisible(fs, rs)
    local key = rs.stateKey
    if not fs.stateTextures or fs.stateTextures[key] ~= rs.self then return true end
    local disabled, pushed, checked = fs.disabled, fs.pushed, fs.checked
    if key == "normal" then
        if disabled and fs.stateTextures.disabled then return false end
        if pushed and fs.stateTextures.pushed then return false end
        return true
    elseif key == "pushed" then return pushed and not disabled
    elseif key == "disabled" then return disabled
    elseif key == "highlight" then return not disabled
    elseif key == "checked" then return checked and not (disabled and fs.stateTextures.disabledChecked)
    elseif key == "disabledChecked" then return checked and disabled
    end
    return true
end

local function drawTexture(t, ts, l, b, w, h, alpha)
    local v = ts.vertex or { 1, 1, 1, 1 }
    local a = alpha * v[4]
    if a <= 0 then return end
    local tc = ts.texCoord or { 0, 1, 0, 1 }
    if ts.gradient then
        local g = ts.gradient
        __js("drawGradient", l, b, w, h, g.orientation,
            g[1][1] * v[1], g[1][2] * v[2], g[1][3] * v[3], g[1][4] * a,
            g[2][1] * v[1], g[2][2] * v[2], g[2][3] * v[3], g[2][4] * a, ts.blend or "BLEND")
    elseif ts.color then
        local c = ts.color
        __js("drawColor", l, b, w, h, c[1] * v[1], c[2] * v[2], c[3] * v[3], c[4] * a, ts.blend or "BLEND")
    elseif ts.file or ts.atlas then
        local src = ts.atlas and ("atlas:" .. ts.atlas) or tostring(ts.file)
        __js("drawImage", l, b, w, h, src, v[1], v[2], v[3], a, ts.desaturation or 0,
            tc[1], tc[2], tc[3], tc[4], ts.blend or "BLEND", ts.rotation or 0)
    end
end

local function drawFontString(fsObj, s, l, b, w, h, alpha, scale)
    local text = s.text
    if not text or text == "" then return end
    local font = Emu.FontValue
    local file, size, flags = fsObj:GetFont()
    local c = font(fsObj, "textColor") or { 1, 1, 1, 1 }
    local v = s.vertex or { 1, 1, 1, 1 }
    local a = alpha * (c[4] or 1) * v[4]
    if a <= 0 then return end
    local sc = font(fsObj, "shadowColor") or { 0, 0, 0, 0 }
    local so = font(fsObj, "shadowOffset") or { 0, 0 }
    local wrapWidth = (s.width and s.width > 0) and w or (#s.points > 1 and w or 0)
    __js("drawText", l, b, w, h, text, file or "", (size or 12) * (s.textScale or 1) * scale, flags or "",
        c[1] * v[1], c[2] * v[2], c[3] * v[3], a,
        font(fsObj, "justifyH") or "CENTER", font(fsObj, "justifyV") or "MIDDLE",
        sc[1], sc[2], sc[3], (sc[4] or 1) * a, so[1] * scale, so[2] * scale,
        s.wordWrap ~= false and wrapWidth or 0, s.nonSpaceWrap or false, (font(fsObj, "spacing") or 0) * scale, s.maxLines or 0)
end

function Emu.Render()
    Emu.dirty = false
    local frames = frameOrder()
    orderedFrames = frames
    __js("beginFrame", Emu.screenW, Emu.screenH)
    local currentClip = false
    for _, f in ipairs(frames) do
        local fs = S[f]
        local cl, cb, cr, ct = clipRect(f)
        if fs.clips then
            local l, b, w, h = absRect(f)
            if l then
                if cl then
                    cl, cb, cr, ct = math.max(cl, l), math.max(cb, b), math.min(cr, l + w), math.min(ct, b + h)
                else
                    cl, cb, cr, ct = l, b, l + w, b + h
                end
            end
        end
        local clipKey = cl and (cl .. "," .. cb .. "," .. cr .. "," .. ct) or false
        if clipKey ~= currentClip then
            if cl then __js("setClip", cl, cb, math.max(0, cr - cl), math.max(0, ct - cb)) else __js("setClip") end
            currentClip = clipKey
        end
        local regions = {}
        local highlight = (Emu.hovered == f and not fs.disabled) or fs.highlightLocked
        for _, r in ipairs(fs.regions) do
            local rs = S[r]
            if rs.shown and rs.objectType ~= "MaskTexture" and (rs.layer ~= "HIGHLIGHT" or highlight) then
                rs.self = r
                if not rs.stateKey or stateTextureVisible(fs, rs) then
                    regions[#regions + 1] = r
                end
            end
        end
        table.sort(regions, function(a, b)
            local sa, sb = S[a], S[b]
            local la, lb = LAYERS[sa.layer] or 3, LAYERS[sb.layer] or 3
            if la ~= lb then return la < lb end
            if sa.sublevel ~= sb.sublevel then return sa.sublevel < sb.sublevel end
            return sa.id < sb.id
        end)
        local frameAlpha = Emu.EffectiveAlpha(f)
        for _, r in ipairs(regions) do
            local rs = S[r]
            local l, b, w, h = absRect(r)
            if l and w > 0 and h > 0 then
                l, b, w, h = animTransform(r, l, b, w, h)
                local alpha = (rs.animAlpha or rs.alpha) * (rs.ignoreParentAlpha and 1 or frameAlpha)
                if alpha > 0 then
                    if rs.objectType == "FontString" then
                        drawFontString(r, rs, l, b, w, h, alpha, Emu.EffectiveScale(r))
                    else
                        drawTexture(r, rs, l, b, w, h, alpha)
                    end
                end
            end
        end
    end
    __js("endFrame")
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function hitTest(x, y, wantWheel)
    local frames = orderedFrames
    for i = #frames, 1, -1 do
        local f = frames[i]
        local s = S[f]
        if (wantWheel and s.mouseWheel or s.mouse) and not s.isScreen and isVisible(f) then
            local l, b, w, h = absRect(f)
            if l then
                local sc = Emu.EffectiveScale(f)
                local ins = s.hitInsets or { 0, 0, 0, 0 }
                if x >= l + ins[1] * sc and x <= l + w - ins[2] * sc and y >= b + ins[4] * sc and y <= b + h - ins[3] * sc then
                    return f
                end
            end
        end
    end
end

function Emu.RefreshHover()
    if Emu.dirty then orderedFrames = frameOrder() end
    local target = Emu.moving and Emu.hovered or hitTest(Emu.mouseX, Emu.mouseY)
    if target ~= Emu.hovered then
        local old = Emu.hovered
        Emu.hovered = target
        touch()
        if old and S[old] then Emu.RunScript(old, "OnLeave", true) end
        if target then Emu.RunScript(target, "OnEnter", true) end
    end
end

function Emu.OnFrameHidden(f)
    if Emu.pressed == f then Emu.pressed = nil end
end

local function clampToScreen(f, l, b)
    local _, _, w, h = absRect(f)
    l = math.max(0, math.min(Emu.screenW - w, l))
    b = math.max(0, math.min(Emu.screenH - h, b))
    return l, b
end

function Emu.MouseMove(x, y)
    Emu.mouseX, Emu.mouseY = x, y
    local m = Emu.moving
    if m then
        local f = m.frame
        local l, b = x + m.dx, y + m.dy
        if S[f].clamped then l, b = clampToScreen(f, l, b) end
        local _, _, w, h = absRect(f)
        local sc = Emu.EffectiveScale(f)
        -- Re-anchored like the client does while moving: TOPLEFT relative to UIParent's BOTTOMLEFT.
        S[f].points = {}
        f:SetPoint("TOPLEFT", Emu.UIParent, "BOTTOMLEFT", l / sc, (b + h) / sc)
        S[f].userPlaced = true
    elseif Emu.pressed and not Emu.dragging then
        local p = Emu.pressed
        local ps = S[p]
        local dx, dy = x - Emu.pressX, y - Emu.pressY
        local pixels = math.sqrt(dx * dx + dy * dy) * (Emu.pixelsPerUnit or 1)
        if ps.dragButtons and ps.dragButtons[Emu.pressButton] and pixels >= Emu.config.dragThreshold then
            Emu.dragging = p
            Emu.RunScript(p, "OnDragStart", Emu.pressButton)
        end
    end
    Emu.RefreshHover()
end

local function clickRegistered(f, button, down)
    local c = S[f].clicks
    if not c then return false end
    local suffix = down and "Down" or "Up"
    return c[button .. suffix] or c["Any" .. suffix] or false
end

function Emu.DoClick(f, button, down)
    local s = S[f]
    if s.disabled then return end
    if s.objectType == "CheckButton" then
        s.checked = not s.checked
        touch()
    end
    Emu.RunScript(f, "PreClick", button, down)
    Emu.RunScript(f, "OnClick", button, down)
    Emu.RunScript(f, "PostClick", button, down)
end

function Emu.MouseDown(button)
    Emu.FireEvent("GLOBAL_MOUSE_DOWN", button)
    local f = Emu.hovered
    if not f then return end
    Emu.pressed, Emu.pressButton, Emu.pressX, Emu.pressY = f, button, Emu.mouseX, Emu.mouseY
    if S[f].clicks and not S[f].disabled then
        S[f].pushed = true
        touch()
    end
    Emu.RunScript(f, "OnMouseDown", button)
    if S[f].clicks and clickRegistered(f, button, true) then Emu.DoClick(f, button, true) end
end

function Emu.MouseUp(button)
    Emu.FireEvent("GLOBAL_MOUSE_UP", button)
    local p = Emu.pressed
    Emu.pressed = nil
    if Emu.dragging then
        local d = Emu.dragging
        Emu.dragging = nil
        if S[d] then Emu.RunScript(d, "OnDragStop") end
    end
    if not p or not S[p] then return end
    if S[p].pushed then
        S[p].pushed = false
        touch()
    end
    local inside = p:IsMouseOver()
    Emu.RunScript(p, "OnMouseUp", button, inside)
    if inside and S[p].clicks and clickRegistered(p, button, false) then Emu.DoClick(p, button, false) end
    Emu.RefreshHover()
end

function Emu.MouseWheel(delta)
    local f = hitTest(Emu.mouseX, Emu.mouseY, true)
    if f then Emu.RunScript(f, "OnMouseWheel", delta) end
end

function GetCursorPosition() return Emu.mouseX, Emu.mouseY end
function GetMouseFoci() return Emu.hovered and { Emu.hovered } or {} end
function GetMouseFocus() return Emu.hovered end
function IsMouseButtonDown(button) return Emu.pressed ~= nil end
function IsShiftKeyDown() return Emu.modShift or false end
function IsControlKeyDown() return Emu.modCtrl or false end
function IsAltKeyDown() return Emu.modAlt or false end
function IsModifierKeyDown() return IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown() end

---------------------------------------------------------------------------
-- Inspector: frames under the cursor, top first (including mouse-disabled ones).
---------------------------------------------------------------------------
local function debugName(o)
    local s = S[o]
    if s.name then return s.name end
    local p = s.parent
    if p then
        for k, v in pairs(p) do
            if v == o and type(k) == "string" then return debugName(p) .. "." .. k end
        end
        return debugName(p) .. ".<" .. s.objectType .. ">"
    end
    return "<anonymous " .. s.objectType .. ">"
end
Emu.DebugName = debugName

function Emu.InspectAt(x, y)
    local frames = frameOrder()
    for i = #frames, 1, -1 do
        local f = frames[i]
        local s = S[f]
        if not s.isScreen and isVisible(f) then
            local l, b, w, h = absRect(f)
            if l and w > 0 and h > 0 and x >= l and x <= l + w and y >= b and y <= b + h then
                local sc = Emu.EffectiveScale(f)
                local info = ("%s (%s)\nstrata %s, level %d, scale %.2f, alpha %.2f\nleft %.1f, top %.1f, size %.1f x %.1f\nmouse %s%s"):format(
                    debugName(f), s.objectType, Emu.EffectiveStrata(f), s.level or 0, sc, Emu.EffectiveAlpha(f),
                    l / sc, (b + h) / sc, w / sc, h / sc, s.mouse and "on" or "off",
                    Emu.hovered == f and " (hovered)" or "")
                return info, l, b, w, h
            end
        end
    end
end

function Emu.IsDirty() return Emu.dirty end
