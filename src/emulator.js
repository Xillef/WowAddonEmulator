// Builds one emulated client session: a fresh Lua state, the WoW environment, the
// scenario and the addon (like a /reload). Shared by the page (main.js) and the
// headless runner (tools/headless.mjs).
//
// host = {
//   fetchText(path) -> Promise<string>   ("emu/..." emulator files, "addon/<Name>/..." addon files,
//                                          "scenarios/..." scenario files)
//   now() -> seconds,  layoutText(...) -> [w, h, lines],  physicalScreenSize() -> [w, h]
//   onError(msg), onChat(msg), onStub(label), onSecure(msg), onReload()
//   draw: { beginFrame, endFrame, setClip, drawColor, drawGradient, drawImage, drawText }
// }
import { LuaVM, LuaError } from "./vm.js";
import { parseToc, savedVariableNames } from "./toc.js";

const WOWLUA = [
  "core.lua", "globals.lua", "generated/enum.lua", "widgets.lua", "runtime.lua",
  "templates.lua", "gameapi.lua", "boot.lua",
];

export class Emulator {
  constructor(M, host) {
    this.M = M;
    this.host = host;
    this.vm = null;
  }

  // Loads everything. Returns { ok, addon } or throws on emulator-internal failures.
  async boot({ addonName, scenarioPath, screen }) {
    const host = this.host;
    if (this.vm) this.vm.close();
    const vm = (this.vm = new LuaVM(this.M));
    vm.register("now", () => host.now());
    vm.register("error", (msg) => host.onError(msg));
    vm.register("chat", (msg) => host.onChat(msg));
    vm.register("stub", (label) => host.onStub(label));
    vm.register("secure", (msg) => host.onSecure(msg));
    vm.register("reload", () => host.onReload());
    vm.register("layoutText", (...a) => host.layoutText(...a));
    vm.register("physicalScreenSize", () => host.physicalScreenSize());
    for (const [name, fn] of Object.entries(host.draw)) vm.register(name, fn);

    // 1. WoW environment
    for (const f of WOWLUA) vm.run(await host.fetchText("emu/src/wowlua/" + f), "@emu/" + f);
    const apinames = await host.fetchText("emu/src/wowlua/generated/apinames.lua");
    vm.run("__Emu.api = (function()\n" + apinames + "\nend)()", "@emu/generated/apinames.lua");
    vm.run(await host.fetchText("emu/src/wowlua/stubs.lua"), "@emu/stubs.lua");
    this.setScreen(screen);

    // 2. Scenario (fake game state, runs before the addon like the game's own state)
    if (scenarioPath) this._runReported(await host.fetchText(scenarioPath), "@" + scenarioPath);

    // 3. Addon files in .toc order, `...` = (addonName, ns)
    const tocText = await host.fetchText(`addon/${addonName}/${addonName}.toc`);
    const toc = parseToc(tocText);
    const metaText = Object.entries(toc.metadata).map(([k, v]) => `${k}\t${v}`).join("\n");
    vm.call("__Emu.BeginAddon", addonName, metaText);
    for (const file of toc.files) {
      if (!file.toLowerCase().endsWith(".lua")) {
        host.onError(`${addonName}: ${file} not loaded (only .lua files are supported, not ${file.split(".").pop()})`);
        continue;
      }
      let code;
      try {
        code = await host.fetchText(`addon/${addonName}/${file}`);
      } catch (e) {
        host.onError(`${addonName}: couldn't open ${file} (${e.message})`);
        continue;
      }
      // In-game a file with an error stops at that point; the next file still loads.
      try {
        vm.runWithArgsFrom(code, `@Interface/AddOns/${addonName}/${file}`, "__Emu.AddonArgs");
      } catch (e) {
        if (!(e instanceof LuaError)) throw e;
        host.onError(e.message);
      }
    }
    vm.call("__Emu.FinishAddon", addonName, savedVariableNames(toc.metadata));

    // 4. Login sequence + the scenario's OnLogin steps
    vm.call("__Emu.Login");
    return { toc };
  }

  setScreen({ absW, absH, uiScale, pixelsPerUnit }) {
    this.vm.call("__Emu.SetScreen", absW, absH, uiScale, pixelsPerUnit);
  }

  // Entry points from the page; each reports Lua errors instead of throwing.
  tick() { return this._call("__Emu.Tick"); }
  render() { return this._call("__Emu.Render"); }
  isDirty() { return this._call("__Emu.IsDirty")?.[0]; }
  mouseMove(x, y) { this._call("__Emu.MouseMove", x, y); }
  mouseDown(button) { this._call("__Emu.MouseDown", button); }
  mouseUp(button) { this._call("__Emu.MouseUp", button); }
  mouseWheel(delta) { this._call("__Emu.MouseWheel", delta); }
  inspectAt(x, y) { return this._call("__Emu.InspectAt", x, y); }
  runLua(code) { return this._run(code, "=console"); }

  _runReported(code, name) {
    try { this.vm.run(code, name); } catch (e) { if (!(e instanceof LuaError)) throw e; this.host.onError(e.message); }
  }

  _run(code, name) {
    try { return this.vm.run(code, name); } catch (e) { if (!(e instanceof LuaError)) throw e; this.host.onError(e.message); }
  }

  _call(path, ...args) {
    if (!this.vm) return undefined;
    try { return this.vm.call(path, ...args); } catch (e) { if (!(e instanceof LuaError)) throw e; this.host.onError(e.message); }
  }
}
