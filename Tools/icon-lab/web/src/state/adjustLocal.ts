// "Adjust all", applied in the page at once: each suggestion was made by the engine with some params (its
// `origin.params`); this moves its doc to new params the way the engine's treatments (Treatments.swift) would,
// near enough to show while the engine's own docs are on their way.
//   - colours: every colour in the doc that is the old primary or secondary (or one of the treatments' shades and
//     mixes of them) becomes the same shade or mix of the new ones; the background replaces the fill.
//   - subject size and move: subject layers scale about their bottom edge when they sit on it (else their centre)
//     and move by the change in dx/dy.
//   - logo size: logo layers scale about their centre.
//   - angle: the disc's turn and a linear fade's angle; pattern and letter where a treatment uses them.
import type { Doc, Layer, Media, Shape, Suggestion, SuggestionParams } from "../api";
import { hexToRgb, isHex, rgbToHex, type RGB } from "../lib/colour";
import { clone } from "../lib/doc";
import { contentAspect } from "../render/sketch";

// The engine's colour maths (Imaging/Colour.swift): shade in HLS, mix in RGB.
function hls([r, g, b]: RGB): [number, number, number] {
  const R = r / 255, G = g / 255, B = b / 255;
  const mx = Math.max(R, G, B), mn = Math.min(R, G, B), l = (mx + mn) / 2;
  if (mx === mn) return [0, l, 0];
  const d = mx - mn, s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn);
  const h = mx === R ? (G - B) / d + (G < B ? 6 : 0) : mx === G ? (B - R) / d + 2 : (R - G) / d + 4;
  return [h / 6, l, s];
}
function fromHls(h: number, l: number, s: number): RGB {
  const v = (m1: number, m2: number, hue: number) => {
    hue = ((hue % 1) + 1) % 1;
    if (hue < 1 / 6) return m1 + (m2 - m1) * hue * 6;
    if (hue < 0.5) return m2;
    if (hue < 2 / 3) return m1 + (m2 - m1) * (2 / 3 - hue) * 6;
    return m1;
  };
  if (s === 0) return [l * 255, l * 255, l * 255];
  const m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s, m1 = 2 * l - m2;
  return [v(m1, m2, h + 1 / 3) * 255, v(m1, m2, h) * 255, v(m1, m2, h - 1 / 3) * 255];
}
const shade = (c: RGB, f: number): RGB => { const [h, l, s] = hls(c); return fromHls(h, f < 1 ? l * f : l + (1 - l) * (f - 1), s); };
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] * (1 - t) + b[0] * t, a[1] * (1 - t) + b[1] * t, a[2] * (1 - t) + b[2] * t];
const close = (a: RGB, b: RGB) => Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2])) <= 3;

const SHADES = [0.2, 0.22, 0.25, 0.28, 0.3, 0.35, 0.4, 0.45, 0.6, 1.4, 1.45];
const MIXES = [0.25, 0.5, 0.75];

type Recipe = (p: RGB, s: RGB) => RGB;

/** How a colour was made from the primary and secondary, found by trying the treatments' recipes. */
function recipeFor(hex: string, p0: RGB | null, s0: RGB | null): Recipe | null {
  if (!isHex(hex)) return null;
  const c = hexToRgb(hex);
  const tries: Recipe[] = [(p) => p, (_p, s) => s];
  for (const f of SHADES) tries.push((p) => shade(p, f), (_p, s) => shade(s, f));
  for (const t of MIXES) tries.push((p, s) => mix(s, p, t));
  for (const r of tries) {
    try { if (p0 && s0 && close(r(p0, s0), c)) return r; } catch { /* a recipe needing a colour we haven't */ }
  }
  return null;
}

/** Applies `fn` to every colour in a doc (fill, effects, shapes, masks' shapes), in place. */
function eachColour(d: Doc, fn: (hex: string) => string) {
  d.fill.color = fn(d.fill.color);
  if (d.fill.dark) d.fill.dark = fn(d.fill.dark);
  const inShape = (s: Shape) => {
    const o = s as Record<string, unknown>;
    for (const k of ["color", "from", "to", "a", "b", "frame", "bar", "bezel"]) if (typeof o[k] === "string") o[k] = fn(o[k] as string);
    if (s.type === "bands") s.colors = s.colors.map(fn);
  };
  for (const g of d.groups) for (const l of g.layers) {
    if (l.content.kind === "shape") inShape(l.content.shape);
    else for (const e of l.content.effects) {
      const o = e as Record<string, unknown>;
      for (const k of ["color", "ink", "dark", "light"]) if (typeof o[k] === "string") o[k] = fn(o[k] as string);
    }
  }
}

const num = (v: number | undefined, d: number) => (typeof v === "number" ? v : d);

export function applyLocally(s: Suggestion, next: SuggestionParams, colours: Record<string, string>, media: Map<string, Media>): Suggestion {
  const p0 = s.doc.origin?.params ?? {};
  const d = clone(s.doc);
  // Colours
  const prim0 = p0.primary ?? colours.striking, sec0 = p0.secondary ?? colours.lightest;
  const prim1 = next.primary ?? colours.striking, sec1 = next.secondary ?? colours.lightest;
  if (prim0 && sec0 && isHex(prim0) && isHex(sec0) && prim1 && sec1 && isHex(prim1) && isHex(sec1) && (prim0 !== prim1 || sec0 !== sec1)) {
    const a0 = hexToRgb(prim0), b0 = hexToRgb(sec0), a1 = hexToRgb(prim1), b1 = hexToRgb(sec1);
    const memo = new Map<string, string>();
    eachColour(d, (hex) => {
      if (memo.has(hex)) return memo.get(hex)!;
      const r = recipeFor(hex, a0, b0);
      const out = r ? rgbToHex(r(a1, b1)) : hex;
      memo.set(hex, out);
      return out;
    });
  }
  if (next.background && isHex(next.background) && d.fill.kind !== "none" && s.treatment !== "risograph") { d.fill.color = next.background; delete d.fill.dark; }

  // Placement
  const ds = num(next.scale, 1) / num(p0.scale, 1);
  const ddx = num(next.dx, 0) - num(p0.dx, 0), ddy = num(next.dy, 0) - num(p0.dy, 0);
  const dl = num(next.logoScale, 1) / num(p0.logoScale, 1);
  const dAngle = num(next.angle, 45) - num(p0.angle, 45);
  for (const g of d.groups) for (const l of g.layers) {
    if (l.role === "subject" && (ds !== 1 || ddx || ddy)) scaleLayer(d, l, ds, ddx, ddy, media);
    else if (l.role === "logo" && dl !== 1) scaleLayer(d, l, dl, 0, 0, media, true);
    if (l.role === "disc" && dAngle) l.transform.rotation += dAngle;
    if (l.mask?.kind === "linear-fade" && dAngle) l.mask.angle += dAngle;
    if (l.content.kind === "shape" && l.content.shape.type === "pattern" && next.pattern && next.pattern !== "solid") l.content.shape.pattern = next.pattern as never;
    if (l.mask?.kind === "shape" && l.mask.shape.type === "text" && next.letter) l.mask.shape.text = next.letter.slice(0, 1).toUpperCase();
  }
  d.origin = { treatment: d.origin?.treatment ?? s.treatment, params: next };
  return { ...s, doc: d };
}

function scaleLayer(d: Doc, l: Layer, k: number, dx: number, dy: number, media: Map<string, Media>, centre = false) {
  const t = l.transform;
  const aspect = contentAspect(d.program, l, media) || 1;
  const h0 = t.width / aspect;
  const bottom = t.y + h0 / 2;
  t.width *= k;
  const h1 = t.width / aspect;
  if (!centre && bottom >= 0.98) t.y = bottom - h1 / 2;
  t.x += dx; t.y += dy;
}
