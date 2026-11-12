// Parts (docs/api.md, "Parts" and "Upscaling") until the engine answers those routes, and under ?mock: a
// picture's parts made from what the engine already knows (its cut-out, title box, box corners, disc), the
// person's changes kept in this browser (localStorage), cut-out candidates made in the browser from the subject
// mask and a drawn region, and part pictures cropped and turned on a canvas. Each function is only used when the
// engine's route is missing; once it answers, the engine's parts win.
import type { Candidate, Content, Edges, Media, MediaKind, Part, Prompt, Rotation } from "../api";
import { uid } from "../lib/doc";
import { loadImage } from "../render/resources";
import { applyEffect, toBlobUrl } from "../mock/raster";

// ---------------------------------------------------------------- what the person changed, kept locally

type Overlay = { rotation?: Rotation; kind?: MediaKind | "unknown"; parts?: Record<string, Partial<Part>>; added?: Part[]; removed?: string[] };
const KEY = (slug: string) => "iconlab-parts:" + slug;

function readAll(slug: string): Record<string, Overlay> {
  try { return JSON.parse(localStorage.getItem(KEY(slug)) ?? "{}"); } catch { return {}; }
}
export function overlayOf(slug: string, id: string): Overlay { return readAll(slug)[id] ?? {}; }
export function changeOverlay(slug: string, id: string, fn: (o: Overlay) => void) {
  const all = readAll(slug);
  const o = all[id] ?? {};
  fn(o);
  all[id] = o;
  try { localStorage.setItem(KEY(slug), JSON.stringify(all)); } catch { /* full: changes last this session only */ }
}

// ---------------------------------------------------------------- parts from what the engine knows

const bboxOf = (pts: number[][]): [number, number, number, number] => {
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const x0 = Math.max(0, Math.min(...xs)), y0 = Math.max(0, Math.min(...ys));
  return [x0, y0, Math.min(1, Math.max(...xs)) - x0, Math.min(1, Math.max(...ys)) - y0];
};

function turnedSize(w: number, h: number, r: Rotation): [number, number] {
  return r === 90 || r === 270 ? [Math.round(h), Math.round(w)] : [Math.round(w), Math.round(h)];
}

/** The parts the engine would give, from fields it sends today. Images left "" are cropped by the page. */
function synthParts(m: Media): Part[] {
  // (A media already given local parts is re-made from its own fields, not its old parts.)
  const W = m.width, H = m.height;
  const parts: Part[] = [{
    id: "whole", name: "Whole picture", source: "whole", kind: m.kind, box: [0, 0, 1, 1], hasMask: false, rotation: 0,
    picked: m.picked, size: [W, H], image: m.url, thumb: m.thumb,
  }];
  const a = m.analysis, d = m.deep;
  if (m.cutout && a.subject) {
    const box = a.subjectBox ?? [0, 0, 1, 1];
    const [cw, ch] = m.cutoutSize ?? [box[2] * W, box[3] * H];
    if (box[2] * box[3] < 0.97) parts.push({ id: "subject", name: "Subject cut-out", source: "subject", kind: "unknown", box, hasMask: true, rotation: 0, picked: false, size: [Math.round(cw), Math.round(ch)], image: m.cutout, thumb: m.cutout, mask: m.mask, flatSides: a.flatSides });
  }
  if (d?.titleBox) {
    const b = d.titleBox;
    parts.push({ id: "title", name: "Title", source: "text", kind: "logo", box: b, hasMask: false, rotation: 0, picked: false, size: [Math.round(b[2] * W), Math.round(b[3] * H)], image: "", thumb: "" });
  }
  if (d?.rectangle && d.rectangle.length === 4) {
    const b = bboxOf(d.rectangle);
    if (b[2] * b[3] < 0.9) parts.push({ id: "rect", name: "Straightened box", source: "rectangle", kind: "unknown", box: b, quad: d.rectangle, hasMask: false, rotation: 0, picked: false, size: [Math.round(b[2] * W), Math.round(b[3] * H)], image: "", thumb: "" });
  }
  if (a.circle) {
    const [cx, cy, r] = a.circle, m0 = Math.min(W, H);
    const b: [number, number, number, number] = [Math.max(0, (cx * W - r * m0) / W), Math.max(0, (cy * H - r * m0) / H), (2 * r * m0) / W, (2 * r * m0) / H];
    parts.push({ id: "disc", name: "Disc", source: "disc", kind: "disc", box: b, hasMask: false, rotation: 0, picked: false, size: [Math.round(2 * r * m0), Math.round(2 * r * m0)], image: "", thumb: "" });
  }
  return parts;
}

/** The media with `parts` (and rotation), from the engine's when it sends them, else made here. */
export function withParts(slug: string, m: Media): Media {
  if (m.parts?.length && !m.partsLocal) {
    // The engine's parts, with anything it left out filled in (a part without `size` was seen).
    const parts = m.parts.map((p) => ({
      ...p, rotation: p.rotation ?? 0, box: p.box ?? [0, 0, 1, 1],
      size: p.size ?? turnedSize((p.box?.[2] ?? 1) * m.width, (p.box?.[3] ?? 1) * m.height, (((m.rotation ?? 0) + (p.rotation ?? 0)) % 360) as Rotation),
    }));
    return { ...m, rotation: m.rotation ?? 0, parts };
  }
  const o = overlayOf(slug, m.id);
  let parts = synthParts(m).filter((p) => !(o.removed ?? []).includes(p.id));
  parts = [...parts, ...(o.added ?? [])].map((p) => ({ ...p, ...(o.parts?.[p.id] ?? {}) }));
  // The whole picture's pick follows the engine's until the person has picked parts here.
  if (!o.parts || !Object.values(o.parts).some((x) => x.picked != null)) parts = parts.map((p) => (p.id === "whole" ? { ...p, picked: m.picked } : p));
  const rotation = o.rotation ?? m.rotation ?? 0;
  parts = parts.map((p) => ({ ...p, size: p.id === "whole" ? turnedSize(m.width, m.height, ((rotation + p.rotation) % 360) as Rotation) : p.size }));
  return { ...m, kind: o.kind ?? m.kind, kindSource: o.kind ? "you" : m.kindSource, rotation, parts, picked: parts.some((p) => p.picked), partsLocal: true };
}

// ---------------------------------------------------------------- part pictures, cut and turned

const canvasCache = new Map<string, Promise<HTMLCanvasElement>>();

function cv(w: number, h: number) { const c = document.createElement("canvas"); c.width = Math.max(1, Math.round(w)); c.height = Math.max(1, Math.round(h)); return c; }

/** A part as a picture: its image when it has one (a cut-out), else a crop of the picture; turned by the
 *  picture's and the part's rotation. At most `max` pixels on its long side. */
export function partCanvas(m: Media, p: Part, max = 1024): Promise<HTMLCanvasElement> {
  const turn = (((m.rotation ?? 0) + p.rotation) % 360) as Rotation;
  const key = [m.id, p.id, p.image, p.box.join(","), turn, max].join("|");
  let c = canvasCache.get(key);
  if (!c) {
    c = (async () => {
      let src: CanvasImageSource, sw: number, sh: number, sx = 0, sy = 0;
      if (p.image && p.source !== "whole") {
        const img = await loadImage(p.image); src = img; sw = img.naturalWidth; sh = img.naturalHeight;
      } else {
        const img = await loadImage(m.url); src = img;
        sx = p.box[0] * img.naturalWidth; sy = p.box[1] * img.naturalHeight; sw = p.box[2] * img.naturalWidth; sh = p.box[3] * img.naturalHeight;
      }
      const k = Math.min(1, max / Math.max(sw, sh));
      const w = sw * k, h = sh * k;
      const side = turn === 90 || turn === 270;
      const out = cv(side ? h : w, side ? w : h);
      const g = out.getContext("2d")!;
      g.imageSmoothingQuality = "high";
      g.translate(out.width / 2, out.height / 2);
      g.rotate((turn * Math.PI) / 180);
      g.drawImage(src, sx, sy, sw, sh, -w / 2, -h / 2, w, h);
      return out;
    })();
    c.catch(() => canvasCache.delete(key));
    canvasCache.set(key, c);
  }
  return c;
}

const urlCache = new Map<string, Promise<string>>();
/** A URL for a part's picture. The engine's parts are already cut and turned; parts made here are cropped and
 *  turned on a canvas (a cut-out that needs no turning uses its image as it is). */
export function partUrl(m: Media, p: Part, max = 512): Promise<string> {
  if (!m.partsLocal) return Promise.resolve(max <= 256 && p.thumb ? p.thumb : p.image || p.thumb);
  const turn = ((m.rotation ?? 0) + p.rotation) % 360;
  if (p.image && turn === 0) return Promise.resolve(p.source === "whole" && max <= 256 ? m.thumb : p.image);
  const key = [m.id, p.id, p.image, p.box.join(","), turn, max].join("|");
  let u = urlCache.get(key);
  if (!u) { u = partCanvas(m, p, max).then(toBlobUrl); urlCache.set(key, u); }
  return u;
}

// ---------------------------------------------------------------- cut-out candidates (Vision-like, in the browser)

type Cand = Candidate & { maskCanvas: HTMLCanvasElement; mediaId: string }
const cands = new Map<string, Cand>();

async function subjectMask(m: Media): Promise<HTMLCanvasElement | null> {
  if (!m.mask) return null;
  try {
    const img = await loadImage(m.mask);
    const c = cv(m.width, m.height);
    const g = c.getContext("2d", { willReadFrequently: true })!;
    g.drawImage(img, 0, 0, c.width, c.height);
    const d = g.getImageData(0, 0, c.width, c.height);
    for (let i = 0; i < d.data.length; i += 4) { const v = d.data[i]; d.data[i] = d.data[i + 1] = d.data[i + 2] = 255; d.data[i + 3] = v; }
    g.putImageData(d, 0, 0);
    return c;
  } catch { return null; }
}

function maskBox(mask: HTMLCanvasElement): { box: [number, number, number, number]; area: number } | null {
  const g = mask.getContext("2d", { willReadFrequently: true })!;
  const { data, width: w, height: h } = g.getImageData(0, 0, mask.width, mask.height);
  let x0 = w, y0 = h, x1 = -1, y1 = -1, n = 0;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > 127) { n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  if (x1 < 0) return null;
  return { box: [x0 / w, y0 / h, (x1 - x0 + 1) / w, (y1 - y0 + 1) / h], area: n / (w * h) };
}

async function cutWith(m: Media, mask: HTMLCanvasElement, box: [number, number, number, number]): Promise<string> {
  const img = await loadImage(m.url);
  const W = img.naturalWidth, H = img.naturalHeight;
  const c = cv(box[2] * W, box[3] * H);
  const g = c.getContext("2d")!;
  g.drawImage(img, box[0] * W, box[1] * H, box[2] * W, box[3] * H, 0, 0, c.width, c.height);
  g.globalCompositeOperation = "destination-in";
  g.drawImage(mask, box[0] * mask.width, box[1] * mask.height, box[2] * mask.width, box[3] * mask.height, 0, 0, c.width, c.height);
  return toBlobUrl(c);
}

async function addCand(m: Media, mask: HTMLCanvasElement, score: number): Promise<Cand | null> {
  const b = maskBox(mask);
  if (!b) return null;
  const c: Cand = { id: "local-" + uid().slice(0, 8), mediaId: m.id, maskCanvas: mask, score, box: b.box, area: b.area, url: await cutWith(m, mask, b.box), mask: await toBlobUrl(mask) };
  cands.set(c.id, c);
  return c;
}

/** Candidates for a prompt, small → whole: the subject inside the region, the region itself, the whole subject.
 *  (Clicks need SAM, in the engine: here a + click only chooses which candidate is shown first.) */
export async function localCandidates(m: Media, prompt: { region?: Prompt["region"]; points?: Prompt["points"] }): Promise<Candidate[]> {
  const subject = await subjectMask(m);
  const W = m.width, H = m.height;
  const region = prompt.region;
  const out: Cand[] = [];
  const regionMask = (r: [number, number, number, number]) => { const c = cv(W, H); const g = c.getContext("2d")!; g.fillStyle = "#fff"; g.fillRect(r[0] * W, r[1] * H, r[2] * W, r[3] * H); return c; };
  if (region && subject) {
    const c = regionMask(region);
    const g = c.getContext("2d")!;
    g.globalCompositeOperation = "destination-in"; g.drawImage(subject, 0, 0);
    const x = await addCand(m, c, 0.9); if (x) out.push(x);
  }
  if (region) { const x = await addCand(m, regionMask(region), 0.6); if (x) out.push(x); }
  if (subject) { const x = await addCand(m, subject, 0.7); if (x) out.push(x); }
  if (!out.length) { const x = await addCand(m, regionMask([0, 0, 1, 1]), 0.3); if (x) out.push(x); }
  // Negative points: drop candidates that contain them.
  const neg = (prompt.points ?? []).filter((p) => !p.positive);
  const kept = out.filter((c) => !neg.some((p) => alphaAtCanvas(c.maskCanvas, p.x, p.y) > 127));
  return (kept.length ? kept : out).sort((a, b) => a.area - b.area).map(({ maskCanvas: _m, mediaId: _i, ...c }) => c);
}

function alphaAtCanvas(c: HTMLCanvasElement, u: number, v: number) {
  const g = c.getContext("2d", { willReadFrequently: true })!;
  return g.getImageData(Math.min(c.width - 1, Math.floor(u * c.width)), Math.min(c.height - 1, Math.floor(v * c.height)), 1, 1).data[3];
}

/** A candidate's mask with grow/shrink, soften and fill holes applied. */
function withEdges(mask: HTMLCanvasElement, e: Edges): HTMLCanvasElement {
  let c = mask;
  if (e.grow) {
    const r = Math.abs(e.grow);
    const b = cv(c.width, c.height), g = b.getContext("2d", { willReadFrequently: true })!;
    g.filter = `blur(${r / 2}px)`; g.drawImage(c, 0, 0);
    const d = g.getImageData(0, 0, b.width, b.height);
    const t = e.grow > 0 ? 20 : 235;
    for (let i = 3; i < d.data.length; i += 4) d.data[i] = d.data[i] > t ? 255 : 0;
    g.putImageData(d, 0, 0);
    c = b;
  }
  if (e.fillHoles) {
    // Close small gaps: a blur and a high threshold, then keep the union with the mask.
    const b = cv(c.width, c.height), g = b.getContext("2d", { willReadFrequently: true })!;
    g.filter = "blur(3px)"; g.drawImage(c, 0, 0); g.filter = "none";
    const d = g.getImageData(0, 0, b.width, b.height);
    for (let i = 3; i < d.data.length; i += 4) d.data[i] = d.data[i] > 160 ? 255 : 0;
    g.putImageData(d, 0, 0); g.drawImage(c, 0, 0);
    c = b;
  }
  if (e.soften) {
    const b = cv(c.width, c.height), g = b.getContext("2d")!;
    g.filter = `blur(${e.soften}px)`; g.drawImage(c, 0, 0);
    c = b;
  }
  return c;
}

export async function localPreview(m: Media, candId: string, edges: Edges): Promise<{ url: string; box: [number, number, number, number] }> {
  const c = cands.get(candId);
  if (!c) throw new Error("That choice has gone: make it again.");
  const mask = withEdges(c.maskCanvas, edges);
  const b = maskBox(mask) ?? { box: c.box };
  return { url: await cutWith(m, mask, b.box), box: b.box };
}

async function toDataUrl(url: string, max = 512): Promise<{ url: string; w: number; h: number }> {
  const img = await loadImage(url);
  const k = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
  const c = cv(img.naturalWidth * k, img.naturalHeight * k);
  c.getContext("2d")!.drawImage(img, 0, 0, c.width, c.height);
  return { url: c.toDataURL("image/png"), w: img.naturalWidth, h: img.naturalHeight };
}

/** Saves a candidate as a part (new, or replacing `partId`), kept in this browser. */
export async function localSavePart(slug: string, m: Media, candId: string, opts: { partId?: string; name?: string; kind?: string; edges?: Edges; prompt?: Prompt }) {
  const c = cands.get(candId);
  if (!c) throw new Error("That choice has gone: make it again.");
  const edges = opts.edges ?? { grow: 0, soften: 0, fillHoles: false };
  const mask = withEdges(c.maskCanvas, edges);
  const b = maskBox(mask) ?? { box: c.box };
  const cut = await toDataUrl(await cutWith(m, mask, b.box), 512);
  const id = opts.partId ?? "p-" + uid().slice(0, 6);
  const prev = m.parts?.find((p) => p.id === id);
  const part: Part = {
    id, name: opts.name ?? prev?.name ?? (opts.prompt?.region ? "Region cut-out" : "Cut-out"), source: opts.prompt?.points?.length ? "sam" : "region",
    kind: (opts.kind as MediaKind) ?? prev?.kind ?? "unknown", box: b.box, hasMask: true, rotation: prev?.rotation ?? 0, picked: prev?.picked ?? true,
    size: [Math.round(b.box[2] * m.width), Math.round(b.box[3] * m.height)], edges, prompt: opts.prompt,
    image: cut.url, thumb: cut.url,
  };
  changeOverlay(slug, m.id, (o) => {
    const isAdded = (o.added ?? []).some((p) => p.id === id);
    if (isAdded || !prev) o.added = [...(o.added ?? []).filter((p) => p.id !== id), part];
    else o.parts = { ...(o.parts ?? {}), [id]: { ...(o.parts?.[id] ?? {}), image: part.image, thumb: part.thumb, box: part.box, size: part.size, edges, prompt: opts.prompt, hasMask: true } };
  });
}

// ---------------------------------------------------------------- parts as layer content, and upscaling

export function isPartAsset(asset: string) { return asset.includes("/") || /@(x4|px4)$/.test(asset); }

export function parseAsset(asset: string) {
  const m = asset.match(/^(.*?)(?:@(x4|px4))?$/)!;
  const [media, part] = m[1].split("/");
  return { media, part: part ?? null, up: (m[2] as "x4" | "px4" | undefined) ?? null };
}

/** A part asset ("<media>/<part>[@x4|@px4]") drawn in the browser, effects applied, for the sketch. */
export async function renderPartContent(content: Content, pixelWidth: number, media: Map<string, Media>, canvasWidth = 1, slug = "") {
  if (content.kind !== "image") throw new Error("not an image");
  const { media: mid, part: pid, up } = parseAsset(content.asset);
  const m0 = media.get(mid);
  if (!m0) throw new Error("no such media: " + mid);
  const m = withParts(slug, m0);
  const p = (m.parts ?? []).find((x) => x.id === (pid ?? "whole")) ?? m.parts![0];
  let c = await partCanvas(m, p, 2048);
  if (up) {
    const s = cv(c.width * 4, c.height * 4), g = s.getContext("2d")!;
    g.imageSmoothingEnabled = up === "x4"; g.imageSmoothingQuality = "high";
    g.drawImage(c, 0, 0, s.width, s.height);
    c = s;
  }
  const pw = Math.min(2048, Math.max(8, Math.round(pixelWidth)));
  const out = cv(pw, (pw * c.height) / c.width);
  const g = out.getContext("2d")!;
  g.imageSmoothingEnabled = content.smoothing !== "pixel"; g.imageSmoothingQuality = "high";
  g.drawImage(c, 0, 0, out.width, out.height);
  let r = out;
  const unit = pw / Math.max(0.05, canvasWidth);
  const w0 = r.width, h0 = r.height;
  for (const e of content.effects) if (!e.off) r = applyEffect(r, e, unit);
  const px = (r.width - w0) / 2 / w0, py = (r.height - h0) / 2 / h0;
  return { url: await toBlobUrl(r), width: r.width, height: r.height, box: [-px, -py, 1 + px, 1 + py] as [number, number, number, number] };
}

/** The pixel size of an asset, for "enlarged past its pixels". */
export function localAssetInfo(asset: string, media: Map<string, Media>, slug = "") {
  const { media: mid, part: pid, up } = parseAsset(asset);
  const m0 = media.get(mid);
  if (!m0) throw new Error("no such media: " + mid);
  const m = withParts(slug, m0);
  const p = (m.parts ?? []).find((x) => x.id === (pid ?? "whole"));
  const [w, h] = p ? p.size : [m.width, m.height];
  const k = up ? 4 : 1;
  return { width: w * k, height: h * k, pixelArt: !!m.analysis.pixelArt || Math.max(w, h) <= 96 };
}

export async function localUpscale(asset: string, mode: "photo" | "pixel", media: Map<string, Media>, slug = "") {
  const base = asset.replace(/@(x4|px4)$/, "");
  const next = base + (mode === "pixel" ? "@px4" : "@x4");
  const info = localAssetInfo(next, media, slug);
  const r = await renderPartContent({ kind: "image", asset: next, cutout: false, smoothing: mode === "pixel" ? "pixel" : "smooth", effects: [] }, Math.min(2048, info.width), media, 1, slug);
  return { asset: next, url: r.url, width: info.width, height: info.height };
}
