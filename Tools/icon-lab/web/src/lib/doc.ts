// Helpers over the document model: ids, lookups, defaults and comparisons.
import type { Doc, Group, Layer, Shape, ShapeType, Effect, EffectOp, Mask, Media, Part, Transform } from "../api";

export const MAX_GROUPS = 4;

export function uid(): string {
  return crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36);
}

export const clone = <T,>(o: T): T => structuredClone(o);

/** What a document looks like, without who it is: two docs with the same visual key render the same. */
export function visualKey(d: Doc): string {
  const { id: _i, parent: _p, name: _n, created: _c, origin: _o, ...rest } = d;
  return JSON.stringify(rest);
}

/** A layer by id, a mask layer too: then `parent` is the layer it masks (whose index `li` is) and `mi` its index
 *  in the parent's masks. */
export type LayerHit = { group: Group; layer: Layer; gi: number; li: number; parent?: Layer; mi?: number };
export function findLayer(d: Doc, id: string | null | undefined): LayerHit | null {
  if (!id) return null;
  for (let gi = 0; gi < d.groups.length; gi++) {
    const g = d.groups[gi];
    const li = g.layers.findIndex((l) => l.id === id);
    if (li >= 0) return { group: g, layer: g.layers[li], gi, li };
  }
  for (let gi = 0; gi < d.groups.length; gi++) {
    const g = d.groups[gi];
    for (let li = 0; li < g.layers.length; li++) {
      const mi = g.layers[li].masks?.findIndex((m) => m.id === id) ?? -1;
      if (mi >= 0) return { group: g, layer: g.layers[li].masks![mi], gi, li, parent: g.layers[li], mi };
    }
  }
  return null;
}

/** Every layer's id in the Layers panel's order: front first, each layer's masks after it. */
export function layerIdsInOrder(d: Doc): string[] {
  return d.groups.flatMap((g) => g.layers.flatMap((l) => [l.id, ...(l.masks ?? []).map((m) => m.id)]));
}

/** `r`, relative to `p` (a square `p.width` across, centred on it and turned with it), on the canvas. */
export function composeTransform(p: Transform, r: Transform): Transform {
  const th = (p.rotation * Math.PI) / 180, c = Math.cos(th), s = Math.sin(th);
  const ox = (r.x - 0.5) * p.width, oy = (r.y - 0.5) * p.width;
  return { x: p.x + ox * c - oy * s, y: p.y + ox * s + oy * c, width: p.width * r.width, rotation: p.rotation + r.rotation };
}

/** The inverse of `composeTransform`: a canvas transform `t` relative to `p`. */
export function relativeTransform(p: Transform, t: Transform): Transform {
  const th = (p.rotation * Math.PI) / 180, c = Math.cos(th), s = Math.sin(th);
  const dx = t.x - p.x, dy = t.y - p.y, w = Math.max(1e-6, p.width);
  return { x: 0.5 + (dx * c + dy * s) / w, y: 0.5 + (-dx * s + dy * c) / w, width: t.width / w, rotation: t.rotation - p.rotation };
}

/** A mask of `parent` with its place on the canvas (a locked mask's transform is relative to its parent's). */
export function placed(parent: Layer, m: Layer): Layer {
  return m.lock === "canvas" ? m : { ...m, transform: composeTransform(parent.transform, m.transform) };
}

/** The layer `id` with its place on the canvas, a mask's too. */
export function placedLayer(d: Doc, id: string | null | undefined): Layer | null {
  const h = findLayer(d, id);
  return !h ? null : h.parent ? placed(h.parent, h.layer) : h.layer;
}

/** Sets where layer `id` is on the canvas (a locked mask's transform is kept relative to the layer it masks). */
export function setPlacedTransform(d: Doc, id: string, t: Transform) {
  const h = findLayer(d, id); if (!h) return;
  h.layer.transform = h.parent && h.layer.lock !== "canvas" ? relativeTransform(h.parent.transform, t) : t;
}

/** Whether a layer can become a mask of `target`: not itself, not a mask's mask, and not a layer with masks of its own. */
export function canMask(d: Doc, maskId: string, targetId: string): boolean {
  if (maskId === targetId) return false;
  const m = findLayer(d, maskId), t = findLayer(d, targetId);
  if (!m || !t || t.parent || m.layer.masks?.length) return false;
  return m.parent?.id !== targetId;
}

/** Makes layer `maskId` (a layer, or another's mask) a mask of `targetId`, staying where it is on the canvas until
 *  locked to it. Locked by default. False if it can't (`canMask`). */
export function makeMask(d: Doc, maskId: string, targetId: string): boolean {
  if (!canMask(d, maskId, targetId)) return false;
  const h = findLayer(d, maskId)!;
  const onCanvas = h.parent ? placed(h.parent, h.layer) : h.layer;
  if (h.parent) h.parent.masks!.splice(h.mi!, 1); else h.group.layers.splice(h.li, 1);
  if (h.parent && !h.parent.masks!.length) delete h.parent.masks;
  const target = findLayer(d, targetId)!.layer;
  const m: Layer = { ...h.layer, transform: relativeTransform(target.transform, onCanvas.transform) };
  delete m.lock; delete m.masks;
  (target.masks ??= []).push(m);
  return true;
}

/** Makes mask `id` a layer of its own again, just behind the layer it masked, where it was on the canvas. */
export function releaseMask(d: Doc, id: string) {
  const h = findLayer(d, id); if (!h?.parent) return;
  const l: Layer = { ...placed(h.parent, h.layer) };
  delete l.lock; delete l.invert;
  h.parent.masks!.splice(h.mi!, 1);
  if (!h.parent.masks!.length) delete h.parent.masks;
  h.group.layers.splice(h.li + 1, 0, l);
}

/** Locks mask `id` to the layer it masks, or frees it to a place of its own, without moving it. */
export function setMaskLock(d: Doc, id: string, locked: boolean) {
  const h = findLayer(d, id); if (!h?.parent || locked === (h.layer.lock !== "canvas")) return;
  const t = placed(h.parent, h.layer).transform;
  if (locked) { delete h.layer.lock; h.layer.transform = relativeTransform(h.parent.transform, t); }
  else { h.layer.lock = "canvas"; h.layer.transform = t; }
}

/** A copy of a layer with fresh ids, its masks' too. */
export function withNewIds(l: Layer, id = uid()): Layer {
  const c = clone(l); c.id = id;
  if (c.masks) c.masks = c.masks.map((m) => ({ ...m, id: uid() }));
  return c;
}

export function findGroup(d: Doc, id: string | null | undefined) {
  return id ? d.groups.find((g) => g.id === id) ?? null : null;
}

export function allLayers(d: Doc): Layer[] { return d.groups.flatMap((g) => g.layers); }

/** Every layer and every mask layer. */
export function allLayersAndMasks(d: Doc): Layer[] { return d.groups.flatMap((g) => g.layers.flatMap((l) => [l, ...(l.masks ?? [])])); }

export const NATURAL: Transform = { x: 0.5, y: 0.5, width: 1, rotation: 0 };

export function newGroup(name = "Group"): Group {
  return { id: uid(), name, glass: { specular: true, shadow: 0.35, translucency: null, blur: null }, layers: [] };
}

/** A layer showing one part of a picture ("<media>/<part>"; the whole picture is the media id). */
export function newPartLayer(m: Media, p: Part, at?: { x: number; y: number }): Layer {
  const whole = p.id === "whole";
  const kind = whole ? m.kind : p.kind;
  const pixel = !!m.analysis.pixelArt || Math.max(p.size[0], p.size[1]) <= 96;
  const aspect = p.size[0] / Math.max(1, p.size[1]);
  return {
    id: uid(),
    name: (whole ? m.name.replace(/\.[^.]+$/, "").replace(/^(ia|wikipedia)-/, "") : p.name).slice(0, 40),
    role: kind === "logo" ? "logo" : kind === "icon" ? "icon" : kind === "disc" ? "disc" : p.hasMask ? "subject" : "backdrop",
    opacity: 1,
    content: { kind: "image", asset: whole ? m.id : `${m.id}/${p.id}`, cutout: false, smoothing: pixel ? "pixel" : "smooth", effects: [] },
    transform: { x: at?.x ?? 0.5, y: at?.y ?? 0.5, width: aspect > 1 ? 0.8 : 0.7 * Math.max(0.4, aspect), rotation: 0 },
    mask: null,
  };
}

export function newImageLayer(m: Media, at?: { x: number; y: number }): Layer {
  const cutout = !!m.cutout;
  return {
    id: uid(),
    name: m.name.replace(/\.[^.]+$/, "").replace(/^(ia|wikipedia)-/, "").slice(0, 40),
    role: m.kind === "logo" ? "logo" : m.kind === "icon" ? "icon" : m.kind === "disc" ? "disc" : cutout ? "subject" : "backdrop",
    opacity: 1,
    content: { kind: "image", asset: m.id, cutout, smoothing: m.analysis.pixelArt ? "pixel" : "smooth", effects: [] },
    transform: { x: at?.x ?? 0.5, y: at?.y ?? 0.5, width: 0.7, rotation: 0 },
    mask: null,
  };
}

export const SHAPE_LABELS: Record<ShapeType, string> = {
  solid: "Solid", gradient: "Gradient", pattern: "Pattern", bands: "Bands", window: "Retro window", crt: "CRT bezel",
  "disc-rims": "Disc rims", text: "Text", "rounded-rect": "Rounded rectangle", circle: "Circle",
};

export function defaultShape(type: ShapeType, primary = "#2463d9", secondary = "#f6c445"): Shape {
  switch (type) {
    case "solid": return { type, color: primary };
    case "gradient": return { type, from: primary, to: secondary, angle: 90 };
    case "pattern": return { type, pattern: "stripes", a: primary, b: secondary };
    case "bands": return { type, colors: [secondary, primary, "#1d2347"] };
    case "window": return { type, frame: "#c0c0c0", bar: "#000080" };
    case "crt": return { type, bezel: "#d8d2c4" };
    case "disc-rims": return { type, color: "#ffffff" };
    case "text": return { type, text: "A", font: "Arial Black", color: primary, size: 0.86 };
    case "rounded-rect": return { type, rect: [0.15, 0.15, 0.7, 0.7], radius: 0.1, color: primary };
    case "circle": return { type, radius: 0.4, color: primary };
  }
}

export function newShapeLayer(type: ShapeType, primary?: string, secondary?: string): Layer {
  return {
    id: uid(), name: SHAPE_LABELS[type], role: type === "text" ? "decoration" : "backdrop", opacity: 1,
    content: { kind: "shape", shape: defaultShape(type, primary, secondary) },
    transform: { ...NATURAL }, mask: null,
  };
}

export const EFFECT_LABELS: Record<EffectOp, string> = {
  silhouette: "Silhouette", outline: "Outline (sticker)", feather: "Feather", halftone: "Halftone", tone: "Tone (screenprint)",
  "gradient-map": "Gradient map", blur: "Blur", autocontrast: "Auto contrast", edges: "Edges", riso: "Risograph ink",
  posterize: "Posterise", scanlines: "Scanlines", tint: "Tint", "brightness-contrast": "Brightness / Contrast", key: "Key out background", flatten: "Flatten onto colour", mask: "Mask",
};

export function defaultEffect(op: EffectOp, primary = "#2463d9", secondary = "#f6c445"): Effect {
  switch (op) {
    case "silhouette": return { op, color: primary };
    case "outline": return { op, color: "#ffffff", width: 0.03 };
    case "feather": return { op, softness: 0.03, offset: 0 };
    case "halftone": return { op, ink: primary, cell: 0.025, angle: 45 };
    case "tone": return { op, level: 1, color: primary };
    case "gradient-map": return { op, dark: primary, light: secondary };
    case "blur": return { op, radius: 0.01 };
    case "autocontrast": return { op };
    case "edges": return { op, color: secondary };
    case "riso": return { op, ink: primary, band: "dark", offset: [0.01, 0.01] };
    case "posterize": return { op, colors: 5 };
    case "scanlines": return { op };
    case "tint": return { op, color: primary, amount: 0.4 };
    case "brightness-contrast": return { op, brightness: 0, contrast: 0 };
    case "key": return { op, tolerance: 0.12 };
    case "flatten": return { op, color: "#ffffff" };
    case "mask": return { op, mask: { kind: "ring", outer: 0.43, inner: 0.07 }, lock: "canvas" };
  }
}

export type MaskKind = Mask["kind"] | "none";

export function defaultMask(kind: MaskKind, layer: Layer, fallbackAsset?: string): Mask | null {
  switch (kind) {
    case "none": return null;
    case "ring": return { kind, outer: 0.43, inner: 0.07 };
    case "linear-fade": return { kind, angle: 225, start: 0.3, end: 0.75 };
    case "shape": return { kind, shape: { type: "text", text: "A", font: "Arial Black", color: "#ffffff" }, transform: { ...NATURAL } };
    case "image": return { kind, asset: fallbackAsset ?? (layer.content.kind === "image" ? layer.content.asset : ""), cutout: true, transform: { ...layer.transform } };
  }
}

export function newDoc(program: string, name = "Untitled"): Doc {
  return {
    schema: 1, id: uid(), parent: null, name, program,
    fill: { kind: "gradient", color: "#4a6fd0" },
    groups: [newGroup("Subject")], created: new Date().toISOString(),
  };
}

/** A copy of `d` to edit: a new id, `d` as its parent. */
export function forkDoc(d: Doc, name?: string): Doc {
  const c = clone(d);
  c.id = uid();
  c.parent = d.id;
  c.name = name ?? d.name;
  c.created = new Date().toISOString();
  return c;
}
