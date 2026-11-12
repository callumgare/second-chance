// The mock engine's pixels: layer contents with their effects, shapes and masks, drawn on canvases in the
// browser. Rough stand-ins for the engine's Core Image versions, good enough to design against.
import type { Content, Effect, Mask, Media, Shape } from "../api";
import { hexToRgb, mix, shade } from "../lib/colour";
import { brightnessContrastTable, loadImage } from "../render/resources";

const cv = (w: number, h: number) => {
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(w)); c.height = Math.max(1, Math.round(h));
  return c;
};
const ctx2d = (c: HTMLCanvasElement) => c.getContext("2d", { willReadFrequently: true })!;

export function toBlobUrl(c: HTMLCanvasElement): Promise<string> {
  return new Promise((resolve, reject) => c.toBlob((b) => (b ? resolve(URL.createObjectURL(b)) : reject(new Error("toBlob"))), "image/png"));
}

// ---------------------------------------------------------------- content

/** `canvasWidth`: the layer's width in canvas units, to turn effect sizes (canvas units) into pixels. */
export async function renderContent(content: Content, pixelWidth: number, media: Map<string, Media>, canvasWidth = 1): Promise<HTMLCanvasElement> {
  const pw = Math.min(2048, Math.max(8, Math.round(pixelWidth)));
  if (content.kind === "shape") return renderShape(content.shape, pw);
  const m = media.get(content.asset);
  if (!m) throw new Error("no such media: " + content.asset);
  const img = await loadImage(content.cutout && m.cutout ? m.cutout : m.url);
  let sx = 0, sy = 0, sw = img.naturalWidth, sh = img.naturalHeight;
  if (content.crop) {
    const [x, y, w, h] = content.crop;
    sx = x * sw; sy = y * sh; sw = w * sw; sh = h * sh;
  }
  const ph = (pw * sh) / sw;
  let c = cv(pw, ph);
  const g = ctx2d(c);
  g.imageSmoothingEnabled = content.smoothing !== "pixel";
  g.imageSmoothingQuality = "high";
  g.drawImage(img, sx, sy, sw, sh, 0, 0, c.width, c.height);
  const unit = pw / Math.max(0.05, canvasWidth); // pixels per canvas unit
  const w0 = c.width, h0 = c.height;
  for (const e of content.effects) c = applyEffect(c, e, unit);
  // Effects that grow the image (an outline) grow it evenly: say where the content box sits in it.
  const px = (c.width - w0) / 2 / w0, py = (c.height - h0) / 2 / h0;
  (c as any).box = [-px, -py, 1 + px, 1 + py];
  return c;
}

function pixels(c: HTMLCanvasElement) { return ctx2d(c).getImageData(0, 0, c.width, c.height); }
const lum = (d: Uint8ClampedArray, i: number) => (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) / 255;

export function applyEffect(src: HTMLCanvasElement, e: Effect, unit: number): HTMLCanvasElement {
  const w = src.width, h = src.height;
  switch (e.op) {
    case "silhouette": {
      const c = cv(w, h), g = ctx2d(c);
      g.drawImage(src, 0, 0); g.globalCompositeOperation = "source-in"; g.fillStyle = e.color; g.fillRect(0, 0, w, h);
      return c;
    }
    case "feather": {
      // the mock's rough feather: the alpha blurred (the engine moves the edge too)
      const c = cv(w, h), g = ctx2d(c);
      g.filter = `blur(${Math.max(0, e.softness * unit / 2)}px)`; g.drawImage(src, 0, 0);
      return c;
    }
    case "outline": {
      const r = Math.max(1, e.width * unit);
      const pad = Math.ceil(r);
      const sil = applyEffect(src, { op: "silhouette", color: e.color }, unit);
      const c = cv(w + pad * 2, h + pad * 2), g = ctx2d(c);
      for (let a = 0; a < 32; a++) {
        const t = (a / 32) * Math.PI * 2;
        g.drawImage(sil, pad + Math.cos(t) * r, pad + Math.sin(t) * r);
      }
      g.drawImage(sil, pad, pad);
      g.drawImage(src, pad, pad);
      return c;
    }
    case "halftone": {
      const cell = Math.max(3, e.cell * unit);
      const d = pixels(src).data;
      const c = cv(w, h), g = ctx2d(c);
      g.fillStyle = e.ink;
      g.translate(w / 2, h / 2); g.rotate((e.angle * Math.PI) / 180);
      const R = Math.hypot(w, h) / 2;
      for (let y = -R; y < R; y += cell) for (let x = -R; x < R; x += cell) {
        const t = (e.angle * Math.PI) / 180;
        const X = Math.round(w / 2 + x * Math.cos(t) - y * Math.sin(t)), Y = Math.round(h / 2 + x * Math.sin(t) + y * Math.cos(t));
        if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
        const i = (Y * w + X) * 4;
        if (d[i + 3] < 60) continue;
        const dark = 1 - lum(d, i);
        const rad = (cell / 2) * Math.sqrt(dark) * 1.1;
        if (rad < 0.4) continue;
        g.beginPath(); g.arc(x, y, rad, 0, Math.PI * 2); g.fill();
      }
      return c;
    }
    case "tone": {
      const id = pixels(src), d = id.data;
      const [r, gg, b] = hexToRgb(e.color);
      for (let i = 0; i < d.length; i += 4) {
        const band = Math.min(2, Math.floor(lum(d, i) * 3));
        const on = d[i + 3] > 100 && band === e.level;
        d[i] = r; d[i + 1] = gg; d[i + 2] = b; d[i + 3] = on ? 255 : 0;
      }
      const c = cv(w, h); ctx2d(c).putImageData(id, 0, 0); return c;
    }
    case "gradient-map": {
      const id = pixels(src), d = id.data;
      const a = hexToRgb(e.dark), b = hexToRgb(e.light);
      for (let i = 0; i < d.length; i += 4) {
        const t = lum(d, i);
        d[i] = a[0] + (b[0] - a[0]) * t; d[i + 1] = a[1] + (b[1] - a[1]) * t; d[i + 2] = a[2] + (b[2] - a[2]) * t;
      }
      const c = cv(w, h); ctx2d(c).putImageData(id, 0, 0); return c;
    }
    case "blur": {
      const c = cv(w, h), g = ctx2d(c);
      g.filter = `blur(${Math.max(0.5, e.radius * unit)}px)`; g.drawImage(src, 0, 0); return c;
    }
    case "autocontrast": {
      const id = pixels(src), d = id.data;
      let lo = 255, hi = 0;
      for (let i = 0; i < d.length; i += 16) if (d[i + 3] > 50) { const v = lum(d, i) * 255; lo = Math.min(lo, v); hi = Math.max(hi, v); }
      const k = hi > lo ? 255 / (hi - lo) : 1;
      for (let i = 0; i < d.length; i += 4) for (let j = 0; j < 3; j++) d[i + j] = (d[i + j] - lo) * k;
      const c = cv(w, h); ctx2d(c).putImageData(id, 0, 0); return c;
    }
    case "edges": {
      const id = pixels(src), d = id.data;
      const out = new ImageData(w, h); const o = out.data;
      const [r, gg, b] = hexToRgb(e.color);
      const L = (x: number, y: number) => { const i = (Math.min(h - 1, Math.max(0, y)) * w + Math.min(w - 1, Math.max(0, x))) * 4; return lum(d, i) * (d[i + 3] / 255); };
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const gx = L(x + 1, y) - L(x - 1, y), gy = L(x, y + 1) - L(x, y - 1);
        const m = Math.min(1, Math.hypot(gx, gy) * 4);
        const i = (y * w + x) * 4;
        o[i] = r; o[i + 1] = gg; o[i + 2] = b; o[i + 3] = m > 0.25 ? 255 * m : 0;
      }
      const c = cv(w, h), g = ctx2d(c);
      g.putImageData(out, 0, 0);
      const glow = cv(w, h), gg2 = ctx2d(glow);
      gg2.filter = "blur(2px)"; gg2.drawImage(c, 0, 0); gg2.filter = "none"; gg2.drawImage(c, 0, 0);
      return glow;
    }
    case "riso": {
      const id = pixels(src), d = id.data;
      const out = new ImageData(w, h); const o = out.data;
      const [r, gg, b] = hexToRgb(e.ink);
      const ox = Math.round(e.offset[0] * unit), oy = Math.round(e.offset[1] * unit);
      let seed = 7;
      const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296 - 0.5) * 0.16;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const sx = x - ox, sy = y - oy;
        const i = (y * w + x) * 4;
        o[i] = r; o[i + 1] = gg; o[i + 2] = b;
        if (sx < 0 || sy < 0 || sx >= w || sy >= h) { o[i + 3] = 0; continue; }
        const j = (sy * w + sx) * 4;
        const v = lum(d, j), a = d[j + 3] / 255;
        const ink = e.band === "dark" ? (0.62 - v) * 2.6 : (0.88 - v) * 1.8;
        o[i + 3] = Math.max(0, Math.min(1, ink + rnd())) * a * 255;
      }
      const c = cv(w, h); ctx2d(c).putImageData(out, 0, 0); return c;
    }
    case "posterize": {
      const id = pixels(src), d = id.data;
      const n = Math.max(2, Math.min(16, Math.round(Math.cbrt(e.colors * 2))));
      const q = (v: number) => Math.round((v / 255) * (n - 1)) * (255 / (n - 1));
      for (let i = 0; i < d.length; i += 4) { d[i] = q(d[i]); d[i + 1] = q(d[i + 1]); d[i + 2] = q(d[i + 2]); d[i + 3] = d[i + 3] > 128 ? 255 : 0; }
      const c = cv(w, h); ctx2d(c).putImageData(id, 0, 0); return c;
    }
    case "scanlines": {
      const c = cv(w, h), g = ctx2d(c);
      g.drawImage(src, 0, 0);
      g.globalCompositeOperation = "source-atop";
      g.fillStyle = "rgba(0,0,0,0.28)";
      const step = Math.max(2, Math.round(h / 90));
      for (let y = 0; y < h; y += step * 2) g.fillRect(0, y, w, step);
      return c;
    }
    case "key": {
      const id = pixels(src), d = id.data;
      const corner = [0, (w - 1) * 4, (h - 1) * w * 4, (h * w - 1) * 4];
      const ref = [0, 1, 2].map((j) => corner.reduce((s, i) => s + d[i + j], 0) / 4);
      const tol = Math.max(1, e.tolerance * 441);
      for (let i = 0; i < d.length; i += 4) {
        const dist = Math.hypot(d[i] - ref[0], d[i + 1] - ref[1], d[i + 2] - ref[2]);
        d[i + 3] = Math.min(d[i + 3], Math.max(0, Math.min(255, (dist - tol) * 4)));
      }
      const c = cv(w, h); ctx2d(c).putImageData(id, 0, 0); return c;
    }
    case "flatten": {
      const c = cv(w, h), g = ctx2d(c);
      g.fillStyle = e.color; g.fillRect(0, 0, w, h); g.drawImage(src, 0, 0); return c;
    }
    case "mask": {
      // The mock only does masks that move with the picture and need no other picture; the engine does the rest.
      if (e.lock !== "image" || e.mask.kind === "image") return src;
      const m = renderMaskLocal(e.mask, Math.max(w, h));
      const c = cv(w, h), g = ctx2d(c);
      g.drawImage(src, 0, 0);
      g.globalCompositeOperation = e.invert ? "destination-out" : "destination-in";
      g.drawImage(m, 0, 0, w, h);
      return c;
    }
    case "brightness-contrast": {
      const c = cv(w, h), g = ctx2d(c);
      g.drawImage(src, 0, 0);
      const d = g.getImageData(0, 0, w, h), a = d.data, lut = brightnessContrastTable(e.brightness, e.contrast);
      for (let i = 0; i < a.length; i += 4) { a[i] = lut[a[i]]; a[i + 1] = lut[a[i + 1]]; a[i + 2] = lut[a[i + 2]]; }
      g.putImageData(d, 0, 0);
      return c;
    }
    case "tint": {
      const c = cv(w, h), g = ctx2d(c);
      g.drawImage(src, 0, 0);
      g.globalCompositeOperation = "source-atop"; g.globalAlpha = e.amount; g.fillStyle = e.color; g.fillRect(0, 0, w, h);
      return c;
    }
  }
}

// ---------------------------------------------------------------- shapes (canvas space, square)

export function renderShape(shape: Shape, size: number): HTMLCanvasElement {
  const S = Math.max(8, Math.min(2048, Math.round(size)));
  const c = cv(S, S), g = ctx2d(c);
  const k = S / 1024;
  switch (shape.type) {
    case "solid": g.fillStyle = shape.color; g.fillRect(0, 0, S, S); break;
    case "gradient": {
      const a = (shape.angle * Math.PI) / 180, dx = Math.cos(a) * S / 2, dy = Math.sin(a) * S / 2;
      const gr = g.createLinearGradient(S / 2 - dx, S / 2 - dy, S / 2 + dx, S / 2 + dy);
      gr.addColorStop(0, shape.from); gr.addColorStop(1, shape.to);
      g.fillStyle = gr; g.fillRect(0, 0, S, S); break;
    }
    case "pattern": {
      g.fillStyle = shape.a; g.fillRect(0, 0, S, S); g.fillStyle = shape.b;
      const cell = 96 * k;
      if (shape.pattern === "stripes") {
        g.save(); g.translate(S / 2, S / 2); g.rotate(Math.PI / 4);
        for (let x = -S; x < S; x += cell) g.fillRect(x, -S, cell / 2, S * 2);
        g.restore();
      } else if (shape.pattern === "dots") {
        // Rows and columns counted, as the engine's Shapes.pattern does, so the two match to the pixel.
        const n = Math.ceil(S / cell);
        for (let row = 0; row <= n; row++) for (let col = 0; col <= n; col++) { g.beginPath(); g.arc(col * cell + (row % 2 ? cell / 2 : 0), row * cell, cell * 0.22, 0, 7); g.fill(); }
      } else if (shape.pattern === "grid") {
        const n = Math.ceil(S / cell);
        for (let i = 0; i < n; i++) { g.fillRect(i * cell, 0, 10 * k, S); g.fillRect(0, i * cell, S, 10 * k); }
      } else if (shape.pattern === "checker") {
        const n = Math.ceil(S / cell);
        for (let row = 0; row < n; row++) for (let col = 0; col < n; col++) if ((row + col) % 2 === 0) g.fillRect(col * cell, row * cell, cell, cell);
      } else {
        g.translate(S / 2, S / 2);
        for (let i = 0; i < 16; i++) { g.beginPath(); g.moveTo(0, 0); g.arc(0, 0, S, (i * 2 * Math.PI) / 16, ((i * 2 + 1) * Math.PI) / 16); g.fill(); }
      }
      break;
    }
    case "bands": {
      const n = Math.max(1, shape.colors.length);
      shape.colors.forEach((col, i) => { g.fillStyle = col; g.fillRect(0, (S * i) / n, S, S / n + 1); });
      break;
    }
    case "window": {
      const x0 = 120 * k, y0 = 170 * k, x1 = 904 * k, y1 = 880 * k;
      g.fillStyle = shape.frame; g.beginPath(); g.roundRect(x0 - 14 * k, y0 - 90 * k, x1 - x0 + 28 * k, y1 - y0 + 104 * k, 28 * k); g.fill();
      g.fillStyle = shape.bar; g.beginPath(); g.roundRect(x0 - 14 * k, y0 - 90 * k, x1 - x0 + 28 * k, 80 * k, [28 * k, 28 * k, 0, 0]); g.fill();
      ["#ff5f57", "#febc2e", "#28c840"].forEach((col, i) => { g.fillStyle = col; g.beginPath(); g.arc(x0 + (32 + i * 52) * k, y0 - 48 * k, 18 * k, 0, 7); g.fill(); });
      g.clearRect(x0, y0, x1 - x0, y1 - y0);
      break;
    }
    case "crt": {
      g.fillStyle = shape.bezel; g.beginPath(); g.roundRect(90 * k, 120 * k, 844 * k, 740 * k, 90 * k); g.fill();
      g.fillStyle = shade(shape.bezel, 0.8); g.fillRect(380 * k, 860 * k, 264 * k, 70 * k);
      g.globalCompositeOperation = "destination-out"; g.beginPath(); g.roundRect(150 * k, 190 * k, 724 * k, 570 * k, 60 * k); g.fill();
      break;
    }
    case "disc-rims": {
      const [r, gg, b] = hexToRgb(shape.color);
      g.strokeStyle = `rgba(${r},${gg},${b},0.55)`; g.lineWidth = 60 * k; g.beginPath(); g.arc(S / 2, S / 2, 150 * k, 0, 7); g.stroke();
      g.strokeStyle = `rgba(${r},${gg},${b},0.35)`; g.lineWidth = 12 * k; g.beginPath(); g.arc(S / 2, S / 2, 434 * k, 0, 7); g.stroke();
      break;
    }
    case "rounded-rect": {
      const [x, y, rw, rh] = shape.rect;
      g.fillStyle = shape.color; g.beginPath(); g.roundRect(x * S, y * S, rw * S, rh * S, shape.radius * S); g.fill();
      break;
    }
    case "circle":
      g.fillStyle = shape.color; g.beginPath(); g.arc(S / 2, S / 2, shape.radius * S, 0, 7); g.fill();
      break;
    case "text": {
      const fs = (shape.size ?? 0.86) * S / Math.max(1, shape.text.length * 0.75);
      g.font = `900 ${fs}px "${shape.font}", "Arial Black", system-ui, sans-serif`;
      g.textAlign = "center"; g.textBaseline = "middle"; g.fillStyle = shape.color;
      const m = g.measureText(shape.text);
      const asc = m.actualBoundingBoxAscent, desc = m.actualBoundingBoxDescent;
      g.fillText(shape.text, S / 2, S / 2 + (asc - desc) / 2);
      break;
    }
  }
  return c;
}

// ---------------------------------------------------------------- masks (canvas space, alpha)

/** A mask that needs no picture (ring, fade, shape), drawn at once. */
export function renderMaskLocal(mask: Exclude<Mask, { kind: "image" }>, size: number): HTMLCanvasElement {
  const S = Math.max(8, Math.min(2048, Math.round(size)));
  const c = cv(S, S), g = ctx2d(c);
  drawMaskInto(g, mask, S);
  return c;
}

function drawMaskInto(g: CanvasRenderingContext2D, mask: Exclude<Mask, { kind: "image" }>, S: number) {
  switch (mask.kind) {
    case "ring":
      g.fillStyle = "#fff"; g.beginPath(); g.arc(S / 2, S / 2, mask.outer * S, 0, 7); g.arc(S / 2, S / 2, mask.inner * S, 0, 7, true); g.fill("evenodd");
      break;
    case "linear-fade": {
      const a = (mask.angle * Math.PI) / 180, dx = Math.cos(a) * S * 0.7, dy = Math.sin(a) * S * 0.7;
      const gr = g.createLinearGradient(S / 2 - dx, S / 2 - dy, S / 2 + dx, S / 2 + dy);
      gr.addColorStop(0, "rgba(255,255,255,1)");
      gr.addColorStop(Math.max(0, Math.min(1, mask.start)), "rgba(255,255,255,1)");
      gr.addColorStop(Math.max(0, Math.min(1, Math.max(mask.start + 0.001, mask.end))), "rgba(255,255,255,0)");
      gr.addColorStop(1, "rgba(255,255,255,0)");
      g.fillStyle = gr; g.fillRect(0, 0, S, S);
      break;
    }
    case "shape": {
      const sh = renderShape({ ...mask.shape, ...("color" in mask.shape ? { color: "#ffffff" } : {}) } as Shape, S);
      const t = mask.transform, w = t.width * S;
      if (mask.invert) { g.fillStyle = "#fff"; g.fillRect(0, 0, S, S); g.globalCompositeOperation = "destination-out"; }
      g.translate(t.x * S, t.y * S); g.rotate((t.rotation * Math.PI) / 180); g.drawImage(sh, -w / 2, -w / 2, w, w);
      break;
    }
  }
}

export async function renderMask(mask: Mask, size: number, media: Map<string, Media>): Promise<HTMLCanvasElement> {
  if (mask.kind !== "image") return renderMaskLocal(mask, size);
  const S = Math.max(8, Math.min(2048, Math.round(size)));
  const c = cv(S, S), g = ctx2d(c);
  switch (mask.kind) {
    case "image": {
      const m = media.get(mask.asset);
      if (!m) break;
      const img = await loadImage(m.cutout ?? m.url);
      const t = mask.transform, w = t.width * S, h = (w * img.naturalHeight) / img.naturalWidth;
      g.translate(t.x * S, t.y * S); g.rotate((t.rotation * Math.PI) / 180); g.drawImage(img, -w / 2, -h / 2, w, h);
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.globalCompositeOperation = "source-in"; g.fillStyle = "#fff"; g.fillRect(0, 0, S, S);
      break;
    }
  }
  return c;
}

// ---------------------------------------------------------------- named colours (lab.py's colour_options)

export async function namedColours(url: string): Promise<Record<string, string>> {
  const img = await loadImage(url);
  const c = cv(48, 48), g = ctx2d(c);
  g.drawImage(img, 0, 0, 48, 48);
  const d = g.getImageData(0, 0, 48, 48).data;
  const pts: [number, number, number][] = [];
  for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 128) pts.push([d[i], d[i + 1], d[i + 2]]);
  const k = 6;
  let cents = Array.from({ length: k }, (_, i) => pts[Math.floor((i + 0.5) * pts.length / k)] ?? [128, 128, 128]) as [number, number, number][];
  let counts = new Array(k).fill(0);
  for (let it = 0; it < 8; it++) {
    const sums = cents.map(() => [0, 0, 0]); counts = new Array(k).fill(0);
    for (const p of pts) {
      let bi = 0, bd = Infinity;
      cents.forEach((q, j) => { const dd = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 + (p[2] - q[2]) ** 2; if (dd < bd) { bd = dd; bi = j; } });
      sums[bi][0] += p[0]; sums[bi][1] += p[1]; sums[bi][2] += p[2]; counts[bi]++;
    }
    cents = cents.map((q, j) => counts[j] ? [sums[j][0] / counts[j], sums[j][1] / counts[j], sums[j][2] / counts[j]] : q) as typeof cents;
  }
  const hex = (p: number[]) => "#" + p.map((v) => Math.round(v).toString(16).padStart(2, "0")).join("");
  const chroma = (p: number[]) => Math.max(...p) - Math.min(...p);
  const idx = cents.map((_, i) => i);
  const dominant = idx.sort((a, b) => counts[b] - counts[a])[0];
  const score = (i: number) => chroma(cents[i]) * Math.pow(counts[i] / pts.length, 0.35);
  const byScore = [...idx].sort((a, b) => score(b) - score(a));
  const striking = hex(cents[byScore[0]]), second = hex(cents[byScore[1]]);
  const byL = [...idx].sort((a, b) => cents[a].reduce((s, v) => s + v) - cents[b].reduce((s, v) => s + v));
  const { rgbToHsl, hslToHex } = await import("../lib/colour");
  const [h, s, l] = rgbToHsl(hexToRgb(striking));
  return {
    striking, "second striking": second, dominant: hex(cents[dominant]),
    complement: hslToHex(h + 0.5, s, l), "split complement": hslToHex(h + 0.42, s, l), analogous: hslToHex(h + 0.08, s, l),
    darkest: hex(cents[byL[0]]), lightest: hex(cents[byL[byL.length - 1]]),
    "deep striking": hslToHex(h, s, Math.min(l, 0.22)), "pale striking": hslToHex(h, s * 0.7, Math.max(l, 0.85)),
    black: "#121214", white: "#f6f6f4", paper: mix("#f5f0e4", striking, 0.04),
  };
}
