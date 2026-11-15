// The page: wires the emulator to the canvas, mouse, side panels and hot reload.
// Rendering is on demand: Lua marks changes dirty; animation frames are only requested
// while an animation or OnUpdate script is running, timers use setTimeout.
import { Emulator } from "./emulator.js";
import { Renderer, layoutText } from "./render.js";

const $ = (id) => document.getElementById(id);
const canvas = $("screen"), overlay = $("overlay"), stage = $("stage");

const store = {
  get(k, d) { try { return localStorage.getItem("emu." + k) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem("emu." + k, v); } catch { /* storage unavailable */ } },
};

// ---- side panels ----
const errors = new Map(), stubs = new Map(), lists = { chat: [], secure: [] };
let panelsDirty = false;
function schedulePanels() {
  if (panelsDirty) return;
  panelsDirty = true;
  requestAnimationFrame(renderPanels);
}
function entry(cls, head, body, times) {
  const d = document.createElement("div");
  d.className = "entry " + cls;
  const h = document.createElement("div");
  h.className = "head";
  h.textContent = head;
  if (times > 1) {
    const t = document.createElement("span");
    t.className = "times";
    t.textContent = "x" + times;
    h.append(t);
  }
  d.append(h);
  if (body) {
    const p = document.createElement("pre");
    p.textContent = body;
    d.append(p);
  }
  return d;
}
function fill(id, items, emptyText) {
  const el = $(id);
  el.replaceChildren(...(items.length ? items : [Object.assign(document.createElement("div"), { className: "empty", textContent: emptyText })]));
}
function renderPanels() {
  panelsDirty = false;
  fill("errors", [...errors.entries()].map(([msg, n]) => {
    const [first, ...rest] = msg.split("\n");
    return entry("err", first, rest.join("\n"), n);
  }), "No errors.");
  fill("stubs", [...stubs.entries()].sort().map(([k, n]) => entry("", k, null, n)), "No calls to unemulated APIs.");
  fill("secure", lists.secure.map((m) => entry("", m)), "No secure clicks.");
  fill("chat", lists.chat.map((m) => entry("", m)), "No chat output.");
  const count = (id, n, bad) => { $(id).textContent = n; $(id).classList.toggle("bad", bad && n > 0); };
  count("errors-count", [...errors.values()].reduce((a, b) => a + b, 0), true);
  count("stubs-count", stubs.size);
  count("secure-count", lists.secure.length);
  count("chat-count", lists.chat.length);
}
function clearPanels() {
  errors.clear(); stubs.clear(); lists.chat = []; lists.secure = [];
  schedulePanels();
}
const stripCodes = (s) => String(s).replace(/\|c[0-9a-fA-F]{8}|\|r/g, "");

// ---- assets-local/map.json: optional real images for textures/icons/atlases ----
const assets = {
  images: new Map(),
  lookup(src) {
    const key = String(src).toLowerCase().replace(/\\/g, "/").replace(/\.(blp|tga|png)$/, "");
    return this.images.get(key) || null;
  },
  async load() {
    let map;
    try {
      const r = await fetch("assets-local/map.json", { cache: "no-store" });
      if (!r.ok) return 0;
      map = await r.json();
    } catch { return 0; }
    await Promise.all(Object.entries(map).map(([key, file]) => new Promise((resolve) => {
      const img = new Image();
      img.onload = () => { this.images.set(key.toLowerCase().replace(/\\/g, "/").replace(/\.(blp|tga|png)$/, ""), img); resolve(); };
      img.onerror = resolve;
      img.src = "assets-local/" + file;
    })));
    return this.images.size;
  },
};

// ---- emulator host ----
const renderer = new Renderer(canvas, assets);
const t0 = performance.now();
const host = {
  async fetchText(p) {
    const url = p.startsWith("emu/") ? p.slice(4) : p;
    const r = await fetch(url, { cache: "no-store" });
    if (!r.ok) throw new Error(`${r.status} ${url}`);
    return r.text();
  },
  now: () => (performance.now() - t0) / 1000,
  layoutText,
  physicalScreenSize: () => [Math.round(stage.clientWidth * devicePixelRatio), Math.round(stage.clientHeight * devicePixelRatio)],
  onError: (m) => { errors.set(m, (errors.get(m) || 0) + 1); schedulePanels(); },
  onChat: (m) => { lists.chat.push(stripCodes(m)); schedulePanels(); },
  onStub: (l) => { stubs.set(l, (stubs.get(l) || 0) + 1); schedulePanels(); },
  onSecure: (m) => { lists.secure.push(m); schedulePanels(); },
  onReload: () => setTimeout(boot, 0),
  draw: renderer.handlers,
};

let emu;
let rafPending = false, timer = null;

// Runs due timers/animations/OnUpdate, renders if anything changed, schedules the next wake-up.
let rafId = 0;
function pump() {
  rafPending = false;
  cancelAnimationFrame(rafId);
  clearTimeout(timer);
  timer = null;
  if (!emu?.vm) return;
  const [busy, nextDue] = emu.tick() || [];
  if (emu.isDirty()) emu.render();
  if (busy) {
    rafPending = true;
    rafId = requestAnimationFrame(pump);
    // Background tabs pause animation frames; this keeps timers running there.
    timer = setTimeout(pump, Math.max(100, (nextDue ?? 0) * 1000));
  } else if (nextDue != null) {
    timer = setTimeout(pump, Math.max(0, nextDue * 1000));
  }
}
function wake() {
  if (rafPending) return;
  rafPending = true;
  rafId = requestAnimationFrame(pump);
  clearTimeout(timer);
  timer = setTimeout(pump, 100); // fallback for background tabs (no animation frames)
}

// Virtual monitor + view (zoom/pan like an image editor; never sent to the game).
// scale = CSS pixels per virtual-screen pixel, (cx, cy) = virtual pixel at the view's center.
// fit = scale and center follow the window size until the user zooms or pans.
const ZOOM_MIN = 0.05, ZOOM_MAX = 32;
const ZOOM_STEPS = [0.05, 0.1, 0.125, 0.25, 1 / 3, 0.5, 2 / 3, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32];
const view = { fit: false, scale: 1, cx: null, cy: null };
function resSize() { return $("res").value.split("x").map(Number); }
function screenParams() {
  const dpr = devicePixelRatio || 1;
  const cssW = stage.clientWidth, cssH = stage.clientHeight;
  for (const c of [canvas, overlay]) { c.width = Math.round(cssW * dpr); c.height = Math.round(cssH * dpr); }
  const [resW, resH] = resSize();
  const uiScale = $("uiscale").value === "pp" ? 768 / resH : Number($("uiscale").value);
  if (view.fit || view.cx === null) { view.cx = resW / 2; view.cy = resH / 2; }
  if (view.fit) view.scale = Math.min(cssW / resW, cssH / resH) || 1;
  renderer.setView({ resW, resH, cssW, cssH, dpr, scale: view.scale, cx: view.cx, cy: view.cy });
  $("zoom-level").textContent = (view.scale * 100 >= 10 ? Math.round(view.scale * 100) : (view.scale * 100).toFixed(1)) + "%";
  $("zoom-fit").setAttribute("aria-pressed", String(view.fit));
  return { absW: (768 * resW) / resH, absH: 768, uiScale, pixelsPerUnit: resH / 768 };
}
function saveView() { store.set("zoom", view.fit ? "fit" : String(view.scale)); }
// Zooms keeping the virtual pixel under (px, py) (CSS px in the stage) in place.
// Without a point, zooms around the view's center.
function zoomTo(scale, px, py) {
  scale = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, scale));
  const cssW = stage.clientWidth, cssH = stage.clientHeight;
  const dx = (px ?? cssW / 2) - cssW / 2, dy = (py ?? cssH / 2) - cssH / 2;
  const vx = view.cx + dx / view.scale, vy = view.cy + dy / view.scale;
  Object.assign(view, { fit: false, scale, cx: vx - dx / scale, cy: vy - dy / scale });
  saveView();
  applyScreen();
}
function zoomStep(dir, px, py) {
  const s = view.scale;
  const next = dir > 0 ? ZOOM_STEPS.find((z) => z > s * 1.001) : ZOOM_STEPS.findLast((z) => z < s / 1.001);
  zoomTo(next ?? s, px, py);
}
function zoomFit() { view.fit = true; saveView(); applyScreen(); }
function applyScreen() {
  if (!emu?.vm) return;
  emu.setScreen(screenParams());
  wake();
}

// ---- boot / reload ----
let config = { addons: [] };
let booting = false;
let lastChange = "";
async function boot() {
  if (booting) return;
  booting = true;
  const started = performance.now();
  clearPanels();
  const addonName = $("addon").value;
  const scenarioPath = $("scenario").value || null;
  try {
    if (!addonName) throw new Error("No addon configured: start the server with --addon <folder> (see README).");
    await emu.boot({ addonName, scenarioPath, screen: screenParams() });
    $("status").textContent = `${addonName} loaded in ${Math.round(performance.now() - started)} ms` +
      ` · ${new Date().toLocaleTimeString()} · font: ${fontStatus}` + (assetCount ? ` · ${assetCount} local images` : "") +
      (lastChange ? ` · reloaded after change: ${lastChange}` : "");
    lastChange = "";
  } catch (e) {
    host.onError("[emulator] " + (e.stack || e.message));
    $("status").textContent = "Load failed, see Lua errors.";
  }
  booting = false;
  wake();
}

// ---- input ----
function toAbs(ev) {
  const r = canvas.getBoundingClientRect();
  const dpr = devicePixelRatio || 1;
  return renderer.toAbs((ev.clientX - r.left) * dpr, (ev.clientY - r.top) * dpr);
}
const BUTTONS = ["LeftButton", "MiddleButton", "RightButton", "Button4", "Button5"];
// Space+drag, Shift+drag or middle-drag pans the view (not sent to the game).
let panning = null, spaceHeld = false;
function setCursor() { canvas.style.cursor = panning ? "grabbing" : spaceHeld ? "grab" : ""; }
canvas.addEventListener("mousemove", (ev) => {
  if (panning) {
    Object.assign(view, {
      fit: false,
      cx: panning.cx - (ev.clientX - panning.mx) / view.scale,
      cy: panning.cy - (ev.clientY - panning.my) / view.scale,
    });
    applyScreen();
    return;
  }
  const [x, y] = toAbs(ev);
  emu.mouseMove(x, y);
  if ($("inspect").checked) inspect(x, y);
  wake();
});
canvas.addEventListener("mousedown", (ev) => {
  if (ev.button === 1 || (ev.button === 0 && (ev.shiftKey || spaceHeld))) {
    ev.preventDefault();
    panning = { mx: ev.clientX, my: ev.clientY, cx: view.cx, cy: view.cy };
    setCursor();
    return;
  }
  emu.mouseMove(...toAbs(ev));
  emu.mouseDown(BUTTONS[ev.button] || "LeftButton");
  wake();
});
window.addEventListener("mouseup", (ev) => {
  if (panning) { panning = null; saveView(); setCursor(); return; }
  if (emu?.vm) { emu.mouseUp(BUTTONS[ev.button] || "LeftButton"); wake(); }
});
canvas.addEventListener("mouseleave", () => { emu.mouseMove(-1000, -1000); wake(); });
// Ctrl+wheel (also a trackpad pinch) or Alt+wheel zooms at the cursor; a plain wheel
// goes to the game (OnMouseWheel).
canvas.addEventListener("wheel", (ev) => {
  ev.preventDefault();
  if (ev.ctrlKey || ev.altKey) {
    const r = canvas.getBoundingClientRect();
    const dy = ev.deltaMode === 1 ? ev.deltaY * 33 : ev.deltaMode === 2 ? ev.deltaY * 400 : ev.deltaY;
    zoomTo(view.scale * Math.exp(-Math.max(-300, Math.min(300, dy)) * 0.0025), ev.clientX - r.left, ev.clientY - r.top);
    return;
  }
  emu.mouseWheel(ev.deltaY < 0 ? 1 : -1);
  wake();
}, { passive: false });
// Keyboard: Ctrl+plus/minus zoom steps, Ctrl+0 fit, Ctrl+1 100 %, Space held = hand tool.
// Not while typing in a text field.
const typing = (ev) => ev.target instanceof HTMLInputElement && ev.target.type !== "checkbox";
window.addEventListener("keydown", (ev) => {
  if (typing(ev)) return;
  if (ev.code === "Space") { ev.preventDefault(); if (!spaceHeld) { spaceHeld = true; setCursor(); } return; }
  if (!(ev.ctrlKey || ev.metaKey) || ev.altKey) return;
  // By character, not key position: "+" sits on different keys per layout (e.g. German).
  const action = { "+": () => zoomStep(1), "=": () => zoomStep(1), "-": () => zoomStep(-1),
    "0": zoomFit, "1": () => zoomTo(1) }[ev.key];
  if (action) { ev.preventDefault(); action(); }
});
window.addEventListener("keyup", (ev) => { if (ev.code === "Space") { spaceHeld = false; setCursor(); } });
window.addEventListener("blur", () => { spaceHeld = false; setCursor(); });
canvas.addEventListener("contextmenu", (ev) => ev.preventDefault());

// ---- inspector ----
function inspect(x, y) {
  const octx = overlay.getContext("2d");
  octx.clearRect(0, 0, overlay.width, overlay.height);
  const r = emu.inspectAt(x, y);
  const info = $("inspect-info");
  if (!r || !r[0]) { info.textContent = "Nothing under the cursor."; return; }
  const [text, l, b, w, h] = r;
  info.replaceChildren(Object.assign(document.createElement("div"), { className: "mono", textContent: text }));
  const [x0, y0, pw, ph] = renderer.rect(l, b, w, h);
  octx.strokeStyle = "#e8c15a";
  octx.lineWidth = Math.max(1, devicePixelRatio);
  octx.setLineDash([4 * devicePixelRatio, 3 * devicePixelRatio]);
  octx.strokeRect(x0 + 0.5, y0 + 0.5, pw - 1, ph - 1);
}
$("inspect").addEventListener("change", () => {
  $("inspect-info").hidden = !$("inspect").checked;
  if (!$("inspect").checked) overlay.getContext("2d").clearRect(0, 0, overlay.width, overlay.height);
  store.set("inspect", $("inspect").checked ? "1" : "");
});

// ---- Lua console ----
$("lua").addEventListener("keydown", (ev) => {
  if (ev.key !== "Enter") return;
  const code = ev.target.value.trim();
  if (!code) return;
  ev.target.value = "";
  host.onChat("> " + code);
  let lua = code;
  if (code.startsWith("/")) lua = `__Emu.RunSlashCommand(${JSON.stringify(code)})`;
  else if (code.startsWith("=")) lua = "return " + code.slice(1);
  const out = emu.runLua(lua);
  if (out && out.length) host.onChat(out.map(String).join(", "));
  wake();
});

// ---- controls ----
$("reload").addEventListener("click", boot);
for (const id of ["res", "uiscale"]) {
  $(id).addEventListener("change", () => {
    store.set(id, $(id).value);
    if (id === "res") view.cx = view.cy = null; // recenter on the new screen
    applyScreen();
  });
}
$("zoom-in").addEventListener("click", () => zoomStep(1));
$("zoom-out").addEventListener("click", () => zoomStep(-1));
$("zoom-level").addEventListener("click", () => zoomTo(1));
$("zoom-fit").addEventListener("click", zoomFit);
$("scenario").addEventListener("change", () => { store.set("scenario", $("scenario").value); boot(); });
$("addon").addEventListener("change", () => { store.set("addon", $("addon").value); fillScenarios(); boot(); });
let resizeTimer;
new ResizeObserver(() => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(applyScreen, 100);
}).observe(stage);

function fillScenarios() {
  const a = config.addons.find((x) => x.name === $("addon").value);
  const sel = $("scenario");
  sel.replaceChildren(new Option("(none)", ""), ...(a?.scenarios || []).map((s) => new Option(s.split("/").pop(), s)));
  const saved = store.get("scenario", null); // "" = the user picked (none)
  sel.value = saved !== null && [...sel.options].some((o) => o.value === saved) ? saved : (a?.scenarios?.[0] || "");
}

// ---- hot reload ----
function listenForChanges() {
  const es = new EventSource("events");
  es.addEventListener("reload", (ev) => {
    const files = JSON.parse(ev.data);
    if (files.some((f) => /^src\/.*\.js$/.test(f))) return location.reload(); // emulator JS changed
    lastChange = files.join(", ");
    boot();
  });
}

// ---- start ----
let fontStatus = "", assetCount = 0;
(async () => {
  $("res").value = store.get("res", "1920x1080");
  $("uiscale").value = store.get("uiscale", "pp");
  const savedZoom = store.get("zoom", "1");
  if (savedZoom === "fit") view.fit = true;
  else view.scale = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Number(savedZoom) || 1));
  $("inspect").checked = store.get("inspect", "") === "1";
  $("inspect-info").hidden = !$("inspect").checked;
  config = await (await fetch("api/config", { cache: "no-store" })).json();
  $("addon").replaceChildren(...config.addons.map((a) => new Option(a.name, a.name)));
  const savedAddon = store.get("addon", "");
  if (config.addons.some((a) => a.name === savedAddon)) $("addon").value = savedAddon;
  fillScenarios();
  // Fonts must be ready before Lua measures any text (measurements are cached).
  const realFriz = (await fetch("assets-local/fonts/FRIZQT__.TTF", { method: "HEAD", cache: "no-store" }).catch(() => null))?.ok;
  await Promise.all(["EmuFriz", "EmuArialN"].map((f) => document.fonts.load(`12px ${f}`).catch(() => null)));
  fontStatus = realFriz ? "FRIZQT__.TTF (assets-local)" : "Marcellus (look-alike)";
  assetCount = await assets.load();
  const M = await createLua51(); // global from dist/lua51.js
  emu = new Emulator(M, host);
  window.emu = emu; // for poking around in devtools
  // Pan the view by virtual pixels from the screen center (scriptable Shift+drag).
  window.emuPan = (x, y) => {
    const [resW, resH] = resSize();
    Object.assign(view, { fit: false, cx: resW / 2 + x, cy: resH / 2 + y });
    applyScreen();
  };
  await boot();
  listenForChanges();
})();
