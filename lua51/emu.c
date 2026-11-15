/*
 * Glue between the unmodified Lua 5.1.5 core (src/) and the browser.
 *
 * - emu_new(): a fresh lua_State with the standard libs, plus
 *     __js(name, ...)  calls a JS handler registered in vm.js (Module.__luaDispatch)
 *     bit.*            WoW's bit library (32-bit ops, see l_bit_* below)
 * - Everything else (pushing args, pcall, reading results) is done from JS
 *   through the exported raw Lua C API, see build.ps1 for the export list.
 */
#include <stdint.h>
#include <emscripten.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Returns the number of results it pushed, or -1 with an error message on
 * top of the stack (a JS exception must not unwind through Lua frames). */
EM_JS(int, js_dispatch, (lua_State *L), {
    return Module.__luaDispatch(L);
});

static int l_js(lua_State *L) {
    int n = js_dispatch(L);
    if (n < 0) return lua_error(L);
    return n;
}

/* WoW's bit library. Arguments are truncated to 32 bits; results are
 * returned as unsigned 32-bit numbers (e.g. bit.bnot(0) == 4294967295).
 * UNVERIFIED: signedness of results in the current client. */
static uint32_t barg(lua_State *L, int i) {
    lua_Number n = luaL_checknumber(L, i);
    return (uint32_t)(int64_t)n;
}
static int bret(lua_State *L, uint32_t v) { lua_pushnumber(L, (lua_Number)v); return 1; }

static int l_band(lua_State *L) { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v &= barg(L, i); return bret(L, v); }
static int l_bor(lua_State *L)  { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v |= barg(L, i); return bret(L, v); }
static int l_bxor(lua_State *L) { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v ^= barg(L, i); return bret(L, v); }
static int l_bnot(lua_State *L) { return bret(L, ~barg(L, 1)); }
static int l_lshift(lua_State *L) { return bret(L, barg(L, 1) << (barg(L, 2) & 31)); }
static int l_rshift(lua_State *L) { return bret(L, barg(L, 1) >> (barg(L, 2) & 31)); }
static int l_arshift(lua_State *L) { return bret(L, (uint32_t)((int32_t)barg(L, 1) >> (barg(L, 2) & 31))); }
static int l_mod(lua_State *L) {
    uint32_t b = barg(L, 2);
    if (b == 0) return luaL_error(L, "bit.mod: division by zero");
    return bret(L, barg(L, 1) % b);
}

static const luaL_Reg bitlib[] = {
    {"band", l_band}, {"bor", l_bor}, {"bxor", l_bxor}, {"bnot", l_bnot},
    {"lshift", l_lshift}, {"rshift", l_rshift}, {"arshift", l_arshift}, {"mod", l_mod},
    {NULL, NULL}
};

EMSCRIPTEN_KEEPALIVE
lua_State *emu_new(void) {
    lua_State *L = luaL_newstate();
    if (!L) return NULL;
    luaL_openlibs(L);
    luaL_register(L, "bit", bitlib);
    lua_pop(L, 1);
    lua_register(L, "__js", l_js);
    return L;
}
