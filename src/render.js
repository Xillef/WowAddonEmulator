// Canvas2D renderer for the draw commands sent by Lua (runtime.lua, Emu.Render) and the
// text metrics Lua asks for (layoutText). Coordinates arrive in WoW absolute units
// (screen height 768, y up); they're converted to canvas pixels here.
//
// Exact: solid colors (SetColorTexture, WHITE8x8 files), gradients, vertex colors, alpha.
// Placeholders: every other Blizzard texture/icon/atlas, unless mapped in
// assets-local/map.json (see README).

const FONT_FAMILIES = [
  // [match in the font path, CSS family, fallback stack]
  [/frizqt/i, "EmuFriz", "serif"],
  [/arialn/i, "EmuArialN", "'Arial Narrow', Arial, sans-serif"],
  [/morpheus/i, "EmuMorpheus", "serif"],
  [/skurri/i, "EmuSkurri", "serif"],
];

export function fontFamilyFor(file) {
  for (const [re, family, fallback] of FONT_FAMILIES) if (re.test(file)) return `${family}, ${fallback}`;
  return "EmuFriz, serif";
}

// ---- WoW text escapes: |cAARRGGBB..|r, |n, |T..|t, |A..|a, |H..|h..|h, || ----
function parseRuns(text) {
  const runs = []; // { text, color: [r,g,b] | null } or { icon: true } or { br: true }
  const colors = [];
  let buf = "";
  const flush = () => { if (buf) { runs.push({ text: buf, color: colors[colors.length - 1] || null }); buf = ""; } };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "\n") { flush(); runs.push({ br: true }); continue; }
    if (ch !== "|") { buf += ch; continue; }
    const n = text[i + 1];
    if (n === "|") { buf += "|"; i++; continue; }
    if (n === "c" && /^[0-9a-fA-F]{8}$/.test(text.substr(i + 2, 8))) {
      flush();
      const hex = text.substr(i + 4, 6);
      colors.push([parseInt(hex.substr(0, 2), 16) / 255, parseInt(hex.substr(2, 2), 16) / 255, parseInt(hex.substr(4, 2), 16) / 255]);
      i += 9; continue;
    }
    if (n === "r") { flush(); colors.pop(); i++; continue; }
    if (n === "n") { flush(); runs.push({ br: true }); i++; continue; }
    if (n === "T" || n === "A") {
      const end = text.indexOf(n === "T" ? "|t" : "|a", i + 2);
      if (end >= 0) { flush(); runs.push({ icon: true }); i = end + 1; continue; }
    }
    if (n === "H") { const end = text.indexOf("|h", i + 2); if (end >= 0) { i = end + 1; continue; } }
    if (n === "h") { i++; continue; }
    buf += ch;
  }
  flush();
  return runs;
}

const measureCanvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(1, 1) : null;
const mctx = measureCanvas ? measureCanvas.getContext("2d") : null;

function cssFont(file, sizePx) { return `${sizePx}px ${fontFamilyFor(file)}`; }

// Lays text out into lines of segments. Units are whatever `size` is in.
function layout(ctx, file, size, text, wrapWidth, nonSpaceWrap, maxLines) {
  ctx.font = cssFont(file, size);
  const runs = parseRuns(String(text));
  const lines = [[]];
  // Split runs into words (keeping spaces attached) so wrapping can break between them.
  const tokens = [];
  for (const r of runs) {
    if (r.br) tokens.push({ br: true });
    else if (r.icon) tokens.push({ text: "", icon: true, color: null, w: size });
    else for (const part of r.text.split(/(?<= )/)) tokens.push({ text: part, color: r.color, w: ctx.measureText(part).width });
  }
  let lineW = 0;
  const widths = [0];
  const push = (t) => { lines[lines.length - 1].push(t); lineW += t.w; widths[widths.length - 1] = lineW; };
  const newLine = () => { lines.push([]); widths.push(0); lineW = 0; };
  for (const t of tokens) {
    if (t.br) { newLine(); continue; }
    const trimmedW = t.icon ? t.w : ctx.measureText(t.text.replace(/ +$/, "")).width;
    if (wrapWidth > 0 && lineW > 0 && lineW + trimmedW > wrapWidth + 0.01) newLine();
    if (wrapWidth > 0 && nonSpaceWrap && !t.icon && trimmedW > wrapWidth) {
      let chunk = "";
      for (const ch of t.text) {
        if (lineW + ctx.measureText(chunk + ch).width > wrapWidth && (chunk || lineW > 0)) {
          if (chunk) push({ text: chunk, color: t.color, w: ctx.measureText(chunk).width });
          newLine();
          chunk = "";
        }
        chunk += ch;
      }
      if (chunk) push({ text: chunk, color: t.color, w: ctx.measureText(chunk).width });
      continue;
    }
    push(t);
  }
  // Trailing spaces don't count towards a line's width.
  for (let i = 0; i < lines.length; i++) {
    const segs = lines[i];
    const last = segs[segs.length - 1];
    if (last && !last.icon && / +$/.test(last.text)) {
      widths[i] -= last.w - ctx.measureText(last.text.replace(/ +$/, "")).width;
    }
  }
  let n = lines.length;
  if (maxLines > 0 && n > maxLines) n = maxLines;
  return { lines: lines.slice(0, n), widths: widths.slice(0, n), truncated: n < lines.length };
}

// For Lua: [width, height, numLines] in the font string's own units.
export function layoutText(file, size, flags, text, wrapWidth, nonSpaceWrap, spacing, maxLines) {
  const l = layout(mctx, file, size, text, wrapWidth, nonSpaceWrap, maxLines);
  const n = l.lines.length;
  return [Math.max(0, ...l.widths), n * size + Math.max(0, n - 1) * spacing, n];
}

export class Renderer {
  constructor(canvas, assets) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.assets = assets; // { lookup(src) -> HTMLImageElement | null }
    this.k = 1;           // canvas px per absolute unit
    this.screenH = 768;
    this.ox = 0;          // canvas px offset of the virtual screen's top-left corner
    this.oy = 0;
    this.view = null;
    this.clip = null;
    this.handlers = {
      beginFrame: (w, h) => this.beginFrame(w, h),
      endFrame: () => this.endFrame(),
      setClip: (...a) => this.setClip(...a),
      drawColor: (...a) => this.drawColor(...a),
      drawGradient: (...a) => this.drawGradient(...a),
      drawImage: (...a) => this.drawImage(...a),
      drawText: (...a) => this.drawText(...a),
    };
  }

  // View onto the virtual monitor: resW x resH virtual pixels, shown at `scale` CSS px per
  // virtual px (0 = fit), centered on (cx, cy) virtual px.
  setView(view) {
    this.view = view;
    const { resW, resH, cssW, cssH, dpr } = view;
    // scale = CSS pixels per virtual-screen pixel; (cx, cy) = virtual pixel at the view's center.
    const s = view.scale > 0 ? view.scale : Math.min(cssW / resW, cssH / resH);
    this.k = (resH / 768) * s * dpr;
    const cx = view.cx ?? resW / 2, cy = view.cy ?? resH / 2;
    this.ox = (cssW / 2 - cx * s) * dpr;
    this.oy = (cssH / 2 - cy * s) * dpr;
  }

  // Absolute WoW units <-> canvas pixels.
  rect(l, b, w, h) {
    const k = this.k;
    return [this.ox + l * k, this.oy + (this.screenH - b - h) * k, w * k, h * k];
  }
  toAbs(canvasX, canvasY) {
    return [(canvasX - this.ox) / this.k, this.screenH - (canvasY - this.oy) / this.k];
  }

  beginFrame(absW, absH) {
    const c = this.ctx;
    this.screenH = absH;
    this.absW = absW;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.globalCompositeOperation = "source-over";
    c.globalAlpha = 1;
    c.fillStyle = "#0b0c0e"; // outside the virtual monitor
    c.fillRect(0, 0, this.canvas.width, this.canvas.height);
    c.fillStyle = "#1b1d22"; // "game world" behind the UI
    c.fillRect(...this.rect(0, 0, absW, absH));
    this.clip = null;
  }

  endFrame() {
    if (this.clip) this.ctx.restore();
    this.clip = null;
  }

  setClip(l, b, w, h) {
    const c = this.ctx;
    if (this.clip) { c.restore(); this.clip = null; }
    if (l === undefined) return;
    c.save();
    c.beginPath();
    c.rect(...this.rect(l, b, w, h));
    c.clip();
    this.clip = true;
  }

  blend(mode) {
    this.ctx.globalCompositeOperation = mode === "ADD" ? "lighter" : mode === "MOD" ? "multiply" : "source-over";
  }

  drawColor(l, b, w, h, r, g, bl, a, blend) {
    const c = this.ctx;
    this.blend(blend);
    c.globalAlpha = 1;
    c.fillStyle = rgba(r, g, bl, a);
    c.fillRect(...this.rect(l, b, w, h));
    this.blend("BLEND");
  }

  drawGradient(l, b, w, h, orientation, r1, g1, b1, a1, r2, g2, b2, a2, blend) {
    const c = this.ctx;
    const [x, y, pw, ph] = this.rect(l, b, w, h);
    // HORIZONTAL: min color left -> max right. VERTICAL: min bottom -> max top.
    const grad = orientation === "VERTICAL" ? c.createLinearGradient(x, y + ph, x, y) : c.createLinearGradient(x, y, x + pw, y);
    grad.addColorStop(0, rgba(r1, g1, b1, a1));
    grad.addColorStop(1, rgba(r2, g2, b2, a2));
    this.blend(blend);
    c.fillStyle = grad;
    c.fillRect(x, y, pw, ph);
    this.blend("BLEND");
  }

  drawImage(l, b, w, h, src, vr, vg, vb, a, desat, tl, tr, tt, tb, blend, rotation) {
    if (/white8x8$/i.test(src.replace(/\.(tga|blp)$/i, ""))) return this.drawColor(l, b, w, h, vr, vg, vb, a, blend);
    const c = this.ctx;
    const [x, y, pw, ph] = this.rect(l, b, w, h);
    const img = this.assets.lookup(src);
    this.blend(blend);
    c.globalAlpha = a;
    if (img) {
      c.filter = desat > 0 ? `grayscale(${desat})` : "none";
      const iw = img.naturalWidth, ih = img.naturalHeight;
      const sx = Math.min(tl, tr) * iw, sy = Math.min(tt, tb) * ih;
      const sw = Math.abs(tr - tl) * iw || 1, sh = Math.abs(tb - tt) * ih || 1;
      c.drawImage(img, sx, sy, sw, sh, x, y, pw, ph);
      c.filter = "none";
      if (vr < 1 || vg < 1 || vb < 1) {
        // Vertex color multiplies the texture: approximate with a multiply overlay.
        c.globalCompositeOperation = "multiply";
        c.fillStyle = rgba(vr, vg, vb, 1);
        c.fillRect(x, y, pw, ph);
      }
    } else {
      drawPlaceholder(c, src, x, y, pw, ph, vr, vg, vb, desat, this.k);
    }
    c.globalAlpha = 1;
    this.blend("BLEND");
  }

  drawText(l, b, w, h, text, file, size, flags, r, g, bl, a, justifyH, justifyV,
    sr, sg, sb, sa, sox, soy, wrapWidth, nonSpaceWrap, spacing, maxLines) {
    const c = this.ctx;
    const k = this.k;
    const px = size * k;
    if (px < 1) return;
    const lay = layout(c, file, px, text, wrapWidth * k, nonSpaceWrap, maxLines);
    const [x, y, pw, ph] = this.rect(l, b, w, h);
    const lineH = px + spacing * k;
    let lines = lay.lines, widths = lay.widths;
    // Text taller than a fixed-height string: cut off with "..." (like the client).
    const fit = Math.max(1, Math.floor((ph + spacing * k + 0.5) / lineH));
    let ellipsis = lay.truncated;
    if (lines.length > fit) { lines = lines.slice(0, fit); widths = widths.slice(0, fit); ellipsis = true; }
    const total = lines.length * px + (lines.length - 1) * spacing * k;
    let ty = justifyV === "TOP" ? y : justifyV === "BOTTOM" ? y + ph - total : y + (ph - total) / 2;
    c.font = cssFont(file, px);
    c.textBaseline = "middle";
    const outline = /THICKOUTLINE/i.test(flags) ? 2 : /OUTLINE/i.test(flags) ? 1 : 0;
    lines.forEach((segs, i) => {
      if (ellipsis && i === lines.length - 1) segs = [...segs, { text: "...", color: null, w: c.measureText("...").width }];
      const lw = widths[i] + (ellipsis && i === lines.length - 1 ? c.measureText("...").width : 0);
      let tx = justifyH === "LEFT" ? x : justifyH === "RIGHT" ? x + pw - lw : x + (pw - lw) / 2;
      const cy = ty + px / 2;
      for (const s of segs) {
        if (s.icon) { // |T..|t / |A..|a: placeholder square
          c.globalAlpha = a;
          c.fillStyle = "rgba(128,128,128,0.6)";
          c.fillRect(tx + 1, ty + 1, px - 2, px - 2);
          tx += s.w;
          continue;
        }
        const col = s.color || [r, g, bl];
        if (sa > 0 && (sox || soy)) {
          c.globalAlpha = 1;
          c.fillStyle = rgba(sr, sg, sb, sa);
          c.fillText(s.text, tx + sox * k, cy - soy * k);
        }
        if (outline) {
          c.globalAlpha = 1;
          c.lineWidth = outline * k * 1.5;
          c.lineJoin = "round";
          c.strokeStyle = rgba(0, 0, 0, a);
          c.strokeText(s.text, tx, cy);
        }
        c.globalAlpha = 1;
        c.fillStyle = rgba(col[0], col[1], col[2], a);
        c.fillText(s.text, tx, cy);
        tx += s.w;
      }
      ty += lineH;
    });
    c.globalAlpha = 1;
  }
}

function rgba(r, g, b, a) {
  const c = (v) => Math.round(Math.max(0, Math.min(1, v)) * 255);
  return `rgba(${c(r)},${c(g)},${c(b)},${Math.max(0, Math.min(1, a))})`;
}

// Recognizable stand-ins for the Blizzard textures the popup uses; everything else is a
// tinted, hatched box (icons get a "?").
function drawPlaceholder(c, src, x, y, w, h, r, g, b, desat, k) {
  const s = String(src).toLowerCase().replace(/\//g, "\\");
  const gray = (v) => (desat > 0 ? 0.6 : v);
  c.save();
  c.lineWidth = Math.max(1, k);
  if (s.includes("ui-checkbox-up") || s.includes("ui-checkbox-down")) {
    c.fillStyle = "rgba(20,20,20,0.9)";
    c.fillRect(x + w * 0.2, y + h * 0.2, w * 0.6, h * 0.6);
    c.strokeStyle = "rgba(160,160,160,1)";
    c.strokeRect(x + w * 0.2, y + h * 0.2, w * 0.6, h * 0.6);
  } else if (s.includes("ui-checkbox-check")) {
    c.strokeStyle = s.includes("disabled") ? "rgba(128,128,128,1)" : "rgba(255,210,0,1)";
    c.lineWidth = Math.max(1.5, w * 0.1);
    c.beginPath();
    c.moveTo(x + w * 0.28, y + h * 0.5);
    c.lineTo(x + w * 0.45, y + h * 0.68);
    c.lineTo(x + w * 0.75, y + h * 0.3);
    c.stroke();
  } else if (s.includes("ui-checkbox-highlight")) {
    c.fillStyle = "rgba(255,255,255,0.15)";
    c.fillRect(x + w * 0.2, y + h * 0.2, w * 0.6, h * 0.6);
  } else if (s.includes("ui-optionsbutton")) {
    // gear: ring + teeth
    const cx = x + w / 2, cy = y + h / 2, R = Math.min(w, h) * 0.42;
    c.fillStyle = rgba(gray(r) * 0.9, gray(g) * 0.75, gray(b) * 0.2, 1);
    c.beginPath();
    for (let i = 0; i < 16; i++) {
      const ang = (i / 16) * Math.PI * 2;
      const rr = i % 2 ? R : R * 0.78;
      c.lineTo(cx + Math.cos(ang) * rr, cy + Math.sin(ang) * rr);
    }
    c.closePath();
    c.fill();
    c.globalCompositeOperation = "destination-out";
    c.beginPath(); c.arc(cx, cy, R * 0.35, 0, Math.PI * 2); c.fill();
  } else {
    const isIcon = /^\d+$/.test(s) || s.includes("\\icons\\") || s.startsWith("atlas:");
    c.fillStyle = rgba(r * 0.35, g * 0.35, b * 0.35, 1);
    c.fillRect(x, y, w, h);
    c.strokeStyle = rgba(r * 0.7, g * 0.7, b * 0.7, 1);
    c.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    if (isIcon && w >= 10 && h >= 10) {
      c.fillStyle = rgba(r * 0.85, g * 0.85, b * 0.85, 1);
      c.font = `bold ${Math.round(h * 0.6)}px sans-serif`;
      c.textAlign = "center";
      c.textBaseline = "middle";
      c.fillText(s.startsWith("atlas:") ? "A" : "?", x + w / 2, y + h / 2 + 1);
    }
  }
  c.restore();
}
