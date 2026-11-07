// The mock engine's treatments: lab.py's, rewritten as document generators. Each returns an editable Doc (or
// null when the program's media can't make it). The engine has the real ones; these exist to design against.
import type { Doc, Group, Layer, Media, Program, RoleKey, Shape, SuggestionParams, Treatment } from "../api";
import { mix, shade } from "../lib/colour";
import { NATURAL, uid } from "../lib/doc";

type Ctx = {
  program: Program
  p: Required<Pick<SuggestionParams, "scale" | "dx" | "dy" | "logoScale" | "dx2" | "dy2" | "angle" | "cell" | "offset">> & SuggestionParams
  primary: string; secondary: string; background?: string
  role(r: RoleKey): Media | undefined
}

type Gen = (c: Ctx) => { fill: Doc["fill"]; groups: Group[]; uses: (Media | undefined)[] } | null

const T: (Treatment & { gen: Gen })[] = [];
function treatment(key: string, title: string, uses: string[], about: string, gen: Gen) { T.push({ key, title, uses, about, gen }); }

const group = (name: string, layers: Layer[], glass: Partial<Group["glass"]> = {}): Group => ({
  id: uid(), name, layers, glass: { specular: true, shadow: 0.35, translucency: null, blur: null, ...glass },
});

function image(m: Media, opts: Partial<Layer> & { cutout?: boolean; effects?: any[]; smoothing?: "smooth" | "pixel"; crop?: any } = {}): Layer {
  const { cutout, effects, smoothing, crop, ...rest } = opts;
  return {
    id: uid(), name: rest.name ?? m.kind.replace("-", " "), opacity: 1,
    content: { kind: "image", asset: m.id, cutout: cutout ?? !!m.cutout, smoothing: smoothing ?? (m.analysis.pixelArt ? "pixel" : "smooth"), effects: effects ?? [], crop: crop ?? null },
    transform: { x: 0.5, y: 0.5, width: 1, rotation: 0 }, mask: null, ...rest,
  };
}
const shape = (name: string, s: Shape, extra: Partial<Layer> = {}): Layer => ({
  id: uid(), name, opacity: 1, content: { kind: "shape", shape: s }, transform: { ...NATURAL }, mask: null, ...extra,
});

/** Where a figure sits: big, bleeding off the bottom unless a flat side says otherwise. */
function figure(c: Ctx, m: Media, width = 0.82) {
  const box = m.analysis.subjectBox;
  const aspect = box ? (box[2] * m.width) / (box[3] * m.height) : m.width / m.height;
  const w = Math.min(width, width * aspect * 1.1) * c.p.scale;
  const h = w / aspect;
  const flatBottom = m.analysis.flatSides.includes("bottom");
  const y = flatBottom ? 1 - h / 2 : Math.min(0.56, 0.9 - h / 2);
  return { x: 0.5 + c.p.dx, y: y + c.p.dy, width: w, rotation: 0 };
}

function cover(c: Ctx, m: Media, zoom = 1) {
  const aspect = m.width / m.height;
  const w = (aspect >= 1 ? aspect : 1) * zoom * c.p.scale;
  return { x: 0.5 + c.p.dx2, y: 0.5 + c.p.dy2, width: w, rotation: 0 };
}

treatment("lifted", "Lifted subject", ["subject"], "The figure cut out in full colour on the primary.", (c) => {
  const s = c.role("subject"); if (!s) return null;
  return { fill: { kind: "gradient", color: c.primary }, groups: [group("Subject", [image(s, { name: "Subject", role: "subject", transform: figure(c, s) })], { shadow: 0.45 })], uses: [s] };
});

treatment("sticker", "Die-cut sticker", ["subject"], "The figure with a thick border in the secondary colour, on the primary.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  return { fill: { kind: "gradient", color: c.primary }, groups: [group("Sticker", [image(s, { name: "Subject, outlined", role: "subject", effects: [{ op: "outline", color: c.secondary, width: 0.035 }], transform: figure(c, s, 0.74) })], { shadow: 0.5 })], uses: [s] };
});

treatment("screenprint", "Screenprint", ["subject"], "The figure in three flat tones, each its own glass layer.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  const t = figure(c, s);
  const tones = [shade(c.primary, 0.28), c.primary, c.secondary];
  const layer = (lv: 0 | 1 | 2) => image(s, { name: `Tone ${lv + 1}`, role: "subject", effects: [{ op: "tone", level: lv, color: tones[lv] }], transform: { ...t } });
  return { fill: { kind: "gradient", color: shade(c.primary, 1.45) }, groups: [group("Light tone", [layer(2)], { shadow: 0.15 }), group("Mid tone", [layer(1)], { shadow: 0.15 }), group("Dark tone", [layer(0)], { shadow: 0.35 })], uses: [s] };
});

treatment("double-exposure", "Double exposure", ["subject", "fill"], "The subject's outline, filled with the fill image.", (c) => {
  const s = c.role("subject"), f = c.role("fill"); if (!s?.cutout || !f) return null;
  const t = figure(c, s, 0.9);
  const l = image(f, { name: "Fill art", role: "backdrop", cutout: false, effects: [{ op: "autocontrast" }], transform: cover(c, f, 1.25) });
  l.mask = { kind: "image", asset: s.id, cutout: true, transform: t };
  return { fill: { kind: "gradient", color: c.secondary }, groups: [group("Exposure", [l], { shadow: 0.25 })], uses: [s, f] };
});

treatment("disc", "Disc", ["disc", "subject"], "A CD: the disc's own label cut to its circle, with rims.", (c) => {
  const d = c.role("disc"); if (!d) return null;
  const circ = d.analysis.circle;
  let crop: [number, number, number, number] | null = null;
  if (circ) {
    const m = Math.min(d.width, d.height), r = circ[2] * m;
    crop = [(circ[0] * d.width - r) / d.width, (circ[1] * d.height - r) / d.height, (2 * r) / d.width, (2 * r) / d.height];
  }
  const disc = image(d, { name: "Disc", role: "disc", cutout: false, crop, transform: { x: 0.5, y: 0.5, width: 0.86 * c.p.scale, rotation: -c.p.angle + 45 } });
  disc.mask = { kind: "ring", outer: 0.43 * c.p.scale, inner: 0.068 };
  return {
    fill: { kind: "gradient", color: c.primary },
    groups: [group("Rims", [shape("Rims", { type: "disc-rims", color: "#ffffff" }, { role: "decoration" })], { shadow: 0, translucency: 0.4 }), group("Disc", [disc], { shadow: 0.45 })],
    uses: [d],
  };
});

treatment("diagonal-fade", "Diagonal fade", ["subject"], "The subject's picture fading into the primary towards a corner, the figure kept crisp.", (c) => {
  const s = c.role("subject"); if (!s) return null;
  const back = image(s, { name: "Picture", role: "backdrop", cutout: false, transform: { x: 0.6 + c.p.dx, y: 0.62 + c.p.dy, width: 1.3 * c.p.scale, rotation: 0 } });
  back.mask = { kind: "linear-fade", angle: c.p.angle + 180, start: 0.3, end: 0.72 };
  const groups = [group("Picture", [back], { specular: false, shadow: 0 })];
  if (s.cutout) groups.unshift(group("Subject", [image(s, { name: "Subject", role: "subject", transform: figure(c, s, 0.7) })], { shadow: 0.2 }));
  if (c.p.pattern && c.p.pattern !== "solid") groups.push(group("Pattern", [shape("Pattern", { type: "pattern", pattern: c.p.pattern as any, a: c.primary, b: c.secondary }, { role: "pattern" })], { specular: false, shadow: 0 }));
  return { fill: { kind: "solid", color: c.primary }, groups, uses: [s] };
});

treatment("duotone", "Duotone with figure", ["fill", "subject"], "The fill art gradient-mapped to two colours, the figure in front.", (c) => {
  const f = c.role("fill"), s = c.role("subject"); if (!f || !s?.cutout) return null;
  return {
    fill: { kind: "gradient", color: c.primary },
    groups: [
      group("Figure", [image(s, { name: "Subject", role: "subject", transform: figure(c, s, 0.88) })], { shadow: 0.45 }),
      group("Back", [image(f, { name: "Fill art", role: "backdrop", cutout: false, effects: [{ op: "blur", radius: 0.002 }, { op: "gradient-map", dark: shade(c.primary, 0.35), light: c.secondary }], transform: cover(c, f) })], { specular: false, shadow: 0 }),
    ],
    uses: [f, s],
  };
});

treatment("halftone", "Halftone", ["subject"], "The figure as halftone dots of the primary on the secondary.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  return { fill: { kind: "gradient", color: c.secondary }, groups: [group("Dots", [image(s, { name: "Halftone", role: "subject", effects: [{ op: "halftone", ink: c.primary, cell: c.p.cell / 1024, angle: 45 }], transform: figure(c, s) })], { shadow: 0.25 })], uses: [s] };
});

treatment("line-art", "Line art", ["subject"], "The figure's edges traced as a glowing line on a deep primary.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  return { fill: { kind: "gradient", color: shade(c.primary, 0.3) }, groups: [group("Lines", [image(s, { name: "Edges", role: "subject", effects: [{ op: "edges", color: c.secondary }], transform: figure(c, s) })], { shadow: 0.2 })], uses: [s] };
});

treatment("bands", "Palette bands", ["subject"], "Stripes from secondary to primary, the figure's silhouette in front.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  const colors = [0, 1, 2, 3, 4].map((i) => mix(c.secondary, c.primary, i / 4));
  return {
    fill: { kind: "solid", color: c.primary },
    groups: [
      group("Figure", [image(s, { name: "Silhouette", role: "subject", effects: [{ op: "silhouette", color: shade(c.primary, 0.25) }], transform: figure(c, s) })], { shadow: 0.4 }),
      group("Bands", [shape("Bands", { type: "bands", colors }, { role: "pattern" })], { specular: false, shadow: 0 }),
    ],
    uses: [s],
  };
});

treatment("window", "Old window", ["fill"], "The art inside a retro window: says old software.", (c) => {
  const f = c.role("fill") ?? c.role("subject"); if (!f) return null;
  const art = image(f, { name: "Art", role: "backdrop", cutout: false, transform: { x: 0.5 + c.p.dx2, y: 0.52 + c.p.dy2, width: 0.82 * Math.max(1, f.width / f.height * 0.9) * c.p.scale, rotation: 0 } });
  art.mask = { kind: "shape", shape: { type: "solid", color: "#ffffff" }, transform: { x: 0.5, y: 0.513, width: 0.766, rotation: 0 } };
  return {
    fill: { kind: "gradient", color: shade(c.primary, 1.4) },
    groups: [group("Window", [shape("Window frame", { type: "window", frame: c.secondary, bar: c.primary }, { role: "frame" })], { shadow: 0.5 }), group("Art", [art], { specular: false, shadow: 0 })],
    uses: [f],
  };
});

treatment("logo-plate", "Logo plate", ["logo", "subject"], "The logo on a glass plate over the subject's art.", (c) => {
  const l = c.role("logo"), s = c.role("subject"); if (!l) return null;
  const groups = [group("Logo", [image(l, { name: "Logo", role: "logo", cutout: !!l.cutout, transform: { x: 0.5 + c.p.dx, y: 0.5 + c.p.dy, width: 0.86 * c.p.logoScale, rotation: 0 } })], { shadow: 0.5 })];
  if (s) groups.push(group("Back", [image(s, { name: "Art", role: "backdrop", cutout: false, effects: [{ op: "blur", radius: 0.01 }, { op: "gradient-map", dark: shade(c.primary, 0.4), light: c.primary }], transform: cover(c, s) })], { specular: false, shadow: 0 }));
  return { fill: { kind: "gradient", color: c.primary }, groups, uses: [l, s] };
});

treatment("exe-icon", "Program's own icon", ["icon"], "The program's own icon, pixels kept hard, on a glass tile.", (c) => {
  const i = c.role("icon"); if (!i) return null;
  return { fill: { kind: "gradient", color: c.primary }, groups: [group("Icon", [image(i, { name: "Program icon", role: "icon", cutout: false, smoothing: "pixel", transform: { x: 0.5 + c.p.dx, y: 0.5 + c.p.dy, width: 0.62 * c.p.scale, rotation: 0 } })], { shadow: 0.45 })], uses: [i] };
});

treatment("risograph", "Risograph", ["subject"], "Two spot inks printed slightly out of register, with grain.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  const t = figure(c, s), o = c.p.offset / 1024;
  return {
    fill: { kind: "gradient", color: c.background ?? "#f5f0e4" },
    groups: [
      group("Ink 2", [image(s, { name: "Mid ink", role: "subject", effects: [{ op: "riso", ink: c.secondary, band: "mid", offset: [o + c.p.dx2, -o + c.p.dy2] }], transform: { ...t } })], { shadow: 0.1 }),
      group("Ink 1", [image(s, { name: "Dark ink", role: "subject", effects: [{ op: "riso", ink: c.primary, band: "dark", offset: [0, 0] }], transform: { ...t } })], { shadow: 0.15 }),
    ],
    uses: [s],
  };
});

treatment("enamel-pin", "Enamel pin", ["subject"], "The figure as a pin: flat enamel fills and a gold rim.", (c) => {
  const s = c.role("subject"); if (!s?.cutout) return null;
  return { fill: { kind: "gradient", color: c.primary }, groups: [group("Pin", [image(s, { name: "Enamel", role: "subject", effects: [{ op: "posterize", colors: 5 }, { op: "outline", color: "#d6ac4c", width: 0.015 }], transform: figure(c, s, 0.78) })], { shadow: 0.5 })], uses: [s] };
});

treatment("monogram", "Monogram", ["fill"], "The title's first letter, huge, filled with the art.", (c) => {
  const f = c.role("fill") ?? c.role("subject"); if (!f) return null;
  const letter = (c.p.letter || c.program.title.replace(/^(the|a)\s+/i, "")[0] || "A").toUpperCase().slice(0, 2);
  const art = image(f, { name: "Art", role: "backdrop", cutout: false, transform: cover(c, f) });
  art.mask = { kind: "shape", shape: { type: "text", text: letter, font: "Arial Black", color: "#ffffff" }, transform: { x: 0.5 + c.p.dx, y: 0.5 + c.p.dy, width: c.p.scale, rotation: 0 } };
  return { fill: { kind: "gradient", color: c.primary }, groups: [group("Letter", [art], { shadow: 0.45 })], uses: [f] };
});

treatment("crt", "CRT", ["fill"], "The art on a CRT in a bezel of the primary, with scanlines.", (c) => {
  const f = c.role("fill") ?? c.role("subject"); if (!f) return null;
  const art = image(f, { name: "Screen", role: "backdrop", cutout: false, effects: [{ op: "scanlines" }], transform: { x: 0.5 + c.p.dx2, y: 0.46 + c.p.dy2, width: 0.8 * Math.max(1, f.width / f.height * 0.8) * c.p.scale, rotation: 0 } });
  art.mask = { kind: "shape", shape: { type: "solid", color: "#ffffff" }, transform: { x: 0.5, y: 0.464, width: 0.72, rotation: 0 } };
  return {
    fill: { kind: "gradient", color: shade(c.primary, 0.6) },
    groups: [group("Bezel", [shape("CRT bezel", { type: "crt", bezel: c.primary }, { role: "frame" })], { shadow: 0.45 }), group("Screen", [art], { specular: false, shadow: 0 })],
    uses: [f],
  };
});

export const TREATMENTS: Treatment[] = T.map(({ gen: _g, ...t }) => t);

export function generate(program: Program, params: SuggestionParams, only?: string[]): { treatment: string; title: string; about: string; uses: string[]; doc: Doc }[] {
  const col = program.colours;
  const media = new Map(program.media.map((m) => [m.id, m]));
  const roles = { ...program.roles, ...(params.roles ?? {}) };
  const ctx: Ctx = {
    program,
    p: { scale: 1, dx: 0, dy: 0, logoScale: 1, dx2: 0, dy2: 0, angle: 45, cell: 26, offset: 14, ...params } as Ctx["p"],
    primary: params.primary || col.striking || "#4a6fd0",
    secondary: params.secondary || col["second striking"] || "#f6c445",
    background: params.background || undefined,
    role: (r) => (roles[r] ? media.get(roles[r]!) : undefined),
  };
  const out = [];
  for (const t of T) {
    if (only && only.length && !only.includes(t.key)) continue;
    const r = t.gen(ctx);
    if (!r) continue;
    if (ctx.background && t.key !== "risograph") r.fill = { ...r.fill, color: ctx.background };
    const doc: Doc = {
      schema: 1, id: uid(), parent: null, name: t.title, program: program.slug,
      origin: { treatment: t.key, params }, fill: r.fill, groups: r.groups.slice(0, 4), created: new Date().toISOString(),
    };
    out.push({ treatment: t.key, title: t.title, about: t.about, uses: [...new Set(r.uses.filter(Boolean).map((m) => m!.id))], doc });
  }
  return out;
}
