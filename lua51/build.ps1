# Builds the unmodified Lua 5.1.5 core (src/) + emu.c to WebAssembly:
#   dist/lua51.js + dist/lua51.wasm  (committed; only needed again after changing emu.c)
# Needs Emscripten (emsdk). Set $env:EMSDK or pass -Emsdk; default K:\Tools\emsdk.
param([string]$Emsdk = $(if ($env:EMSDK) { $env:EMSDK } else { "K:\Tools\emsdk" }))
$env:EMSDK_QUIET = "1"
. (Join-Path $Emsdk "emsdk_env.ps1") | Out-Null
# emcc prints info lines to stderr; failures are detected via $LASTEXITCODE below.
if (-not (Get-Command emcc -ErrorAction SilentlyContinue)) { throw "emcc not found under $Emsdk" }

$here = $PSScriptRoot
$dist = Join-Path (Split-Path $here) "dist"
New-Item -ItemType Directory -Force $dist | Out-Null

# lua.c / luac.c / print.c are the standalone interpreter/compiler, not the library.
$sources = Get-ChildItem (Join-Path $here "src") -Filter *.c |
    Where-Object { $_.Name -notin @("lua.c", "luac.c", "print.c") } |
    ForEach-Object { $_.FullName }

$exports = @(
    "_emu_new", "_lua_close", "_malloc", "_free",
    "_lua_gettop", "_lua_settop", "_lua_type", "_lua_pushvalue", "_lua_remove", "_lua_insert",
    "_lua_tolstring", "_lua_tonumber", "_lua_toboolean", "_lua_topointer",
    "_lua_pushnil", "_lua_pushnumber", "_lua_pushlstring", "_lua_pushboolean",
    "_lua_getfield", "_lua_setfield", "_lua_rawgeti", "_lua_objlen",
    "_lua_pcall", "_luaL_loadbuffer"
) -join ","

$emccArgs = @(
    "-O2", "-I", (Join-Path $here "src")
) + $sources + @(
    (Join-Path $here "emu.c"),
    "-o", (Join-Path $dist "lua51.js"),
    "-sMODULARIZE=1", "-sEXPORT_NAME=createLua51",
    "-sENVIRONMENT=web,node",
    "-sALLOW_MEMORY_GROWTH=1",
    "-sEXPORTED_FUNCTIONS=$exports",
    "-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF64"
)

& emcc @emccArgs
if ($LASTEXITCODE -ne 0) { throw "emcc failed ($LASTEXITCODE)" }
Get-ChildItem $dist | Format-Table Name, Length
