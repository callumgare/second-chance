// An Icon Composer `.icon`'s icon.json, read back into a design: its fill, its groups' Liquid Glass and its layers
// placed as Icon Composer places them. Kept free of the page's state so it can be checked on its own.
//
// Icon Composer draws each layer's picture at its size in points (a PNG's pixels; `@2x` halves them) on a canvas
// of 1024 points, centred, then moved by `position`'s `translation-in-points` (y down) and scaled by its `scale`
// about the layer's centre; a group's `position` moves and scales its layers about the canvas's centre. A
// `-specializations` list (per appearance) gives way to its plain key, or else to its entry for no appearance.
import type { Doc, Fill, Glass, Group, Layer } from "../api";

const CANVAS = 1024;

/** An icon.json, loosely: only what's read here is named. */
export type IconJSON = { [key: string]: unknown; groups?: unknown[] };

/** A picture the icon names (`image-name`), once added to the program: its media id and its size in points. */
export type IconPicture = { asset: string; width: number; height: number; pixelArt?: boolean };

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

/** `key`'s value for the default appearance: the plain key, or the specialization with no appearance. */
function plain(o: Obj, key: string): unknown {
  if (key in o) return o[key];
  const specs = o[`${key}-specializations`];
  if (!Array.isArray(specs)) return undefined;
  const any = specs.map(obj).filter((s): s is Obj => !!s);
  return (any.find((s) => !("appearance" in s) && !("idiom" in s)) ?? any.find((s) => !("appearance" in s)))?.value;
}

/** `key`'s value for one appearance ("dark"), if the icon says one. */
function forAppearance(o: Obj, key: string, appearance: string): unknown {
  const specs = o[`${key}-specializations`];
  if (!Array.isArray(specs)) return undefined;
  return specs.map(obj).find((s) => s?.appearance === appearance)?.value;
}

/** Icon Composer's colour (`srgb:r,g,b,a`, `display-p3:…`, `extended-srgb:…`, `gray:w,a`) as #rrggbb. Display P3
 *  is taken as sRGB: close enough for a fill the person can change. */
export function colourFromIconComposer(s: unknown): string | undefined {
  if (typeof s !== "string") return undefined;
  const m = /^([a-z0-9-]+):(.+)$/i.exec(s.trim());
  if (!m) return undefined;
  const v = m[2].split(",").map((x) => Number(x.trim()));
  if (v.some((x) => !Number.isFinite(x))) return undefined;
  const rgb = m[1].includes("gray") ? [v[0], v[0], v[0]] : v.slice(0, 3);
  if (rgb.length < 3) return undefined;
  return "#" + rgb.map((x) => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16).padStart(2, "0")).join("");
}

/** A fill value (`{solid: c}`, `{"automatic-gradient": c}`, `{"linear-gradient": [c, …]}`) as a kind and colour. */
function readFill(v: unknown): { kind: Fill["kind"]; color: string } | undefined {
  const o = obj(v);
  if (!o) return undefined;   // "automatic", "system-light", …: Icon Composer's own, which a design leaves out
  if (o.solid != null) { const c = colourFromIconComposer(o.solid); return c ? { kind: "solid", color: c } : undefined; }
  const g = o["automatic-gradient"] ?? (Array.isArray(o["linear-gradient"]) ? o["linear-gradient"][0] : undefined);
  const c = colourFromIconComposer(g);
  return c ? { kind: "gradient", color: c } : undefined;
}

function fillOf(icon: Obj): Fill {
  const light = readFill(plain(icon, "fill"));
  if (!light) return { kind: "none", color: "#000000" };
  const dark = readFill(forAppearance(icon, "fill", "dark"));
  return dark ? { ...light, dark: dark.color } : light;
}

function glassOf(g: Obj): Glass {
  const shadow = obj(plain(g, "shadow"));
  const kind = shadow?.kind;
  const translucency = obj(plain(g, "translucency"));
  const blur = num(plain(g, "blur-material"));
  const lighting = plain(g, "lighting");
  return {
    specular: plain(g, "specular") !== false,
    shadow: num(shadow?.opacity) ?? 0.35,
    shadowKind: kind === "none" ? "none" : kind === "layer-color" ? "chromatic" : "neutral",
    lighting: lighting === "combined" ? "combined" : "individual",
    translucency: translucency?.enabled === true ? num(translucency.value) ?? 0.5 : null,
    blur: blur ?? null,
  };
}

type Position = { scale: number; dx: number; dy: number };
function positionOf(o: Obj): Position {
  const p = obj(plain(o, "position"));
  const t = Array.isArray(p?.["translation-in-points"]) ? (p["translation-in-points"] as unknown[]) : [];
  return { scale: num(p?.scale) ?? 1, dx: num(t[0]) ?? 0, dy: num(t[1]) ?? 0 };
}

/** The picture's size in points, from its pixel size and an `@2x`/`@3x` in its name. */
export function pointsScale(imageName: string): number {
  const m = /@(\d+(?:\.\d+)?)x\.[^.]+$/i.exec(imageName);
  return m ? Number(m[1]) : 1;
}

/** The pictures an icon.json names, each once. */
export function imageNames(icon: IconJSON): string[] {
  const names = new Set<string>();
  for (const g of icon.groups ?? []) for (const l of (obj(g)?.layers as unknown[] | undefined) ?? []) {
    const n = obj(l)?.["image-name"];
    if (typeof n === "string" && n) names.add(n);
  }
  return [...names];
}

/** The design an icon.json describes. `pictures` gives each `image-name` as added to the program (one missing
 *  leaves its layer out, said in `missing`); `newId` makes the design's ids. */
export function docFromIcon(icon: IconJSON, opts: { name: string; program: string; pictures: Map<string, IconPicture>; newId: () => string }):
  { doc: Doc; missing: string[] } {
  const missing: string[] = [];
  const groups: Group[] = [];
  (icon.groups ?? []).forEach((gv, gi) => {
    const g = obj(gv);
    if (!g) return;
    const gp = positionOf(g);
    const layers: Layer[] = [];
    for (const lv of (g.layers as unknown[] | undefined) ?? []) {
      const l = obj(lv);
      const imageName = l?.["image-name"];
      if (!l || typeof imageName !== "string") continue;
      const pic = opts.pictures.get(imageName);
      if (!pic) { missing.push(imageName); continue; }
      const lp = positionOf(l);
      const scale = lp.scale * gp.scale;
      const widthPt = (pic.width / pointsScale(imageName)) * scale;
      const cx = gp.dx + lp.dx * gp.scale, cy = gp.dy + lp.dy * gp.scale;
      const hidden = plain(l, "hidden") === true;
      layers.push({
        id: opts.newId(),
        name: typeof l.name === "string" && l.name ? l.name : imageName.replace(/\.[^.]+$/, ""),
        ...(hidden ? { hidden } : {}),
        opacity: num(plain(l, "opacity")) ?? 1,
        content: { kind: "image", asset: pic.asset, cutout: false, smoothing: pic.pixelArt ? "pixel" : "smooth", effects: [] },
        transform: { x: 0.5 + cx / CANVAS, y: 0.5 + cy / CANVAS, width: widthPt / CANVAS, rotation: 0 },
        mask: null,
      });
    }
    if (!layers.length) return;
    const hidden = plain(g, "hidden") === true;
    groups.push({
      id: opts.newId(),
      name: typeof g.name === "string" && g.name ? g.name : `Group ${gi + 1}`,
      ...(hidden ? { hidden } : {}),
      glass: glassOf(g),
      layers,
    });
  });
  const doc: Doc = {
    schema: 1, id: opts.newId(), parent: null, name: opts.name, program: opts.program,
    fill: fillOf(icon), groups, created: new Date().toISOString(),
  };
  return { doc, missing };
}
