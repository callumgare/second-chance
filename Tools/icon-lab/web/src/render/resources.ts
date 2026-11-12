// The pixels the sketch is drawn from: layer contents, shapes and masks, fetched from the engine at the size
// they're shown and kept by request. `get` answers at once with the best copy loaded so far (and asks for a
// sharper one when that's too small); listeners hear when anything new arrives, to redraw.
import { api, type Content, type Effect, type Mask, type Shape, type Transform } from "../api";
import { renderMaskLocal, renderShape } from "../mock/raster";
import { hexToRgb } from "../lib/colour";

export const BUCKETS = [64, 128, 256, 512, 1024, 2048];
export function bucket(px: number): number {
  for (const b of BUCKETS) if (px <= b) return b;
  return 2048;
}

export type Img = HTMLImageElement | HTMLCanvasElement;
export type Box = [number, number, number, number];
type Entry = { img: Img; size: number; w: number; h: number; box: Box };
type Kind = "content" | "shape" | "mask";

/** `box`: where the image sits relative to the content's own box (an outline draws outside it). */
export type Loaded = { img: Img; w: number; h: number; box: Box };

class Resources {
  private loaded = new Map<string, Entry[]>(); // base key → copies by size
  private pending = new Map<string, Promise<void>>(); // base key + size
  private failed = new Set<string>();
  private family = new Map<string, Entry>(); // the content without its width → its latest copy (no flicker while scaling)
  private listeners = new Set<() => void>();
  private scheduled = false;
  version = 0;

  subscribe(fn: () => void) { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; }
  private notify() {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => { this.scheduled = false; this.version++; this.listeners.forEach((f) => f()); });
  }

  private base(kind: Kind, program: string, what: unknown) { return kind + "|" + program + "|" + JSON.stringify(what); }

  /** What a request is "a version of", for showing the last copy while a changed one renders. */
  private familyKey(kind: Kind, program: string, what: any) {
    const c = what.content;
    const f = kind === "content" ? (c?.kind === "image" ? { asset: c.asset, cutout: c.cutout, crop: c.crop ?? null } : { shape: c?.shape?.type }) : kind === "mask" ? { kind: what.kind, asset: what.asset, shape: what.shape?.type } : { type: what.type };
    return "family|" + this.base(kind, program, f);
  }

  private best(base: string, size: number): Entry | null {
    const list = this.loaded.get(base);
    if (!list?.length) return null;
    return list.find((e) => e.size >= size) ?? list[list.length - 1];
  }

  // A layer's content changes many times a second while a slider is dragged: asking for every value queued them all
  // (160 renders for a two-second blur drag, measured), so the preview stepped through stale values long after the
  // slider stopped, each render slowed from about 0.1 s to most of a second by the others of the same picture, and
  // in the app, where the engine shares the process, the window was held up too. So each picture has one render in
  // flight at a time, the largest size waiting going next (the canvas before the small previews), and only the
  // latest request for each size waits; different pictures still render side by side. A request dropped for a
  // newer one is asked again by the next draw if it's still wanted. (After: 21 renders for the same drag, the
  // canvas's about 0.12 s each, the last done within 0.1 s of letting go.)
  private static readonly MAX_RENDERS = 3;
  private running = 0;
  private inFlight = new Set<string>();   // pictures (family keys) with a render in flight
  private waiting = new Map<string, { family: string; size: number; run(): void }>();   // slot → its latest request

  private load(kind: Kind, program: string, what: any, base: string, size: number, now = false): Promise<void> {
    const key = base + "@" + size;
    if (this.failed.has(key)) return Promise.resolve();
    const existing = this.pending.get(key);
    if (existing) return existing;
    if (kind !== "content" || now) return this.start(kind, program, what, base, size);
    const family = this.familyKey(kind, program, what);
    this.waiting.set(family + "@" + size, { family, size, run: () => {
      this.inFlight.add(family);
      this.running++;
      void this.start(kind, program, what, base, size).finally(() => {
        this.inFlight.delete(family);
        this.running--;
        this.pump();
      });
    } });
    this.pump();
    return Promise.resolve();
  }

  private pump() {
    while (this.running < Resources.MAX_RENDERS) {
      let next: [string, { family: string; size: number; run(): void }] | null = null;
      for (const w of this.waiting) if (!this.inFlight.has(w[1].family) && (!next || w[1].size > next[1].size)) next = w;
      if (!next) return;
      this.waiting.delete(next[0]);
      next[1].run();
    }
  }

  private start(kind: Kind, program: string, what: any, base: string, size: number): Promise<void> {
    const key = base + "@" + size;
    const p = (async () => {
      try {
        let url: string;
        let w = 0, h = 0;
        let box: Box = [0, 0, 1, 1];
        if (kind === "content") { const r = await api.renderContent(program, what.content, size, what.cw ?? 1, what.t); url = r.url; w = r.width; h = r.height; if (r.box) box = r.box; }
        else if (kind === "shape") url = (await api.renderShape(program, what, size)).url;
        else url = (await api.renderMask(program, what, size)).url;
        const raw = await loadImage(url);
        const img: Img = kind === "mask" ? luminanceToAlpha(raw) : raw;
        if (!w) { w = raw.naturalWidth; h = raw.naturalHeight; }
        const list = this.loaded.get(base) ?? [];
        list.push({ img, size, w, h, box });
        list.sort((a, b) => a.size - b.size);
        this.loaded.set(base, list);
        this.family.set(this.familyKey(kind, program, what), list[list.length - 1]);
        this.notify();
      } catch (e) {
        this.failed.add(key);
        console.warn("render failed", kind, e);
      } finally {
        this.pending.delete(key);
      }
    })();
    this.pending.set(key, p);
    return p;
  }

  private getAny(kind: Kind, program: string, what: unknown, px: number): Loaded | null {
    const size = bucket(Math.max(16, px));
    const base = this.base(kind, program, what);
    const have = this.best(base, size);
    if (!have || have.size < size) void this.load(kind, program, what, base, size);
    const use = have ?? this.family.get(this.familyKey(kind, program, what));
    return use ? { img: use.img, w: use.w, h: use.h, box: use.box } : null;
  }

  /** A layer's content. Its last effect's colour is applied here, over a copy rendered in neutral colours, so
   *  changing a colour never waits on the engine. */
  content(program: string, content: Content, px: number, canvasWidth?: number, transform?: Transform): Loaded | null {
    const { neutral, spec } = splitColour(splitMasks(content).head);
    const got = this.getAny("content", program, contentWhat(neutral, canvasWidth, transform), px);
    if (!got || !spec) return got;
    return { ...got, img: recoloured(got.img, spec) };
  }
  /** Shapes are drawn here, at once (the engine draws the same for the real icon). */
  shape(_program: string, shape: Shape, px: number): Loaded | null {
    const size = bucket(Math.max(16, px));
    const key = JSON.stringify(shape) + "@" + size;
    let c = this.local.get(key);
    if (!c) { c = renderShape(shape, size); this.local.set(key, c); this.trimLocal(); }
    return { img: c, w: c.width, h: c.height, box: [0, 0, 1, 1] };
  }
  /** Masks made of shapes are drawn here; another picture's silhouette comes from the engine. */
  mask(program: string, mask: Mask, px: number): Loaded | null {
    if (mask.kind === "image") return this.getAny("mask", program, mask, px);
    const size = bucket(Math.max(16, px));
    const key = "mask|" + JSON.stringify(mask) + "@" + size;
    let c = this.local.get(key);
    if (!c) { c = renderMaskLocal(mask, size); this.local.set(key, c); this.trimLocal(); }
    return { img: c, w: c.width, h: c.height, box: [0, 0, 1, 1] };
  }
  private local = new Map<string, HTMLCanvasElement>();
  private trimLocal() { if (this.local.size > 400) for (const k of [...this.local.keys()].slice(0, 100)) this.local.delete(k); }

  /** Waits for the exact sizes asked for (used before drawing something that must be complete). */
  async ensure(reqs: { kind: Kind; program: string; what: unknown; px: number }[]) {
    await Promise.all(reqs.filter((r) => r.kind === "content" || (r.kind === "mask" && (r.what as Mask).kind === "image")).map((r) => {
      if (r.kind === "content") { const w = r.what as any; r = { ...r, what: { ...w, content: splitColour(splitMasks(w.content).head).neutral } }; }
      const size = bucket(Math.max(16, r.px));
      const base = this.base(r.kind, r.program, r.what);
      const have = this.best(base, size);
      return have && have.size >= size ? Promise.resolve() : this.load(r.kind, r.program, r.what, base, size, true);
    }));
  }

  pendingCount() { return this.pending.size; }
}

export const resources = new Resources();

/** Effects sized in canvas units depend on how wide the layer is: only then is its width part of the key. */
export function contentWhat(content: Content, canvasWidth?: number, transform?: Transform) {
  // Only those effects' renders depend on the width; others are asked with 1 so scaling doesn't re-render them.
  const fx = content.kind === "image" ? content.effects : [];
  const sized = fx.some((e) => e.op === "outline" || e.op === "feather" || e.op === "halftone" || e.op === "blur" || e.op === "riso" || (e.op === "mask" && e.lock === "canvas"));
  // A canvas-locked mask still in the chain (not trailing: those are applied in the page) depends on where the layer is.
  const placed = fx.some((e) => e.op === "mask" && e.lock === "canvas") && transform;
  const r3 = (v: number) => Math.round(v * 500) / 500;
  return {
    content,
    ...(sized && canvasWidth != null ? { cw: Math.round(canvasWidth * 50) / 50 } : {}),
    ...(placed ? { t: { x: r3(transform.x), y: r3(transform.y), width: r3(transform.width), rotation: Math.round(transform.rotation) } } : {}),
  };
}

/** Canvas-locked masks at the end of the effects are applied by the page (the content is asked for without them),
 *  so moving the layer never waits on the engine. */
export function splitMasks(content: Content): { head: Content; trailing: { mask: Mask; invert: boolean }[] } {
  if (content.kind !== "image") return { head: content, trailing: [] };
  const fx = [...content.effects];
  const trailing: { mask: Mask; invert: boolean }[] = [];
  while (fx.length) {
    const e = fx[fx.length - 1];
    if (e.op !== "mask" || e.lock !== "canvas") break;
    trailing.unshift({ mask: e.mask, invert: !!e.invert });
    fx.pop();
  }
  return trailing.length ? { head: { ...content, effects: fx }, trailing } : { head: content, trailing };
}

const imageCache = new Map<string, Promise<HTMLImageElement>>();
export function loadImage(url: string): Promise<HTMLImageElement> {
  let p = imageCache.get(url);
  if (!p) {
    p = new Promise((resolve, reject) => {
      const img = new Image();
      img.decoding = "async";
      img.onload = () => resolve(img);
      img.onerror = () => { imageCache.delete(url); reject(new Error("image failed: " + url)); };
      img.src = url;
    });
    imageCache.set(url, p);
  }
  return p;
}

/** An L8 (greyscale, opaque) mask becomes an alpha mask, so it can clip with destination-in. A mask that
 *  already has alpha is used as it is. */
function luminanceToAlpha(img: HTMLImageElement): Img {
  const w = img.naturalWidth, h = img.naturalHeight;
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  const g = c.getContext("2d", { willReadFrequently: true })!;
  g.drawImage(img, 0, 0);
  let d: ImageData;
  try { d = g.getImageData(0, 0, w, h); } catch { return img; }
  const a = d.data;
  let opaque = true;
  for (let i = 3; i < a.length; i += 4 * 7) if (a[i] !== 255) { opaque = false; break; }
  if (!opaque) return img;
  for (let i = 0; i < a.length; i += 4) { a[i + 3] = a[i]; a[i] = a[i + 1] = a[i + 2] = 255; }
  g.putImageData(d, 0, 0);
  return c;
}

/** Alpha (0…255) at a point (0…1) of an image, for picking layers by their visible pixels. */
const alphaMaps = new WeakMap<Img, { data: Uint8ClampedArray; w: number; h: number }>();
export function alphaAt(img: Img, u: number, v: number): number {
  if (u < 0 || v < 0 || u > 1 || v > 1) return 0;
  let m = alphaMaps.get(img);
  if (!m) {
    const iw = img instanceof HTMLImageElement ? img.naturalWidth : img.width;
    const ih = img instanceof HTMLImageElement ? img.naturalHeight : img.height;
    const w = Math.max(1, Math.min(256, iw)), h = Math.max(1, Math.round(w * (ih / (iw || 1))));
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const g = c.getContext("2d", { willReadFrequently: true })!;
    g.drawImage(img, 0, 0, w, h);
    try { m = { data: g.getImageData(0, 0, w, h).data, w, h }; } catch { return 255; }
    alphaMaps.set(img, m);
  }
  const x = Math.min(m.w - 1, Math.floor(u * m.w)), y = Math.min(m.h - 1, Math.floor(v * m.h));
  return m.data[(y * m.w + x) * 4 + 3];
}

// ---------------------------------------------------------------- colours applied in the page

type Spec =
  | { kind: "ink"; color: string }                       // single-ink effects: every visible pixel takes the colour
  | { kind: "gmap"; dark: string; light: string }        // gradient map: luminance → dark…light
  | { kind: "tint"; color: string; amount: number }      // blend towards a colour
  | { kind: "key"; color: string }                       // outline: the key colour's pixels take the colour

const NEUTRAL_KEY = "#ff00ff";

/** The content to ask the engine for (its last effect's colours made neutral) and how to colour the result. */
export function splitColour(content: Content): { neutral: Content; spec: Spec | null } {
  if (content.kind !== "image" || !content.effects.length) return { neutral: content, spec: null };
  const effects = content.effects;
  const last = effects[effects.length - 1];
  const keep = effects.slice(0, -1);
  const withLast = (e: Effect | null) => ({ neutral: { ...content, effects: e ? [...keep, e] : keep } as Content });
  switch (last.op) {
    case "silhouette": case "edges": return { ...withLast({ ...last, color: "#000000" }), spec: { kind: "ink", color: last.color } };
    case "tone": return { ...withLast({ ...last, color: "#000000" }), spec: { kind: "ink", color: last.color } };
    case "halftone": case "riso": return { ...withLast({ ...last, ink: "#000000" }), spec: { kind: "ink", color: last.ink } };
    case "gradient-map": return { ...withLast({ ...last, dark: "#000000", light: "#ffffff" }), spec: { kind: "gmap", dark: last.dark, light: last.light } };
    case "tint": return { ...withLast(null), spec: { kind: "tint", color: last.color, amount: last.amount } };
    case "outline": return { ...withLast({ ...last, color: NEUTRAL_KEY }), spec: { kind: "key", color: last.color } };
    default: return { neutral: content, spec: null };
  }
}

const recolourCache = new WeakMap<Img, Map<string, HTMLCanvasElement>>();
function recoloured(img: Img, spec: Spec): HTMLCanvasElement {
  let byImg = recolourCache.get(img);
  if (!byImg) { byImg = new Map(); recolourCache.set(img, byImg); }
  const key = JSON.stringify(spec);
  let c = byImg.get(key);
  if (c) return c;
  const w = img instanceof HTMLImageElement ? img.naturalWidth : img.width, h = img instanceof HTMLImageElement ? img.naturalHeight : img.height;
  c = document.createElement("canvas"); c.width = Math.max(1, w); c.height = Math.max(1, h);
  const g = c.getContext("2d", { willReadFrequently: true })!;
  g.drawImage(img, 0, 0);
  if (spec.kind === "ink") {
    g.globalCompositeOperation = "source-in"; g.fillStyle = spec.color; g.fillRect(0, 0, w, h);
  } else if (spec.kind === "tint") {
    g.globalCompositeOperation = "source-atop"; g.globalAlpha = spec.amount; g.fillStyle = spec.color; g.fillRect(0, 0, w, h);
  } else {
    try {
      const d = g.getImageData(0, 0, w, h), a = d.data;
      if (spec.kind === "gmap") {
        const [r0, g0, b0] = hexToRgb(spec.dark), [r1, g1, b1] = hexToRgb(spec.light);
        for (let i = 0; i < a.length; i += 4) { const t = a[i] / 255; a[i] = r0 + (r1 - r0) * t; a[i + 1] = g0 + (g1 - g0) * t; a[i + 2] = b0 + (b1 - b0) * t; }
      } else {
        const [r1, g1, b1] = hexToRgb(spec.color);
        for (let i = 0; i < a.length; i += 4) {
          // How magenta the pixel is: 1 on the border, fading where it was blended with the picture.
          const m = Math.max(0, Math.min(1, (Math.min(a[i], a[i + 2]) - a[i + 1]) / 200));
          if (m > 0.02) { a[i] = a[i] + (r1 - a[i]) * m; a[i + 1] = a[i + 1] + (g1 - a[i + 1]) * m; a[i + 2] = a[i + 2] + (b1 - a[i + 2]) * m; }
        }
      }
      g.putImageData(d, 0, 0);
    } catch { /* tainted: leave it neutral */ }
  }
  if (byImg.size > 12) byImg.delete(byImg.keys().next().value!);
  byImg.set(key, c);
  return c;
}
