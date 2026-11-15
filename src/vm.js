// Thin JS <-> Lua bridge over the raw Lua 5.1 C API exported by dist/lua51.js.
// Works in the browser and in Node (headless checks).
//
// Values crossing the bridge: nil/undefined, boolean, number, string. Lua strings are
// byte strings; they are decoded/encoded as UTF-8 here (addon files are UTF-8).

const LUA_REGISTRYINDEX = -10000;
const LUA_GLOBALSINDEX = -10002;
const LUA_MULTRET = -1;
const T = { NONE: -1, NIL: 0, BOOLEAN: 1, LIGHTUSERDATA: 2, NUMBER: 3, STRING: 4, TABLE: 5, FUNCTION: 6 };

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8");

export class LuaError extends Error {}

export class LuaVM {
  // M: an instantiated Emscripten module (createLua51()). One VM is active per module
  // at a time (__js dispatch goes to the newest one); close() the old one first.
  constructor(M) {
    this.M = M;
    this.L = M._emu_new();
    if (!this.L) throw new Error("emu_new failed (out of memory?)");
    this.handlers = Object.create(null);
    M.__luaDispatch = (L) => this._dispatch(L);
    // Keep debug.traceback in the registry: the WoW env removes the global `debug`.
    this._getGlobal("debug");
    this.M._lua_getfield(this.L, -1, this._cstr("traceback"));
    this.M._lua_setfield(this.L, LUA_REGISTRYINDEX, this._cstr("emu_traceback"));
    this.M._lua_settop(this.L, 0);
  }

  close() {
    if (this.L) this.M._lua_close(this.L);
    this.L = 0;
  }

  // fn(...args) -> undefined | value | array of values (multiple returns)
  register(name, fn) { this.handlers[name] = fn; }

  // Compiles and runs a chunk. Throws LuaError (message incl. traceback) on failure.
  // varargs are passed as `...` to the chunk (WoW passes addonName, ns that way;
  // ns is a table, so that case goes through runWithArgsFrom instead).
  run(code, chunkName = "=chunk") {
    const L = this.L, M = this.M;
    const base = M._lua_gettop(L);
    this._pushTraceback();
    this._load(code, chunkName);
    const st = M._lua_pcall(L, 0, LUA_MULTRET, base + 1);
    return this._finish(st, base);
  }

  // Loads a chunk and calls it with the values returned by calling Lua function `argsFn`
  // (a global path). Used for addon files: `...` = (addonName, ns table).
  runWithArgsFrom(code, chunkName, argsFnPath) {
    const L = this.L, M = this.M;
    const base = M._lua_gettop(L);
    this._pushTraceback();
    this._load(code, chunkName);
    this._pushPath(argsFnPath);
    let st = M._lua_pcall(L, 0, LUA_MULTRET, base + 1);
    if (st !== 0) return this._finish(st, base);
    const nargs = M._lua_gettop(L) - (base + 2);
    st = M._lua_pcall(L, nargs, LUA_MULTRET, base + 1);
    return this._finish(st, base);
  }

  // Calls a global function by dotted path ("__emu.render") with primitive args.
  call(path, ...args) {
    const L = this.L, M = this.M;
    const base = M._lua_gettop(L);
    this._pushTraceback();
    this._pushPath(path);
    for (const a of args) this._push(a);
    const st = M._lua_pcall(L, args.length, LUA_MULTRET, base + 1);
    return this._finish(st, base);
  }

  // ---- internals ----
  _finish(status, base) {
    const L = this.L, M = this.M;
    if (status !== 0) {
      const msg = this._to(-1);
      M._lua_settop(L, base);
      throw new LuaError(String(msg));
    }
    const out = [];
    const top = M._lua_gettop(L);
    for (let i = base + 2; i <= top; i++) out.push(this._to(i));
    M._lua_settop(L, base);
    return out;
  }

  _load(code, chunkName) {
    const M = this.M;
    const bytes = typeof code === "string" ? enc.encode(code) : code;
    const p = M._malloc(bytes.length || 1);
    M.HEAPU8.set(bytes, p);
    const st = M._luaL_loadbuffer(this.L, p, bytes.length, this._cstr(chunkName));
    M._free(p);
    if (st !== 0) {
      // Compile error: message on top. Leave the stack as a function slot would be
      // (pcall will fail on calling a string), simpler: throw right away.
      const msg = this._to(-1);
      M._lua_settop(this.L, M._lua_gettop(this.L) - 2); // pop msg + traceback fn
      throw new LuaError(String(msg));
    }
  }

  _pushTraceback() {
    this.M._lua_getfield(this.L, LUA_REGISTRYINDEX, this._cstr("emu_traceback"));
  }

  _getGlobal(name) { this.M._lua_getfield(this.L, LUA_GLOBALSINDEX, this._cstr(name)); }

  _pushPath(path) {
    const parts = path.split(".");
    this._getGlobal(parts[0]);
    for (let i = 1; i < parts.length; i++) {
      if (this.M._lua_type(this.L, -1) !== T.TABLE) break;
      this.M._lua_getfield(this.L, -1, this._cstr(parts[i]));
      this.M._lua_remove(this.L, -2);
    }
  }

  _dispatch(L) {
    const M = this.M;
    const n = M._lua_gettop(L);
    const name = this._to(1);
    const args = [];
    for (let i = 2; i <= n; i++) args.push(this._to(i));
    try {
      const fn = this.handlers[name];
      if (!fn) throw new Error("__js: no handler '" + name + "'");
      let r = fn(...args);
      M._lua_settop(L, 0);
      if (r === undefined) return 0;
      if (!Array.isArray(r)) r = [r];
      for (const v of r) this._push(v);
      return r.length;
    } catch (e) {
      M._lua_settop(L, 0);
      this._push("[js:" + name + "] " + (e && e.message ? e.message : String(e)));
      return -1;
    }
  }

  _push(v) {
    const M = this.M, L = this.L;
    if (v === undefined || v === null) M._lua_pushnil(L);
    else if (typeof v === "boolean") M._lua_pushboolean(L, v ? 1 : 0);
    else if (typeof v === "number") M._lua_pushnumber(L, v);
    else {
      const bytes = enc.encode(String(v));
      const p = M._malloc(bytes.length || 1);
      M.HEAPU8.set(bytes, p);
      M._lua_pushlstring(L, p, bytes.length);
      M._free(p);
    }
  }

  _to(i) {
    const M = this.M, L = this.L;
    switch (M._lua_type(L, i)) {
      case T.NIL: case T.NONE: return undefined;
      case T.BOOLEAN: return M._lua_toboolean(L, i) !== 0;
      case T.NUMBER: return M._lua_tonumber(L, i);
      case T.STRING: {
        const lenp = this._scratch(4);
        const p = M._lua_tolstring(L, i, lenp);
        const len = M.HEAPU8[lenp] | (M.HEAPU8[lenp + 1] << 8) | (M.HEAPU8[lenp + 2] << 16) | (M.HEAPU8[lenp + 3] << 24);
        return dec.decode(M.HEAPU8.subarray(p, p + len));
      }
      default: return undefined; // tables/functions/userdata don't cross the bridge
    }
  }

  // Small, reused allocations (C strings are cached; they're all short constant names).
  _scratch(n) {
    if (!this._scratchPtr) this._scratchPtr = this.M._malloc(16);
    return this._scratchPtr;
  }

  _cstr(s) {
    this._cstrCache ??= new Map();
    let p = this._cstrCache.get(s);
    if (p === undefined) {
      const bytes = enc.encode(s);
      p = this.M._malloc(bytes.length + 1);
      this.M.HEAPU8.set(bytes, p);
      this.M.HEAPU8[p + bytes.length] = 0;
      this._cstrCache.set(s, p);
    }
    return p;
  }
}
