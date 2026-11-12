// An in-browser stand-in for the engine (docs/api.md), built on the old prototype's games/ folders (served by
// the dev server's mock plugin). Renders are canvases turned into blob URLs; "icon renders" composite the
// sketch. State (docs, pins, picks) lives in localStorage so a reload keeps it.
import { ApiError, type Doc, type DocsState, type EngineEvent, type Job, type Media, type Program, type ProgramSummary, type Transport } from "../api";
import { drawSketch, sketchRequests } from "../render/sketch";
import { resources } from "../render/resources";
import { namedColours, renderContent, renderMask, renderShape, toBlobUrl } from "./raster";
import { generate, TREATMENTS } from "./treatments";

type Saved = {
  docs: Record<string, Doc>; pins: string[]; current: string | null; picked: Record<string, boolean>
  extra?: Record<string, Partial<Media>> // per-media changes (hires, deep, kind)
  added?: Media[]                        // images found in "your files"
};

let fixtures: Promise<Program[]> | null = null;
function loadFixtures(): Promise<Program[]> {
  fixtures ??= fetch("/mock-files/fixtures.json").then((r) => {
    if (!r.ok) throw new Error("The mock needs the dev server (npm run dev): /mock-files is missing.");
    return r.json();
  }).then((j) => j.programs as Program[]);
  return fixtures;
}

const colourCache = new Map<string, Promise<Record<string, string>>>();

function store(slug: string): Saved {
  try {
    const raw = localStorage.getItem("iconlab-mock:" + slug);
    if (raw) return JSON.parse(raw);
  } catch { /* storage unavailable */ }
  return { docs: {}, pins: [], current: null, picked: {} };
}
function persist(slug: string, s: Saved) {
  try { localStorage.setItem("iconlab-mock:" + slug, JSON.stringify(s)); } catch { /* full or unavailable */ }
}

/** Programs made from search results that aren't among the fixtures: no media until "your files" adds some. */
function extraPrograms(): { slug: string; title: string; year?: number }[] {
  try { return JSON.parse(localStorage.getItem("iconlab-mock:programs") ?? "[]"); } catch { return []; }
}

/** What the fixtures don't have: online images get `remote`, and the same art twice is folded as a duplicate. */
function dress(media: Media[]): Media[] {
  const out = media.map((m) => m.source === "Your files" || m.remote ? m : {
    ...m, remote: { source: m.source === "Wikipedia" ? "wikipedia" : "archive", url: m.url, thumbUrl: m.thumb, kind: m.kind, sourceLabel: m.kind === "box-front" ? "Box - Front" : m.kind === "disc" ? "Disc" : undefined, width: m.width, height: m.height, pageUrl: m.sourceUrl },
  });
  const byKind = new Map<string, Media[]>();
  for (const m of out) byKind.set(m.kind, [...(byKind.get(m.kind) ?? []), m]);
  for (const list of byKind.values()) {
    const sorted = [...list].sort((a, b) => b.width * b.height - a.width * a.height);
    sorted.forEach((m, i) => {
      const best = sorted.slice(0, i).find((x) => !x.duplicateOf && Math.abs(m.width / m.height - x.width / x.height) < 0.01);
      if (best && !m.duplicateOf) m.duplicateOf = best.id;
    });
  }
  return out;
}

async function program(slug: string): Promise<Program> {
  const all = await loadFixtures();
  const extra = extraPrograms().find((p) => p.slug === slug);
  const base: Program | undefined = all.find((p) => p.slug === slug) ?? (extra ? { ...extra, media: [], colours: {}, roles: {} } : undefined);
  if (!base) throw new ApiError(404, "no program " + slug);
  const s = store(slug);
  const media: Media[] = dress([...base.media, ...(s.added ?? [])]).map((m) => ({ ...m, ...(s.extra?.[m.id] ?? {}), picked: s.picked[m.id] ?? m.picked }));
  let colours = colourCache.get(slug);
  if (!colours) {
    const subject = media.find((m) => m.id === base.roles.subject) ?? media[0];
    colours = subject ? namedColours(subject.thumb).catch(() => ({})) : Promise.resolve({});
    colourCache.set(slug, colours);
  }
  return { ...base, media, colours: await colours };
}

async function mediaMap(slug: string) { return new Map((await program(slug)).media.map((m) => [m.id, m])); }

// ---------------------------------------------------------------- events and jobs

const listeners = new Set<(e: EngineEvent) => void>();
const jobs = new Map<string, Job>();
function emitJob(job: Job) { jobs.set(job.id, job); listeners.forEach((f) => f({ type: "job", job })); }

let jobSeq = 0;
/** Runs `work` as a job the activity panel can show. */
async function asJob<T>(title: string, program: string | undefined, group: string, work: () => Promise<T>, eta = 1): Promise<T> {
  const id = "mock-" + ++jobSeq;
  const job: Job = { id, program, title, state: "running", progress: 0.1, eta, group };
  emitJob(job);
  const tick = setInterval(() => emitJob({ ...job, progress: Math.min(0.95, (jobs.get(id)?.progress ?? 0) + 0.25), eta: Math.max(0, (jobs.get(id)?.eta ?? eta) - 0.25) }), 250);
  try {
    const r = await work();
    emitJob({ ...job, state: "done", progress: 1, eta: 0 });
    return r;
  } catch (e) {
    emitJob({ ...job, state: "failed", progress: 1, detail: String(e) });
    throw e;
  } finally { clearInterval(tick); }
}

/** A little background work so the activity panel has something to show (only in the mock). */
function demoJobs() {
  const titles = ["Analyse · picked images (palette, OCR, flat sides)", "Cut out subject · box front", "Download hi-res · disc scan", "Find duplicates · feature print"];
  titles.forEach((title, i) => {
    const id = "demo-" + i;
    let p = 0;
    emitJob({ id, title, state: i < 2 ? "running" : "queued", progress: 0, eta: 6 + i * 3, group: "Gather (mock)" });
    setTimeout(() => {
      const t = setInterval(() => {
        p = Math.min(1, p + 0.08 + Math.random() * 0.05);
        emitJob({ id, title, state: p >= 1 ? "done" : "running", progress: p, eta: Math.round((1 - p) * 8), group: "Gather (mock)" });
        if (p >= 1) clearInterval(t);
      }, 600);
    }, i * 1800);
  });
}

// ---------------------------------------------------------------- renders

const renderCache = new Map<string, Promise<any>>();
function cached<T>(key: string, f: () => Promise<T>): Promise<T> {
  let p = renderCache.get(key);
  if (!p) { p = f(); p.catch(() => renderCache.delete(key)); renderCache.set(key, p); }
  return p;
}
const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function iconRender(doc: Doc, appearance: any, size: number) {
  const media = await mediaMap(doc.program);
  const S = Math.max(16, Math.min(1024, size));
  await resources.ensure(sketchRequests(doc, S, media));
  await delay(150 + Math.min(600, S / 2)); // ictool isn't instant; nor should the mock be
  const c = document.createElement("canvas"); c.width = S; c.height = S;
  const g = c.getContext("2d")!;
  // Full bleed, as v1's ictool renders were.
  drawSketch(g, doc, S, { appearance, pixelRatio: 1, media });
  return { url: await toBlobUrl(c), icon: `(mock)/${doc.program}/${doc.id}.icon` };
}

// ---------------------------------------------------------------- routes

type Handler = (m: RegExpMatchArray, body: any) => Promise<unknown>;
const routes: [string, RegExp, Handler][] = [
  ["GET", /^\/api\/programs$/, async () => {
    const all = [...extraPrograms().map((p) => ({ ...p, media: [], colours: {}, roles: {} } as Program)), ...await loadFixtures()];
    return all.map((p): ProgramSummary => {
      const s = store(p.slug);
      const subject = p.media.find((m) => m.id === p.roles.subject) ?? p.media[0];
      return { slug: p.slug, title: p.title, year: p.year, thumb: subject?.thumb, media: p.media.length, pins: s.pins.length, updated: new Date().toISOString() };
    });
  }],
  ["GET", /^\/api\/programs\/([^/]+)$/, async (m) => program(m[1])],
  ["GET", /^\/api\/programs\/([^/]+)\/look$/, async (m) => {
    const { colours, colourOrder, roles } = await program(m[1]);
    return { colours, colourOrder, roles };
  }],
  ...stageOneAndTwoRoutes(),
  ["PATCH", /^\/api\/programs\/([^/]+)\/media\/([^/]+)$/, async (m, body) => {
    const s = store(m[1]);
    if (typeof body.picked === "boolean") s.picked[m[2]] = body.picked;
    persist(m[1], s);
    const media = (await program(m[1])).media.find((x) => x.id === m[2]);
    if (!media) throw new ApiError(404, "no media");
    const out = { ...media, ...(body.kind ? { kind: body.kind } : {}) };
    listeners.forEach((f) => f({ type: "media", program: m[1], media: out }));
    return out;
  }],
  ["GET", /^\/api\/treatments$/, async () => TREATMENTS],
  ["POST", /^\/api\/programs\/([^/]+)\/suggestions$/, async (m, body) => {
    const p = await program(m[1]);
    return generate(p, body.params ?? {}, body.treatments);
  }],
  ["POST", /^\/api\/render\/content$/, async (_m, body) => {
    const media = await mediaMap(body.program);
    const key = JSON.stringify(["content", body.program, body.content, body.pixelWidth, body.canvasWidth ?? 1]);
    return cached(key, async () => {
      const c = await renderContent(body.content, body.pixelWidth, media, body.canvasWidth ?? 1);
      return { url: await toBlobUrl(c), width: c.width, height: c.height, box: (c as any).box };
    });
  }],
  ["POST", /^\/api\/render\/shape$/, async (_m, body) =>
    cached(JSON.stringify(["shape", body.shape, body.size]), async () => ({ url: await toBlobUrl(renderShape(body.shape, body.size)) }))],
  ["POST", /^\/api\/render\/mask$/, async (_m, body) => {
    const media = await mediaMap(body.program);
    return cached(JSON.stringify(["mask", body.program, body.mask, body.size]), async () => ({ url: await toBlobUrl(await renderMask(body.mask, body.size, media)) }));
  }],
  ["POST", /^\/api\/render\/icon$/, async (_m, body) => {
    const { id: _i, parent: _p, name: _n, created: _c, origin: _o, ...visual } = body.doc;
    const key = JSON.stringify(["icon", visual, body.appearance, body.size]);
    if (renderCache.has(key)) return renderCache.get(key);
    return cached(key, () => asJob(`Render icon · ${body.doc.name} · ${body.appearance} ${body.size}`, body.doc.program, "Renders", () => iconRender(body.doc, body.appearance, body.size), 0.6));
  }],
  ["GET", /^\/api\/programs\/([^/]+)\/docs$/, async (m): Promise<DocsState> => {
    const s = store(m[1]);
    return { docs: Object.values(s.docs), pins: s.pins, current: s.current };
  }],
  ["PUT", /^\/api\/programs\/([^/]+)\/docs\/([^/]+)$/, async (m, body) => {
    const s = store(m[1]);
    s.docs[m[2]] = body; persist(m[1], s); return body;
  }],
  ["PUT", /^\/api\/programs\/([^/]+)\/current$/, async (m, body) => {
    const s = store(m[1]); s.current = body.id; persist(m[1], s); return {};
  }],
  ["POST", /^\/api\/programs\/([^/]+)\/pins$/, async (m, body) => {
    const s = store(m[1]);
    if (!s.docs[body.id]) throw new ApiError(404, "pin an unsaved doc");
    if (!s.pins.includes(body.id)) s.pins.push(body.id);
    persist(m[1], s); return { pins: s.pins };
  }],
  ["PUT", /^\/api\/programs\/([^/]+)\/pins$/, async (m, body) => {
    const s = store(m[1]);
    const named = (body.pins as string[]).filter((p) => s.pins.includes(p));
    s.pins = [...named, ...s.pins.filter((p) => !named.includes(p))];
    persist(m[1], s); return { pins: s.pins };
  }],
  ["DELETE", /^\/api\/programs\/([^/]+)\/pins\/([^/]+)$/, async (m) => {
    const s = store(m[1]); s.pins = s.pins.filter((p) => p !== m[2]); persist(m[1], s); return { pins: s.pins };
  }],
  ["POST", /^\/api\/programs\/([^/]+)\/save$/, async (m, body) => {
    const s = store(m[1]);
    const saved = [];
    for (const id of body.ids as string[]) {
      const d = s.docs[id];
      if (!d) continue;
      await asJob(`Save · ${d.name}`, m[1], "Save", () => delay(400));
      const slugName = d.name.toLowerCase().replace(/[^a-z0-9]+/g, "-");
      saved.push({ id, icon: `data/programs/${m[1]}/saved/${slugName}.icon`, png: `data/programs/${m[1]}/saved/${slugName}.png` });
    }
    return { saved };
  }],
  ["GET", /^\/api\/jobs$/, async () => [...jobs.values()]],
];

export const mockTransport: Transport = {
  kind: "mock",
  async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const p = path.split("?")[0];
    lastQuery = path.split("?")[1] ?? "";
    for (const [m, re, h] of routes) {
      if (m !== method) continue;
      const match = p.match(re);
      if (match) {
        const decoded = match.map((x) => (x === undefined ? x : decodeURIComponent(x))) as unknown as RegExpMatchArray;
        await delay(5);
        return (await h(decoded, body ? structuredClone(body) : {})) as T;
      }
    }
    throw new ApiError(404, `mock: no route for ${method} ${path}`);
  },
  events(onEvent, onStatus) {
    listeners.add(onEvent);
    onStatus("open");
    if (!jobs.size) demoJobs();
    else jobs.forEach((job) => onEvent({ type: "job", job }));
    return () => { listeners.delete(onEvent); };
  },
};

// ---------------------------------------------------------------- stages 1 and 2

const slugify = (s: string) => s.toLowerCase().replace(/^the\s+/, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);

async function updateMedia(slug: string, id: string, patch: Partial<Media>) {
  const s = store(slug);
  s.extra = { ...(s.extra ?? {}), [id]: { ...(s.extra?.[id] ?? {}), ...patch } };
  persist(slug, s);
  const m = (await program(slug)).media.find((x) => x.id === id);
  if (m) listeners.forEach((f) => f({ type: "media", program: slug, media: m }));
  return m;
}

function hiresJob(slug: string, m: Media) {
  void asJob(`Hi-res and analysis · ${m.name}`, slug, "hires", async () => {
    await delay(600 + Math.random() * 1200);
    await updateMedia(slug, m.id, { hires: "running" });
    await delay(1500 + Math.random() * 2500);
    const box = m.analysis.subjectBox;
    await updateMedia(slug, m.id, {
      hires: "done",
      deep: {
        aesthetics: Math.round((0.4 + Math.random() * 0.5) * 100) / 100, utility: m.kind === "manual" || m.kind === "box-back",
        legibility: Math.round((box ? 0.5 + box[2] * 0.4 : 0.3) * 100) / 100,
        titleBox: m.analysis.textFraction > 0.05 ? [0.1, 0.06, 0.8, 0.18] : undefined,
        rectangle: m.kind === "box-front" ? [[0.03, 0.02], [0.97, 0.03], [0.96, 0.98], [0.02, 0.97]] : undefined,
        paletteRoles: { dominant: "#3a2a8f", accent: "#f6c445", background: "#1d2347", ink: "#111111", paper: "#f4ecd2" },
        accentContrast: 7.2,
      },
    });
  }, 4);
}

const FAKE_FS: Record<string, { name: string; dir?: boolean; size?: number; type: any; hint?: string }[]> = {
  "/Users/you": [{ name: "Downloads", dir: true, type: "folder" }, { name: "Games", dir: true, type: "folder", hint: "Has Windows programs" }, { name: ".hidden", dir: true, type: "folder" }],
  "/Users/you/Downloads": [
    { name: "zoombinis.iso", size: 412_000_000, type: "disc-image" }, { name: "SETUP.EXE", size: 2_400_000, type: "installer" },
    { name: "keen1.zip", size: 1_200_000, type: "archive" }, { name: "readme.txt", size: 2_100, type: "other" },
  ],
  "/Users/you/Games": [{ name: "Zoombinis.app", dir: true, type: "wrapp", hint: "A game's app made by Second Chance" }, { name: "KEEN", dir: true, type: "folder", hint: "Has Windows programs" }],
  "/Users/you/Games/KEEN": [{ name: "KEEN1.EXE", size: 98_000, type: "program", hint: "DOS program" }, { name: "EGAHEAD.CK1", size: 40_000, type: "other" }],
  "/Users/Shared/second-chance/installers": [{ name: "zoombinis", dir: true, type: "folder" }],
  "/Users/Shared/second-chance/installers/zoombinis": [{ name: "Zoombinis.iso", size: 412_000_000, type: "disc-image" }],
};
const PLACES = [["Home", "/Users/you"], ["Downloads", "/Users/you/Downloads"], ["Games", "/Users/you/Games"], ["Installers store", "/Users/Shared/second-chance/installers"]];

let scanSeq = 0;
function fakeScan(slug: string, path: string): string {
  const scan = "mock" + ++scanSeq;
  const name = path.split("/").pop() ?? path;
  const emit = (event: any) => listeners.forEach((f) => f({ type: "scan", program: slug, scan, event }));
  const steps: any[] = [
    { event: "node", id: 1, name, kind: "file", size: 412_000_000, depth: 0, display: `${name} · ISO 9660 + HFS hybrid` },
    { event: "node", id: 2, parent: 1, name: "Windows side", kind: "volume", size: 0, depth: 1, display: "ISO 9660" },
    { event: "node", id: 3, parent: 2, name: "AUTORUN.INF", kind: "entry", size: 120, depth: 2, display: "names ZOOMBINI.ICO as the disc icon" },
    { event: "node", id: 4, parent: 2, name: "ZOOMBINI.ICO", kind: "entry", size: 9000, depth: 2, display: "icon file · 4 sizes" },
    { event: "image", sha256: "a1", node: 4, width: 32, height: 32, bitDepth: 8, display: `${name} › ZOOMBINI.ICO › 32×32`, new: true },
    { event: "image", sha256: "a2", node: 4, width: 16, height: 16, bitDepth: 8, display: `${name} › ZOOMBINI.ICO › 16×16`, new: true },
    { event: "node", id: 5, parent: 2, name: "SETUP.EXE", kind: "entry", size: 2_400_000, depth: 2, display: "InstallShield 5 launcher", installer: "InstallShield 5" },
    { event: "image", sha256: "a3", node: 5, width: 32, height: 32, bitDepth: 4, display: `${name} › SETUP.EXE › 32×32`, new: true },
    { event: "progress", nodes: 5, images: 3, queued: 6, bytesExtracted: 0 },
    { event: "node", id: 6, parent: 2, name: "DATA1.CAB", kind: "entry", size: 38_000_000, depth: 2, display: "InstallShield cabinet · unshield", installer: "InstallShield 5" },
    { event: "node", id: 7, parent: 6, name: "ZOOMBINI.EXE", kind: "entry", size: 1_800_000, depth: 3, display: "Win32 program · the launch target" },
    ...[48, 32, 16].map((s, i) => ({ event: "image", sha256: "b" + i, node: 7, width: s, height: s, bitDepth: 32, display: `${name} › DATA1.CAB › ZOOMBINI.EXE › ${s}×${s}`, new: true })),
    { event: "node", id: 8, parent: 6, name: "ART", kind: "entry", size: 0, depth: 3, display: "31 bitmaps" },
    ...Array.from({ length: 6 }, (_, i) => ({ event: "image", sha256: "c" + i, node: 8, width: 640, height: 480, bitDepth: 8, display: `${name} › DATA1.CAB › ART › SCENE${i}.BMP`, new: i % 3 !== 2 })),
    { event: "skip", node: 6, name: "SOUNDS", reason: "audio (140 files)" },
    { event: "progress", nodes: 9, images: 12, queued: 3, bytesExtracted: 38_000_000 },
    { event: "skip", node: 2, name: "DIRECTX", reason: "known redistributable" },
    { event: "node", id: 9, parent: 1, name: "Mac side", kind: "volume", size: 0, depth: 1, display: "HFS" },
    { event: "node", id: 10, parent: 9, name: "Zoombinis", kind: "fork", size: 600_000, depth: 2, display: "classic Mac app · resource fork", macType: "APPL" },
    { event: "image", sha256: "d1", node: 10, width: 32, height: 32, bitDepth: 8, display: `${name} › Mac side › Zoombinis › icl8 128`, new: true },
    { event: "skip", node: 9, name: "Zoombinis Data", reason: "unknown format (‘ZBDT’)" },
    { event: "progress", nodes: 10, images: 13, queued: 0, bytesExtracted: 41_000_000 },
    { event: "done", nodes: 10, images: 13, families: 6, skipped: 3, records: "records.jsonl", seconds: 6.2 },
  ];
  void asJob(`Find images in ${name}`, slug, "scan", async () => {
    // A ".app" replays a real icon-extract run (mock-data/scan-sample.jsonl); anything else, a made-up disc.
    let lines = steps;
    if (/\.app$/i.test(path)) {
      try { lines = (await (await fetch("/mock-files/scan-sample.jsonl")).text()).split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { /* the made-up one */ }
    }
    for (const e of lines) { await delay(lines === steps ? 220 + Math.random() * 300 : 40); emit(e); }
    // The images it "found": borrow the program's own fixture images, as "your files".
    const s = store(slug);
    const base = (await loadFixtures()).find((p) => p.slug === slug)?.media ?? [];
    const found: Media[] = base.slice(0, 3).map((m, i) => ({
      ...m, id: `${m.id}-file-${scan}-${i}`, source: "Your files", remote: undefined, picked: false, duplicateOf: undefined,
      provenance: [name, "DATA1.CAB", "ART", m.name].join(" › "), name: `${m.name.replace(/\.[^.]+$/, "")}.png`,
    }));
    s.added = [...(s.added ?? []), ...found];
    persist(slug, s);
    for (const m of found) listeners.forEach((f) => f({ type: "media", program: slug, media: m }));
  }, 7);
  return scan;
}

function stageOneAndTwoRoutes(): [string, RegExp, Handler][] {
  return [
    ["POST", /^\/api\/programs$/, async (_m, body) => {
      const r = body.result;
      const norm = (s: string) => s.toLowerCase().replace(/^the\s+/, "").replace(/[^a-z0-9]+/g, "");
      const fixture = (await loadFixtures()).find((p) => norm(p.title) === norm(r.title) || norm(r.title).includes(norm(p.title)) || norm(p.title).includes(norm(r.title)));
      const slug = fixture?.slug ?? slugify(r.title);
      if (!fixture && !extraPrograms().some((p) => p.slug === slug)) {
        try { localStorage.setItem("iconlab-mock:programs", JSON.stringify([...extraPrograms(), { slug, title: r.title, year: r.year }])); } catch { /* unavailable */ }
      }
      const p = await program(slug);
      return { slug, title: p.title, year: p.year, media: p.media.length, pins: store(slug).pins.length, updated: new Date().toISOString() } satisfies ProgramSummary;
    }],
    ["POST", /^\/api\/programs\/([^/]+)\/gather$/, async (m) => {
      void asJob("Gather images · 9 sources", m[1], "gather", () => delay(5000), 5);
      return {};
    }],
    ["POST", /^\/api\/programs\/([^/]+)\/media\/([^/]+)\/pick$/, async (m, body) => {
      const s = store(m[1]);
      s.picked[m[2]] = !!body.picked;
      persist(m[1], s);
      let media = (await program(m[1])).media.find((x) => x.id === m[2]);
      if (!media) throw new ApiError(404, "not found: media " + m[2]);
      if (body.picked && (!media.hires || media.hires === "failed")) {
        media = (await updateMedia(m[1], media.id, { hires: "queued" })) ?? media;
        hiresJob(m[1], media);
      }
      listeners.forEach((f) => f({ type: "media", program: m[1], media: media! }));
      return media;
    }],
    ["POST", /^\/api\/programs\/([^/]+)\/media\/([^/]+)\/deepen$/, async (m) => {
      const media = (await program(m[1])).media.find((x) => x.id === m[2]);
      if (media) hiresJob(m[1], media);
      return {};
    }],
    ["GET", /^\/api\/fs$/, async () => {
      // the query string is cut off by the router: read it again from the last request
      const q = new URLSearchParams(lastQuery);
      const path = q.get("path") || "/Users/you";
      const list = FAKE_FS[path];
      if (!list) throw new ApiError(404, "not found: " + path);
      const parent = path.split("/").slice(0, -1).join("/") || "/";
      return {
        path, parent,
        entries: list.filter((e) => q.get("hidden") === "1" || !e.name.startsWith(".")).map((e) => ({ ...e, dir: !!e.dir, path: path + "/" + e.name })),
        places: PLACES.map(([name, p]) => ({ name, path: p, dir: true, type: "folder" })),
      };
    }],
    ["POST", /^\/api\/programs\/([^/]+)\/extract$/, async (m, body) => {
      if (/\.txt$/i.test(body.path)) throw new ApiError(500, "icon-extract isn't built: run `swift build -c release --product icon-extract` in Packages/WrappKit");
      return { scan: fakeScan(m[1], body.path) };
    }],
  ];
}
let lastQuery = "";
