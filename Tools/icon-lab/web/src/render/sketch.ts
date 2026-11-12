// The browser's quick sketch of a document (document.md, "How it renders"): the fill as a gradient, groups
// back to front, each layer's content placed by its transform and clipped by its masks, and the glass only
// hinted at (a top highlight and a drop shadow). ictool's render is the real thing.
import type { Appearance, Doc, Layer, Mask, Media } from "../api";
import { hexToRgb, shade } from "../lib/colour";
import { placed } from "../lib/doc";
import { alphaAt, contentWhat, resources, splitMasks, type Img } from "./resources";

export type SketchOptions = {
  appearance: Appearance
  /** Device pixels per unit of `size` (for shadow blur, which ignores transforms, and sharp copies). */
  pixelRatio?: number
  media?: Map<string, Media>
  /** Clip to the icon shape. */
  clip?: boolean
  hiddenLayer?: string | null
}

export const TINT = "#8aa7ff";

/** The icon's rounded square. A plain rounded rect is close enough to the squircle at sketch sizes. */
export function iconPath(ctx: CanvasRenderingContext2D, size: number) {
  const r = size * 0.2237;
  ctx.beginPath();
  ctx.roundRect(0, 0, size, size, r);
}

function fillColour(doc: Doc, appearance: Appearance): string | null {
  if (doc.fill.kind === "none") return null;
  switch (appearance) {
    case "light": return doc.fill.color;
    case "dark": return doc.fill.dark ?? shade(doc.fill.color, 0.45);
    case "tinted": return "#2b2d33";
    case "clear": return "#5b6170";
  }
}

/** The pixel aspect (w / h) a layer's content has, from the render if one has arrived, else from the media. */
export function contentAspect(program: string, layer: Layer, media?: Map<string, Media>): number {
  const c = layer.content;
  if (c.kind === "shape") return 1;
  const got = resources.content(program, c, 0, layer.transform.width) ?? null; // any size, just for the aspect
  if (got && got.w && got.h) { const [x0, y0, x1, y1] = got.box; return (got.w / (x1 - x0)) / (got.h / (y1 - y0)); }
  const [mid, rest] = c.asset.split("/");
  const m = media?.get(mid);
  if (!m) return 1;
  if (rest) {
    const p = m.parts?.find((x) => x.id === rest.replace(/@(x4|px4)$/, ""));
    if (p) { let [w, h] = p.size; if (c.crop) { w *= c.crop[2]; h *= c.crop[3]; } return h > 0 ? w / h : 1; }
  }
  let w = m.width, h = m.height;
  if (c.cutout && m.cutoutSize) { w = m.cutoutSize[0]; h = m.cutoutSize[1]; }
  else if (c.cutout && m.analysis.subjectBox) { w *= m.analysis.subjectBox[2]; h *= m.analysis.subjectBox[3]; }
  if (c.crop) { w *= c.crop[2]; h *= c.crop[3]; }
  return h > 0 ? w / h : 1;
}

/** The layer's box on a canvas of `size`: centre, width, height, rotation (radians). */
export function layerBox(program: string, layer: Layer, size: number, media?: Map<string, Media>) {
  const t = layer.transform;
  const w = t.width * size;
  const h = w / contentAspect(program, layer, media);
  return { cx: t.x * size, cy: t.y * size, w, h, rot: (t.rotation * Math.PI) / 180 };
}

const UNIT: [number, number, number, number] = [0, 0, 1, 1];
function layerImage(program: string, layer: Layer, displayPx: number): { img: Img; box: [number, number, number, number] } | null {
  const c = layer.content;
  if (c.kind === "image") { const r = resources.content(program, c, displayPx, layer.transform.width, layer.transform); return r ? { img: r.img, box: r.box } : null; }
  const r = resources.shape(program, c.shape, displayPx);
  return r ? { img: r.img, box: UNIT } : null;
}

/** Draws an image over `box` of a content box w × h centred at the origin. */
export function drawInBox(ctx: CanvasRenderingContext2D, img: Img, box: [number, number, number, number], w: number, h: number) {
  const [x0, y0, x1, y1] = box;
  ctx.drawImage(img, -w / 2 + x0 * w, -h / 2 + y0 * h, (x1 - x0) * w, (y1 - y0) * h);
}

// Scratch canvases, reused between draws.
const pool: HTMLCanvasElement[] = [];
function scratch(i: number, px: number): CanvasRenderingContext2D {
  let c = pool[i];
  if (!c) { c = document.createElement("canvas"); pool[i] = c; }
  if (c.width !== px || c.height !== px) { c.width = px; c.height = px; }
  const g = c.getContext("2d")!;
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.globalCompositeOperation = "source-over";
  g.globalAlpha = 1;
  g.filter = "none";
  g.clearRect(0, 0, px, px);
  return g;
}

/** Draws `doc` into `ctx` over a square of `size` units at the origin. */
export function drawSketch(ctx: CanvasRenderingContext2D, doc: Doc, size: number, opts: SketchOptions) {
  const pr = opts.pixelRatio ?? 1;
  const px = Math.max(1, Math.round(size * pr));
  const program = doc.program;
  ctx.save();
  if (opts.clip !== false) { iconPath(ctx, size); ctx.clip(); }

  // Fill: Icon Composer's automatic gradient is lighter at the top.
  const fc = fillColour(doc, opts.appearance);
  if (fc) {
    if (doc.fill.kind === "gradient" || opts.appearance === "tinted" || opts.appearance === "clear") {
      const g = ctx.createLinearGradient(0, 0, 0, size);
      g.addColorStop(0, shade(fc, 1.16));
      g.addColorStop(0.55, fc);
      g.addColorStop(1, shade(fc, 0.82));
      ctx.fillStyle = g;
    } else ctx.fillStyle = fc;
    ctx.fillRect(0, 0, size, size);
  }

  const layerFilter = opts.appearance === "tinted" ? "grayscale(1) brightness(1.15) contrast(1.1)"
    : opts.appearance === "clear" ? "grayscale(1) brightness(1.5) contrast(0.85)"
    : opts.appearance === "dark" ? "brightness(0.94)" : "none";

  // Groups back to front (the array is front first).
  for (let gi = doc.groups.length - 1; gi >= 0; gi--) {
    const group = doc.groups[gi];
    if (group.hidden) continue;
    const gctx = scratch(0, px);
    gctx.scale(pr, pr);
    let drewAny = false;
    for (let li = group.layers.length - 1; li >= 0; li--) {
      const layer = group.layers[li];
      if (layer.hidden || layer.id === opts.hiddenLayer) continue;
      const box = layerBox(program, layer, size, opts.media);
      const got = layerImage(program, layer, Math.max(box.w, box.h) * pr);
      if (!got) continue;
      const masks = canvasMasks(layer);
      const maskLayers = (layer.masks ?? []).filter((m) => !m.hidden);
      const masked = masks.length > 0 || maskLayers.length > 0;
      const target = masked ? scratch(1, px) : gctx;
      if (masked) target.scale(pr, pr);
      target.save();
      target.globalAlpha = masked ? 1 : layer.opacity;
      target.imageSmoothingEnabled = !(layer.content.kind === "image" && layer.content.smoothing === "pixel");
      target.translate(box.cx, box.cy);
      target.rotate(box.rot);
      drawInBox(target, got.img, got.box, box.w, box.h);
      target.restore();
      if (masked) {
        for (const mk of masks) {
          const img = resources.mask(program, mk.mask, px)?.img;
          if (!img) continue;
          target.globalCompositeOperation = mk.invert ? "destination-out" : "destination-in";
          target.drawImage(img, 0, 0, size, size);
        }
        // Mask layers: each drawn where it sits, the layer kept where it's opaque (or, inverted, where it isn't). One
        // not loaded yet hides the layer rather than showing it unmasked for a moment.
        for (const m of maskLayers) {
          const ml = placed(layer, m);
          const mctx = scratch(2, px);
          mctx.scale(pr, pr);
          const mb = layerBox(program, ml, size, opts.media);
          const mg = layerImage(program, ml, Math.max(mb.w, mb.h) * pr);
          if (mg) {
            mctx.globalAlpha = m.opacity;
            mctx.imageSmoothingEnabled = !(m.content.kind === "image" && m.content.smoothing === "pixel");
            mctx.translate(mb.cx, mb.cy);
            mctx.rotate(mb.rot);
            drawInBox(mctx, mg.img, mg.box, mb.w, mb.h);
          }
          target.save();
          target.setTransform(1, 0, 0, 1, 0, 0);
          target.globalCompositeOperation = m.invert ? "destination-out" : "destination-in";
          target.drawImage(mctx.canvas, 0, 0);
          target.restore();
        }
        target.globalCompositeOperation = "source-over";
        gctx.save();
        gctx.setTransform(1, 0, 0, 1, 0, 0);
        gctx.globalAlpha = layer.opacity;
        gctx.drawImage(target.canvas, 0, 0);
        gctx.restore();
      }
      drewAny = true;
    }
    if (!drewAny) continue;

    // Specular: a soft light across the top of the group's own pixels.
    if (group.glass.specular && opts.appearance !== "clear") {
      gctx.save();
      gctx.globalCompositeOperation = "source-atop";
      const s = gctx.createLinearGradient(0, 0, 0, size);
      s.addColorStop(0, "rgba(255,255,255,0.28)");
      s.addColorStop(0.45, "rgba(255,255,255,0.04)");
      s.addColorStop(1, "rgba(255,255,255,0)");
      gctx.fillStyle = s;
      gctx.fillRect(0, 0, size, size);
      gctx.restore();
    }

    ctx.save();
    ctx.globalAlpha = group.glass.translucency != null ? 1 - group.glass.translucency * 0.55 : opts.appearance === "clear" ? 0.8 : 1;
    // The group's shadow, matched to Icon Composer's (measured from ictool renders): faint, soft (blur ≈ 4 % of the
    // icon), a little below. Neutral is black at ≈ 10 % × opacity at its core; chromatic is the group's own colours,
    // darkened and blurred, about twice as strong.
    const shadowKind = group.glass.shadowKind ?? (group.glass.shadow > 0 ? "neutral" : "none");
    const shadowOn = shadowKind !== "none" && group.glass.shadow > 0;
    if (shadowOn && shadowKind === "chromatic") {
      ctx.save();
      ctx.globalAlpha *= Math.min(1, 0.47 * group.glass.shadow);
      ctx.filter = `blur(${size * 0.022 * pr}px) saturate(1.5) brightness(0.7)`;
      ctx.drawImage(gctx.canvas, 0, 0, px, px, 0, size * 0.014, size, size);
      ctx.restore();
    } else if (shadowOn) {
      ctx.shadowColor = `rgba(0,0,0,${Math.min(0.6, group.glass.shadow * 0.1)})`;
      ctx.shadowBlur = size * 0.04 * pr;
      ctx.shadowOffsetY = size * 0.014 * pr;
    }
    ctx.filter = layerFilter;
    ctx.drawImage(gctx.canvas, 0, 0, px, px, 0, 0, size, size);
    ctx.restore();
  }

  if (opts.appearance === "tinted") {
    ctx.save();
    ctx.globalCompositeOperation = "color";
    ctx.globalAlpha = 0.75;
    ctx.fillStyle = TINT;
    ctx.fillRect(0, 0, size, size);
    ctx.restore();
  }

  // A thin rim of light along the edge, as the glass has.
  if (opts.clip !== false && fc) {
    ctx.save();
    iconPath(ctx, size);
    const [r, g, b] = hexToRgb("#ffffff");
    const rim = ctx.createLinearGradient(0, 0, 0, size);
    rim.addColorStop(0, `rgba(${r},${g},${b},0.45)`);
    rim.addColorStop(0.3, `rgba(${r},${g},${b},0.08)`);
    rim.addColorStop(1, `rgba(${r},${g},${b},0.18)`);
    ctx.strokeStyle = rim;
    ctx.lineWidth = Math.max(1 / pr, size * 0.006);
    ctx.stroke();
    ctx.restore();
  }
  ctx.restore();
}

/** Every resource the sketch of `doc` at `size` would ask for, to wait for them all. */
export function sketchRequests(doc: Doc, size: number, media?: Map<string, Media>) {
  const reqs: { kind: "content" | "shape" | "mask"; program: string; what: unknown; px: number }[] = [];
  for (const g of doc.groups) {
    if (g.hidden) continue;
    for (const l of g.layers) {
      if (l.hidden) continue;
      const box = layerBox(doc.program, l, size, media);
      const px = Math.max(box.w, box.h);
      if (l.content.kind === "image") reqs.push({ kind: "content", program: doc.program, what: contentWhat(l.content, l.transform.width, l.transform), px });
      else reqs.push({ kind: "shape", program: doc.program, what: l.content.shape, px });
      for (const mk of canvasMasks(l)) reqs.push({ kind: "mask", program: doc.program, what: mk.mask, px: size });
      for (const m of l.masks ?? []) {
        if (m.hidden) continue;
        const ml = placed(l, m), mb = layerBox(doc.program, ml, size, media);
        if (ml.content.kind === "image") reqs.push({ kind: "content", program: doc.program, what: contentWhat(ml.content, ml.transform.width, ml.transform), px: Math.max(mb.w, mb.h) });
        else reqs.push({ kind: "shape", program: doc.program, what: ml.content.shape, px: Math.max(mb.w, mb.h) });
      }
    }
  }
  return reqs;
}

/** The front-most visible layer under a point (canvas units 0…1), by its pixels. */
export function pickLayer(doc: Doc, u: number, v: number, media?: Map<string, Media>): Layer | null {
  for (const g of doc.groups) {
    if (g.hidden) continue;
    for (const l of g.layers) {
      if (l.hidden) continue;
      const a = alphaUnder(doc.program, l, u, v, media);
      if (a == null || a < 40) continue;
      if (canvasMasks(l).some((mk) => { const m = resources.mask(doc.program, mk.mask, 0)?.img; return m ? (alphaAt(m, u, v) < 40) !== mk.invert : false; })) continue;
      if ((l.masks ?? []).some((m) => !m.hidden && ((alphaUnder(doc.program, placed(l, m), u, v, media) ?? 0) < 40) !== !!m.invert)) continue;
      return l;
    }
  }
  return null;
}

/** A layer's alpha at a point (canvas units 0…1): null outside its box, 255 where its pixels haven't arrived. */
function alphaUnder(program: string, l: Layer, u: number, v: number, media?: Map<string, Media>): number | null {
  const size = 1000;
  const box = layerBox(program, l, size, media);
  const dx = u * size - box.cx, dy = v * size - box.cy;
  const c = Math.cos(-box.rot), s = Math.sin(-box.rot);
  const lx = dx * c - dy * s, ly = dx * s + dy * c;
  const fu = lx / box.w + 0.5, fv = ly / box.h + 0.5;
  if (fu < 0 || fu > 1 || fv < 0 || fv > 1) return null;
  const got = layerImage(program, l, 0);
  if (!got) return 255;
  const [x0, y0, x1, y1] = got.box;
  return alphaAt(got.img, (fu - x0) / (x1 - x0), (fv - y0) / (y1 - y0));
}

/** Draws a sketch onto a fresh canvas element. */
export function sketchCanvas(doc: Doc, cssSize: number, appearance: Appearance, media?: Map<string, Media>, canvas?: HTMLCanvasElement) {
  const pr = window.devicePixelRatio || 1;
  const c = canvas ?? document.createElement("canvas");
  const px = Math.round(cssSize * pr);
  // Both sides: a new canvas is 300×150, so a 300 px icon (150 pt on a Retina screen, Review's size) kept its
  // height and showed stretched until the real render came.
  if (c.width !== px || c.height !== px) { c.width = px; c.height = px; }
  const g = c.getContext("2d")!;
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.clearRect(0, 0, px, px);
  g.scale(pr, pr);
  drawSketch(g, doc, cssSize, { appearance, pixelRatio: pr, media });
  return c;
}

/** The masks the page applies on the canvas: a document's old `layer.mask`, then trailing canvas-locked mask effects. */
export function canvasMasks(layer: Layer): { mask: Mask; invert: boolean }[] {
  const out: { mask: Mask; invert: boolean }[] = [];
  if (layer.mask) out.push({ mask: layer.mask, invert: false });
  out.push(...splitMasks(layer.content).trailing);
  return out;
}
