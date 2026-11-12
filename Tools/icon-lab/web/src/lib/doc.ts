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

export function findLayer(d: Doc, id: string | null | undefined): { group: Group; layer: Layer; gi: number; li: number } | null {
  if (!id) return null;
  for (let gi = 0; gi < d.groups.length; gi++) {
    const g = d.groups[gi];
    const li = g.layers.findIndex((l) => l.id === id);
    if (li >= 0) return { group: g, layer: g.layers[li], gi, li };
  }
  return null;
}

export function findGroup(d: Doc, id: string | null | undefined) {
  return id ? d.groups.find((g) => g.id === id) ?? null : null;
}

export function allLayers(d: Doc): Layer[] { return d.groups.flatMap((g) => g.layers); }

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
