// Headless run (no browser): loads an addon + scenario in Node and prints Lua errors,
// chat output and the stub calls. Text widths are rough estimates here (no canvas).
//
//   node tools/headless.mjs <addonFolder> <AddonName> [scenarios/<Addon>/<file>.lua] [--frames]
import fs from "fs";
import path from "path";
import { createRequire } from "module";
import { fileURLToPath, pathToFileURL } from "url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [addonDir, addonName, scenario] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const showFrames = process.argv.includes("--frames");
const evalArg = process.argv.find((a) => a.startsWith("--eval="));
if (!addonDir || !addonName) {
  console.error("usage: node tools/headless.mjs <addonFolder> <AddonName> [scenario.lua] [--frames]");
  process.exit(1);
}

const require = createRequire(import.meta.url);
const createLua51 = require(path.join(root, "dist/lua51.js"));
const { Emulator } = await import(pathToFileURL(path.join(root, "src/emulator.js")));

const errors = [], stubs = new Map(), chat = [], secure = [];
const t0 = performance.now();
let draws = 0;
const host = {
  async fetchText(p) {
    if (p.startsWith("emu/")) return fs.readFileSync(path.join(root, p.slice(4)), "utf8");
    if (p.startsWith("addon/")) {
      const rel = p.split("/").slice(2).join("/");
      return fs.readFileSync(path.join(addonDir, rel), "utf8");
    }
    return fs.readFileSync(path.join(root, p), "utf8");
  },
  now: () => (performance.now() - t0) / 1000,
  // Rough metrics: average glyph width 0.5em, line height = size.
  layoutText(file, size, flags, text, wrap) {
    const plain = String(text).replace(/\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t|\|A[^|]*\|a/g, "");
    const lines = plain.split(/\|n|\n/);
    let w = 0, n = 0;
    for (const l of lines) {
      const lw = l.length * size * 0.5;
      const k = wrap > 0 ? Math.max(1, Math.ceil(lw / wrap)) : 1;
      n += k;
      w = Math.max(w, wrap > 0 ? Math.min(lw, wrap) : lw);
    }
    return [w, n * size, n];
  },
  physicalScreenSize: () => [1920, 1080],
  onError: (m) => errors.push(m),
  onChat: (m) => chat.push(m),
  onStub: (l) => stubs.set(l, (stubs.get(l) || 0) + 1),
  onSecure: (m) => secure.push(m),
  onReload: () => {},
  draw: Object.fromEntries(["beginFrame", "endFrame", "setClip", "drawColor", "drawGradient", "drawImage", "drawText"]
    .map((n) => [n, () => { draws++; }])),
};

const M = await createLua51();
const emu = new Emulator(M, host);
await emu.boot({
  addonName,
  scenarioPath: scenario,
  screen: { absW: 768 * 16 / 9, absH: 768, uiScale: 768 / 1080, pixelsPerUnit: 1080 / 768 },
});
// Let timers (e.g. C_Timer.After at login) run for 3 simulated... real seconds.
const until = performance.now() + 3000;
while (performance.now() < until) {
  emu.tick();
  await new Promise((r) => setTimeout(r, 50));
}
emu.render();

console.log(`== errors (${errors.length})`);
for (const e of errors) console.log(e + "\n");
console.log(`== chat (${chat.length})`);
for (const c of chat) console.log("  " + c);
console.log(`== stub calls (${stubs.size})`);
for (const [k, n] of [...stubs].sort()) console.log(`  ${k} x${n}`);
console.log(`== draw calls in last render: ${draws}`);
if (evalArg) console.log("== eval\n" + JSON.stringify(emu.runLua(evalArg.slice(7))));
if (showFrames) {
  const out = emu.runLua(`
    local S, lines = __Emu.S, {}
    for _, f in ipairs(__Emu.FrameOrder()) do
      if __Emu.IsVisible(f) and not S[f].isScreen then
        local l, b, w, h = f:GetRect()
        lines[#lines + 1] = ("%-60s %-8s lvl %3d  %s"):format(__Emu.DebugName(f), __Emu.EffectiveStrata(f), S[f].level,
          l and ("%.0f,%.0f %.0fx%.0f"):format(l, b, w, h) or "no rect")
      end
    end
    return table.concat(lines, "\\n")`);
  console.log("== visible frames\n" + (out ? out[0] : ""));
}
