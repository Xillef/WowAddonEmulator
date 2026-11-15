// Local dev server for the emulator page:
//   - serves the emulator (index.html, src/, dist/, scenarios/, assets/, assets-local/)
//   - serves each configured addon folder read-only under /addon/<Name>/...
//   - watches the addon folders + scenarios/ + src/ and pushes "reload" over SSE
//
//   node server.js [--addon <path to addon folder>]... [--port 8642]
// Addon folders can also be listed in emulator.config.local.json (gitignored):
//   { "addons": ["K:/path/to/MyAddon"], "port": 8642 }
// The folder name is the addon name (like Interface/AddOns/<Name>), with <Name>.toc inside.
// Only listens on 127.0.0.1. Never writes to the addon folders.
import http from "http";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.dirname(fileURLToPath(import.meta.url));

// ---- config ----
const args = process.argv.slice(2);
let config = { addons: [], port: 8642 };
const localConfig = path.join(root, "emulator.config.local.json");
if (fs.existsSync(localConfig)) config = { ...config, ...JSON.parse(fs.readFileSync(localConfig, "utf8")) };
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--addon") config.addons = [...config.addons, args[++i]];
  else if (args[i] === "--port") config.port = Number(args[++i]);
}
const addons = new Map(); // name -> absolute folder
for (const dir of config.addons) {
  let abs = path.resolve(dir);
  // Long, real path: Windows short names (ROBERT~1) break recursive fs.watch.
  try { abs = fs.realpathSync.native(abs); } catch { /* missing: reported below */ }
  const name = path.basename(abs);
  if (!fs.existsSync(path.join(abs, name + ".toc"))) {
    console.error(`skipping ${abs}: no ${name}.toc inside`);
    continue;
  }
  addons.set(name, abs);
}
if (addons.size === 0) {
  console.error("No addon configured. Use --addon <folder> or emulator.config.local.json (see README).");
}

// ---- static files ----
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8", ".wasm": "application/wasm",
  ".lua": "text/plain; charset=utf-8", ".toc": "text/plain; charset=utf-8", ".xml": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8", ".ttf": "font/ttf", ".otf": "font/otf", ".woff2": "font/woff2",
  ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml", ".tga": "application/octet-stream",
};
const PUBLIC = ["index.html", "src", "dist", "scenarios", "assets", "assets-local"];

// Resolves `rel` inside `base`; null if it escapes base (path traversal) or doesn't exist.
function safeJoin(base, rel) {
  const p = path.resolve(base, "." + path.sep + rel);
  if (p !== base && !p.startsWith(base + path.sep)) return null;
  return p;
}

// WoW file names are case-insensitive; addon .toc entries don't always match the disk.
function findCaseInsensitive(base, rel) {
  let cur = base;
  for (const part of rel.split("/").filter(Boolean)) {
    if (!fs.existsSync(cur) || !fs.statSync(cur).isDirectory()) return null;
    const match = fs.readdirSync(cur).find((e) => e.toLowerCase() === part.toLowerCase());
    if (!match) return null;
    cur = path.join(cur, match);
  }
  return cur;
}

function sendFile(res, file) {
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return notFound(res);
    res.writeHead(200, {
      "Content-Type": TYPES[path.extname(file).toLowerCase()] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    fs.createReadStream(file).pipe(res);
  });
}
function notFound(res) { res.writeHead(404, { "Content-Type": "text/plain" }); res.end("not found"); }

function listScenarios(addonName) {
  const dir = path.join(root, "scenarios", addonName);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith(".lua")).map((f) => `scenarios/${addonName}/${f}`);
}

// ---- SSE reload ----
const clients = new Set();
let pending = null, changed = new Set();
function notify(what) {
  changed.add(what);
  clearTimeout(pending);
  pending = setTimeout(() => {
    const msg = `event: reload\ndata: ${JSON.stringify([...changed])}\n\n`;
    changed = new Set();
    for (const c of clients) c.write(msg);
  }, 150);
}
function watch(dir, label) {
  try {
    fs.watch(dir, { recursive: true }, (_, file) => file && notify(`${label}/${String(file).replace(/\\/g, "/")}`));
  } catch (e) {
    console.error(`can't watch ${dir}: ${e.message}`);
  }
}
for (const [name, dir] of addons) watch(dir, name);
watch(path.join(root, "scenarios"), "scenarios");
watch(path.join(root, "src"), "src");

// ---- server ----
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  const p = decodeURIComponent(url.pathname);
  if (p === "/events") {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
    res.write(": connected\n\n");
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }
  if (p === "/api/config") {
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify({ addons: [...addons.keys()].map((name) => ({ name, scenarios: listScenarios(name) })) }));
    return;
  }
  if (p.startsWith("/addon/")) {
    const [, , name, ...rest] = p.split("/");
    const base = addons.get(name);
    if (!base) return notFound(res);
    const rel = rest.join("/");
    if (!safeJoin(base, rel)) return notFound(res);
    const file = findCaseInsensitive(base, rel);
    return file ? sendFile(res, file) : notFound(res);
  }
  const rel = p === "/" ? "index.html" : p.slice(1);
  if (!PUBLIC.some((d) => rel === d || rel.startsWith(d + "/"))) return notFound(res);
  const file = safeJoin(root, rel);
  return file ? sendFile(res, file) : notFound(res);
});

server.listen(config.port, "127.0.0.1", () => {
  console.log(`WoW Addon Emulator: http://localhost:${config.port}/`);
  for (const [name, dir] of addons) console.log(`  addon ${name}: ${dir} (read-only, watched)`);
});
