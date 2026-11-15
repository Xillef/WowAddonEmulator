-- Emulator internals shared by every wowlua file. Loaded first.
-- __Emu is the emulator's own namespace; addon code never needs it, scenario files do.

__Emu = {
    config = {
        -- UNVERIFIED (to check in-game): does SetScript() drop hooks added earlier with
        -- HookScript()? true = yes (hooks are lost), false = hooks keep running.
        setScriptClearsHooks = true,
        -- UNVERIFIED: does SetScript("OnEnter"/"OnLeave"/"OnMouseDown"/...) on a plain
        -- Frame enable mouse input by itself?
        mouseScriptsEnableMouse = true,
        -- Pixels the cursor has to move with a button held before OnDragStart fires.
        -- UNVERIFIED (client value unknown).
        dragThreshold = 4,
    },
    allFrames = {},
    dirty = true,
    loggedIn = false,
    mouseX = 0, mouseY = 0,
    screenW = 1024, screenH = 768,
}
local Emu = __Emu

local traceback = debug.traceback

function Emu.Now() return __js("now") end

-- Message + stack, like BugSack shows it. Used as the xpcall handler everywhere.
function Emu.ErrorTraceback(msg)
    return traceback(tostring(msg), 2)
end

function Emu.ReportError(msg)
    msg = tostring(msg)
    if not msg:find("\nstack traceback:", 1, true) then
        msg = traceback(msg, 2)
    end
    __js("error", msg)
end

function Emu.Chat(text) __js("chat", text) end

-- Calls fn(...) and reports an error instead of raising it.
function Emu.SafeCall(fn, ...)
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, Emu.ErrorTraceback)
    if not ok then Emu.ReportError(err) end
    return ok
end

-- "Real WoW API, not emulated": a no-op stub that logs each call (shown in the page).
local stubCache = {}
function Emu.Stub(label)
    local fn = stubCache[label]
    if not fn then
        fn = function() __js("stub", label) end
        stubCache[label] = fn
    end
    return fn
end
