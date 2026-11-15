# WoW Addon Emulator

Runs a World of Warcraft addon's **real Lua files** in the browser, against a fake WoW
frame API, and draws the result on a canvas. Saving an addon file reloads the page
(like `/reload` in the game), so UI changes can be checked without starting WoW.

The Lua is real Lua 5.1.5 (the game's version) compiled to WebAssembly, so language
behavior matches the client. The WoW API around it is emulated. **The game stays the
final check**: "works in the emulator" never means "works in the game".

Status: v1. Verified with the PreDungeonChecklist checklist popup.

## Run

Needs Node.js (18+). No install step, no dependencies.

```bash
node server.js --addon "K:/Projekte/VibeLab/WoW/PreDungeonChecklist/PreDungeonChecklist"
```

Then open http://localhost:8642/. The addon folder name must be the addon name, with
`<Name>.toc` inside (as in `Interface/AddOns/<Name>`). Instead of `--addon` you can
put the folders in `emulator.config.local.json` (gitignored):

```json
{ "addons": ["K:/Projekte/VibeLab/WoW/PreDungeonChecklist/PreDungeonChecklist"], "port": 8642 }
```

The server only listens on 127.0.0.1, serves the addon read-only and never writes to
it. It watches the addon folder, `scenarios/` and `src/`; any save reloads the page.

### The page

- **Screen / UI scale**: the emulated monitor (default 1920×1080, pixel-perfect UI
  scale = 768 / height).
- **Zoom and pan** (only the view; nothing reaches the game):
  - Ctrl+wheel or Alt+wheel (or a trackpad pinch) zooms at the cursor, from 5 % to 3200 %.
    A plain wheel goes to the game (`OnMouseWheel`).
  - Ctrl+plus / Ctrl+minus zoom in steps, Ctrl+0 fits the screen in the window, Ctrl+1
    is 100 % (one screen pixel per CSS pixel). The toolbar buttons (− 100% + Fit) do the same.
  - Space+drag, Shift+drag or middle-drag pans. The zoom level is remembered.
  - Zooming in redraws text, colors and placeholders sharp at the larger size; it
    doesn't show the game's actual screen pixels. Images from `assets-local/` are scaled
    up (smoothed).
- **Lua errors**: every error with its stack, counted like BugSack. Errors in a file
  don't stop the next file from loading (same as the game).
- **Not emulated (stub calls)**: real WoW API functions/methods that were called but
  aren't emulated. They return nothing. If one matters for what you're checking, it
  needs implementing.
- **Secure actions (not run)**: clicks on secure buttons (`SecureActionButtonTemplate`)
  with their attributes, e.g. `type=item, item=item:242275`.
- **Chat**: `print()` and `SendChatMessage` output.
- **Inspect**: hover shows the frame under the cursor (name, strata, level, scale, rect).
- **Lua console** (bottom): `/pdc` runs a slash command, `=expr` prints a value, anything
  else runs as Lua. `__Emu` is the emulator's own namespace.

### Headless (no browser)

```bash
node tools/headless.mjs "K:/Projekte/VibeLab/WoW/PreDungeonChecklist/PreDungeonChecklist" PreDungeonChecklist scenarios/PreDungeonChecklist/checklist.lua --frames
```

Prints errors, chat, stub calls and (with `--frames`) every visible frame with its
rect. Text widths are rough estimates there (no canvas).

## Scenarios

A scenario (`scenarios/<Addon>/<name>.lua`) fakes the game state and says what to open.
It runs before the addon's files, like the game's own state exists before addons load.

```lua
local Emu = __Emu
Emu.SetPlayer { name = "Emberlyn", specID = 63 }          -- Fire Mage
Emu.SetGroup { { name = "Stonewall", class = "WARRIOR", role = "TANK" } }
Emu.SetInstance { name = "Some Dungeon", type = "party", difficultyID = 23 }
Emu.AddItem(241322, { name = "Flask of the Magisters", count = 2, bag = 0, slot = 1 })
Emu.AddAura("player", { name = "Flask of the Magisters", spellId = 1235110, duration = 3600, expiresIn = 2400 })
Emu.SetWeaponEnchant { mainHand = { expiresIn = 240 } }
Emu.SetInventorySlot(5, { itemID = 100005, durability = { 40, 100 } })
Emu.SetSavedVariables { MyAddonDB = { ... } }             -- assigned before ADDON_LOADED
Emu.OnLogin(function() Emu.RunSlashCommand("/pdc") end)   -- after PLAYER_ENTERING_WORLD
```

All helpers are in `src/wowlua/gameapi.lua`. A scenario can also replace any API
function directly (`function C_Item.GetItemCount(id) return 3 end`).

Load order per (re)load: WoW environment → scenario → addon files in `.toc` order with
`...` = `(addonName, ns)` → SavedVariables → `ADDON_LOADED` → `SPELLS_CHANGED`,
`PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD(true, false)` → scenario `OnLogin` steps.
SavedVariables start empty on every reload (a fresh install), unless the scenario
presets them.

## Fonts and textures (assets-local/)

Blizzard's font and textures can't be shipped. The repo ships **Marcellus** (SIL OFL,
`assets/fonts/`) as a free look-alike for Friz Quadrata. For exact text metrics, copy
your own files from the game into the gitignored `assets-local/`:

```
assets-local/fonts/FRIZQT__.TTF     (also ARIALN.TTF, MORPHEUS.TTF, SKURRI.TTF)
assets-local/map.json               texture path, fileID or "atlas:<name>" -> png
assets-local/icons/...              the png files map.json points to
```

`map.json` example (keys are case-insensitive, `\` or `/`, extension optional):

```json
{
  "interface/icons/inv_misc_questionmark": "icons/questionmark.png",
  "134400": "icons/questionmark.png",
  "atlas:Professions-ChatIcon-Quality-Tier2": "icons/tier2.png"
}
```

Without a mapping, textures are placeholders: icons are gray boxes with "?", atlases a
box with "A". Checkbox and options-button textures get simple drawn stand-ins.

## How it works

```
lua51/          Lua 5.1.5 source (unmodified) + emu.c glue + build.ps1 -> dist/lua51.{js,wasm}
dist/           build output (committed; rebuilding needs Emscripten, see below)
src/vm.js       JS <-> Lua bridge over the raw Lua C API (__js(name, ...) calls into JS)
src/emulator.js one session: fresh Lua state, WoW env, scenario, addon, login events
src/toc.js      .toc parser
src/render.js   Canvas2D: colors, gradients, textures/placeholders, WoW text (|c..|r, wrap)
src/main.js     the page: canvas, mouse, panels, hot reload, inspector, console
src/wowlua/     the WoW environment, in Lua (loaded in this order):
  core.lua        __Emu namespace, error reporting, stubs, config switches
  globals.lua     WoW's Lua additions (strsplit, wipe, Mixin, hooksecurefunc, ...) + sandbox
  generated/      enum.lua (Enum.*, Constants.*) and apinames.lua (real API names)
  widgets.lua     Region/Frame/Texture/FontString/Button/... objects, anchor layout, animations
  runtime.lua     CreateFrame, events, C_Timer, animation/OnUpdate driver, input, render pass
  templates.lua   font objects, BackdropTemplate, UICheckButtonTemplate, GameTooltip, pools, UIParent
  gameapi.lua     fake game state + the unit/item/aura/spell/instance APIs that read it
  boot.lua        addon loading, SavedVariables, login sequence, slash commands
  stubs.lua       fallback: real API names -> logged stubs, unknown names stay nil
server.js       static server + read-only addon serving + file watcher (SSE)
tools/          headless.mjs (Node runner), gen-wowapi.mjs (regenerates generated/)
```

Rendering is on demand: Lua marks changes dirty. Animation frames are only requested
while an animation or a visible `OnUpdate` script is running; `C_Timer` timers are
woken with `setTimeout`. A page with nothing animating does no work.

### Unknown APIs

`tools/gen-wowapi.mjs` reads Ketho's vscode-wow-api annotations (MIT; a mirror of
Blizzard's API documentation) and writes the list of real API names. A call to a real
but unemulated function or widget method is a logged no-op stub. A name that doesn't
exist in WoW stays `nil` and errors like in-game. Regenerate after a patch:

```bash
node tools/gen-wowapi.mjs "C:/Users/Robert Langdon/lua-tools/vscode-wow-api/Annotations/Core"
```

### Rebuilding Lua (only after changing lua51/emu.c)

Needs Emscripten (emsdk). Install used here: `K:\Tools\emsdk` (`emsdk install latest`,
`emsdk activate latest`, not `--permanent`). Then:

```bash
powershell -ExecutionPolicy Bypass -File lua51/build.ps1
```

`-Emsdk <path>` or `$env:EMSDK` picks a different emsdk folder.

## Fidelity: what matches the game and what doesn't

Checked against Blizzard's UI source (Gethe/wow-ui-source, live branch, Nov 2026):
- GameFontNormal = FRIZQT height 12, GameFontNormalSmall = height 10, both with a black
  (1, -1) shadow; tooltip fonts 14/12/10 (`Blizzard_Fonts_Shared`).
- BackdropTemplate builds the same 9 textures (4 corners + 4 edges on BORDER, `Center`
  on BACKGROUND, inset by `insets`, default edge size 39), stored on the frame under
  the same keys.
- UICheckButtonTemplate: 32×32 with its `Text` font string at LEFT → RIGHT (-2, 0).

Known gaps:
- **Only part of the API is emulated.** What PreDungeonChecklist's checklist popup uses
  is implemented; everything else is a logged stub (see the panel). The config window
  (v2) needs more, including `SetGradient` checked against the client.
- **Text metrics**: without your own FRIZQT__.TTF, string widths differ slightly, so
  measured widths (and windows sized from them) can be a few pixels off. Wrapping,
  `...` truncation and line height are approximations of the client's.
- **Textures**: only solid colors, WHITE8x8 files and gradients are exact. Everything
  else is a placeholder unless mapped in `assets-local/map.json`. Atlas sizes
  (`useAtlasSize`) are a generic 32×32. Texture rotation, masks, tiling, flipbooks and
  rotation animations aren't drawn.
- **No secure/taint model, no combat lockdown.** Secure clicks are logged, not run.
- **Game data is fake**: unknown spell IDs return a generic "Spell <id>"; the item,
  aura, group and instance data come from the scenario.
- **XML files** in a `.toc` aren't loaded (reported as an error).
- Tooltips: the look is a placeholder (dark blue box, gray border); default line
  colors, padding and wrap width are approximations.

Behaviors marked **UNVERIFIED** in the code (the emulator picks one; check in-game):
- Does `SetScript` drop hooks added earlier with `HookScript`? Here: yes
  (`__Emu.config.setScriptClearsHooks`). Relevant for PreDungeonChecklist UI.lua:884/956.
- Does `SetScript("OnEnter"/"OnLeave"/"OnMouseDown"/...)` enable mouse input by itself?
  Here: yes (`__Emu.config.mouseScriptsEnableMouse`).
- Over-constrained anchors (e.g. LEFT + RIGHT + TOP): edge anchors win over center
  anchors, then the explicit size.
- `SetFrameLevel` raises children that would end up at or below the parent.
- Animation groups on hidden regions pause.
- Drag threshold (4 px), where a moved frame is re-anchored (TOPLEFT to UIParent's
  BOTTOMLEFT), `bit.*` results are unsigned 32-bit.
- `GameTooltip:SetText` without a color is white, `AddLine` without a color is gold.
- Unparented regions use UIParent's scale.

## Licenses

Emulator code: no license chosen yet. Lua 5.1.5: MIT (`lua51/COPYRIGHT`). Marcellus font: SIL OFL 1.1
(`assets/fonts/OFL-Marcellus.txt`). `src/wowlua/generated/` is generated from
Ketho/vscode-wow-api (MIT).
