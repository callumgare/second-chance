// The engine's API, typed. Mirrors docs/document.md and docs/api.md: keep the two in step.
// Every call goes through `transport`, which is the real engine (fetch) or the in-browser mock.

import { listenToEvents } from "./host";

// ---------------------------------------------------------------- the document (document.md)

export type Doc = {
  schema: 1
  id: string
  parent: string | null
  name: string
  program: string
  origin?: { treatment: string; params: SuggestionParams }
  fill: Fill
  groups: Group[] // FRONT first
  created: string
  [unknown: string]: unknown // unknown keys are kept
}

export type Fill = { kind: "gradient" | "solid" | "none"; color: string; dark?: string }

export type Group = {
  id: string
  name: string
  hidden?: boolean
  glass: Glass
  layers: Layer[] // FRONT first
  [unknown: string]: unknown
}

export type Glass = {
  specular: boolean
  shadow: number
  shadowKind?: "none" | "neutral" | "chromatic"
  lighting?: "individual" | "combined"
  translucency: number | null
  blur: number | null
}

export type Role = "subject" | "logo" | "backdrop" | "pattern" | "frame" | "icon" | "disc" | "decoration"

export type Layer = {
  id: string
  name: string
  role?: Role
  hidden?: boolean
  opacity: number
  content: Content
  transform: Transform
  mask?: Mask | null
  [unknown: string]: unknown
}

export type Transform = { x: number; y: number; width: number; rotation: number }

export type Crop = [number, number, number, number]

export type ImageContent = {
  kind: "image"
  asset: string
  cutout: boolean
  crop?: Crop | null
  smoothing: "smooth" | "pixel"
  effects: Effect[]
}
export type ShapeContent = { kind: "shape"; shape: Shape }
export type Content = ImageContent | ShapeContent

export type PatternKind = "stripes" | "dots" | "grid" | "checker" | "rays"

export type Shape =
  | { type: "solid"; color: string }
  | { type: "gradient"; from: string; to: string; angle: number }
  | { type: "pattern"; pattern: PatternKind; a: string; b: string }
  | { type: "bands"; colors: string[] }
  | { type: "window"; frame: string; bar: string }
  | { type: "crt"; bezel: string }
  | { type: "disc-rims"; color: string }
  | { type: "text"; text: string; font: string; color: string; size?: number } // size: share of the canvas (0.86)
  | { type: "rounded-rect"; rect: [number, number, number, number]; radius: number; color: string } // canvas units
  | { type: "circle"; radius: number; color: string } // centred

export type ShapeType = Shape["type"]

export type Effect =
  | { op: "silhouette"; color: string }
  | { op: "outline"; color: string; width: number }
  | { op: "feather"; softness: number; offset: number }   // canvas units; offset: negative in, positive out
  | { op: "halftone"; ink: string; cell: number; angle: number }
  | { op: "tone"; level: 0 | 1 | 2; color: string }
  | { op: "gradient-map"; dark: string; light: string }
  | { op: "blur"; radius: number }
  | { op: "autocontrast" }
  | { op: "edges"; color: string }
  | { op: "riso"; ink: string; band: "dark" | "mid"; offset: [number, number] }
  | { op: "posterize"; colors: number }
  | { op: "scanlines" }
  | { op: "tint"; color: string; amount: number }
  | { op: "brightness-contrast"; brightness: number; contrast: number }   // each -1…1, 0 unchanged
  | { op: "key"; tolerance: number }
  | { op: "mask"; mask: Mask; lock: "canvas" | "image"; invert?: boolean } // canvas: stays put as the layer moves; image: moves with it
  | { op: "flatten"; color: string }

export type EffectOp = Effect["op"]

export type Mask =
  | { kind: "shape"; shape: Shape; transform: Transform; invert?: boolean }
  | { kind: "image"; asset: string; cutout: true; crop?: Crop | null; transform: Transform }
  | { kind: "ring"; outer: number; inner: number }
  | { kind: "linear-fade"; angle: number; start: number; end: number }

export type SuggestionParams = {
  primary?: string; secondary?: string; background?: string
  scale?: number; dx?: number; dy?: number
  logoScale?: number
  dx2?: number; dy2?: number
  angle?: number; pattern?: string; cell?: number; offset?: number; letter?: string
  roles?: Partial<Record<"subject" | "fill" | "disc" | "logo" | "icon", string>>
}

// ---------------------------------------------------------------- programs and media (api.md)

export type ProgramSummary = { slug: string; title: string; year?: number; bundleId?: string; thumb?: string; media: number; pins: number; updated: string }

export type MediaKind = "box-front" | "box-back" | "box-spine" | "disc" | "logo" | "icon" | "title-screen" | "screenshot"
  | "banner" | "manual" | "cutout" | "art" | "other"

export type Media = {
  id: string
  name: string
  kind: MediaKind | "unknown"; kindConfidence: number
  kindSource?: "you" | "source" | "analysis"
  kindGuesses?: { kind: MediaKind; p: number }[]
  sourceLabel?: string
  rotation?: Rotation; rotationAuto?: boolean; rotationWhy?: string
  /** The whole picture first (id "whole"), then everything cut or cropped from it. Filled in by the page
   *  (parts/normalize) when the engine doesn't send them yet. */
  parts?: Part[]
  /** Set by the page: these parts were made here (the engine doesn't send parts yet). */
  partsLocal?: boolean
  source: string
  sourceUrl?: string
  provenance?: string
  /** Where it came from: its page at the source, a search there (old imports), or the source's home page. */
  link?: { url: string; kind: "page" | "search" | "home"; label: string }
  width: number; height: number
  url: string
  thumb: string
  cutout?: string
  mask?: string
  picked: boolean
  analysis: {
    subject: boolean; subjectBox?: [number, number, number, number]
    flatSides: ("left" | "right" | "top" | "bottom")[]
    text: string[]; textFraction: number
    busyness: number
    palette: string[]
    circle?: [number, number, number]
    pixelArt?: boolean
    /** Share of the picture that isn't transparent (0…1), when measured. */
    coverage?: number
    /** Any pixel isn't opaque. */
    hasAlpha?: boolean
    scores: Record<string, number>
  }
  suitability: number
  cutoutSize?: [number, number]
  // Stage 2 (api.md, "Stage 2"): all optional.
  remote?: RemoteMedia
  /** For pictures from general searches: how likely they're of this program (0…1), and why. */
  relevance?: number; relevanceWhy?: string[]
  hires?: "queued" | "running" | "done" | "failed"
  /** A larger copy actually replaced the picture (hires "done" alone may have found none). */
  upgraded?: boolean
  /** Left out of the grid (unless "Show hidden") and of suggestions. */
  hidden?: boolean
  duplicateOf?: string
  derivedFrom?: string
  deep?: DeepFindings
}

export type Rotation = 0 | 90 | 180 | 270

export type PartSource = "whole" | "subject" | "instance" | "text" | "rectangle" | "disc" | "region" | "sam" | "frame"
export type Edges = { grow: number; soften: number; fillHoles: boolean }
export type Prompt = { region?: [number, number, number, number]; points?: { x: number; y: number; positive: boolean }[]; choice?: number }

export type Part = {
  id: string
  name: string
  source: PartSource
  kind: MediaKind | "unknown"; kindSet?: boolean
  box: [number, number, number, number]   // in the picture (unturned), 0…1
  quad?: number[][]
  hasMask: boolean
  rotation: Rotation; rotationAuto?: boolean; rotationWhy?: string
  picked: boolean
  size: [number, number]                   // the part image's pixel size, turned
  flatSides?: ("left" | "right" | "top" | "bottom")[]
  edges?: Edges
  prompt?: Prompt
  /** A cut-out found in another frame of a video: that frame's part id. */
  frame?: string
  image: string; thumb: string; mask?: string
}

export type Candidate = { id: string; url: string; mask: string; score: number; box: [number, number, number, number]; area: number }

export type RemoteMedia = {
  source: string; url: string; thumbUrl?: string; kind?: string; sourceLabel?: string
  width?: number; height?: number; region?: string; title?: string; pageUrl?: string; license?: string
}

export type DeepFindings = {
  /** Added by hand (dropped in from the computer): top of the scale, and not found again by a scan. */
  byHand?: boolean
  aesthetics?: number; utility?: boolean
  faces?: number; faceBoxes?: number[][]
  rectangle?: number[][]
  trim?: [number, number, number, number]
  titleBox?: [number, number, number, number]
  legibility?: number
  paletteRoles?: Partial<Record<"dominant" | "accent" | "background" | "ink" | "paper", string>>
  accentContrast?: number
  // from icon-extract, for images found in your files
  roles?: string[]; extractScore?: number; scoreReasons?: string[]; foundIn?: string[]
  /** A video's number of frames (its frames are its parts), and the best one's part id ("frame-2"). */
  frames?: number; bestFrame?: string
}

// ---------------------------------------------------------------- search (stage 1)

export type SourceState = "ready" | "needsKey" | "linkOnly" | "disabled"
export type SourceInfo = { id: string; name: string; state: SourceState; note?: string; local: boolean; homepage?: string; search?: boolean; media?: boolean }
export type SearchSource = { id: string; name: string; state: SourceState; note?: string; running: boolean; count: number }

export type ProgramHit = {
  source: string; sourceId: string; title: string; alternateTitles?: string[]; year?: number; platforms?: string[]
  developer?: string; publisher?: string; kind?: string; thumb?: string; url?: string; ids?: Record<string, string>; summary?: string
}

export type ProgramResult = {
  key: string; title: string; year?: number; platforms: string[]; developer?: string; publisher?: string
  kind?: string; thumb?: string; ids: Record<string, string>; links: Record<string, string>
  hits: ProgramHit[]; mergeReasons: string[]; score: number
  /** The person merged it: it can be unmerged. */
  mergedByYou?: boolean
  /** The programs already opened from it, the one with the most designs first. */
  programs?: OpenedProgram[]
  /** One of its hits is the host's program with this bundle id (source "secondchance"). */
  bundleId?: string
}

/** The person's merges (`GET /api/merges`): hit keys (`<source>:<id>`) that are one program, and hits kept apart. */
export type MergeRules = { groups: string[][]; apart: string[] };
export const hitKey = (h: ProgramHit) => `${h.source}:${h.sourceId}`;

export type ModelStatus = { name: string; purpose: string; size: number; licence: string; source: string
  state: "absent" | "downloading" | "compiling" | "ready" | "failed"; progress?: number; error?: string }
const MOCK_MODELS: ModelStatus[] = [
  { name: "mobileclip-s2-image", purpose: "an image's kind and its embedding", size: 72e6, licence: "Apple ML Research Model licence", source: "", state: "ready" },
  { name: "birefnet-lite", purpose: "a subject mask, as a second opinion", size: 95e6, licence: "MIT", source: "", state: "absent" },
];

export type SearchSnapshot = { id: string; q: string; sources: SearchSource[]; results: ProgramResult[]; done: boolean }

// ---------------------------------------------------------------- your files (stage 2)

export type FSType = "wrapp" | "app" | "disc-image" | "installer" | "archive" | "program" | "image" | "folder" | "other"
export type FSEntry = { name: string; path: string; dir: boolean; size?: number; type: FSType; hint?: string }
export type FSListing = { path: string; parent?: string | null; entries: FSEntry[]; places: FSEntry[] }

/** icon-extract's JSON lines (ProgramImages' ExtractionEvent). */
export type ScanLine =
  | { event: "node"; id: number; parent?: number; name: string; kind: string; size: number; depth: number; display: string; installer?: string; macType?: string }
  | { event: "image"; sha256: string; node: number; width: number; height: number; bitDepth: number; display: string; new: boolean }
  | { event: "skip"; node?: number; name: string; reason: string }
  | { event: "progress"; nodes: number; images: number; queued: number; bytesExtracted: number }
  | { event: "done"; nodes: number; images: number; families: number; skipped: number; records: string; seconds: number }

export type RoleKey = "subject" | "fill" | "disc" | "logo" | "icon"

/** A program opened from a search result before, with what it holds. */
export type OpenedProgram = { slug: string; title: string; media: number; picked: number; pins: number; thumb?: string; bundleId?: string }

export type Program = {
  slug: string; title: string; year?: number
  /** The host's bundle it was opened from (`freeware/skifree`). */
  bundleId?: string
  media: Media[]
  colours: Record<string, string>
  colourOrder?: string[]
  roles: Partial<Record<RoleKey, string>>
}

export type ContentRender = { url: string; width: number; height: number; box?: [number, number, number, number] }

export type Suggestion = { treatment: string; title: string; about: string; uses: string[]; doc: Doc }
export type Treatment = { key: string; title: string; about: string; uses: string[] }

export type Appearance = "light" | "dark" | "tinted" | "clear"

export type DocsState = { docs: Doc[]; pins: string[]; current: string | null; /** Pins Review isn't keeping. */ dropped?: string[] }

export type Job = {
  id: string; program?: string; title: string; state: "queued" | "running" | "done" | "failed"
  progress: number; eta?: number; detail?: string; group?: string; source?: string
  /** A scan job's scan: its `scan` events are this id's. */
  scan?: string
  started?: string; finished?: string
}

export type EngineEvent =
  | { type: "job"; job: Job }
  | { type: "media"; program: string; media: Media }
  | { type: "render"; key: string; url: string }
  | ({ type: "search" } & SearchSnapshot)
  | { type: "scan"; program: string; scan: string; event: ScanLine }
  | { type: "model"; model: ModelStatus }
  | { type: "media-removed"; program: string; ids: string[] }

// ---------------------------------------------------------------- transport

export interface Transport {
  readonly kind: "engine" | "mock"
  request<T>(method: string, path: string, body?: unknown): Promise<T>
  /** Subscribes to engine events; returns an unsubscribe. `onStatus` reports the connection. */
  events(onEvent: (e: EngineEvent) => void, onStatus: (s: "connecting" | "open" | "closed") => void): () => void
}

export class ApiError extends Error {
  /** `routeMissing`: the engine doesn't have this route (a 404 with no error body), as opposed to a 404 about a
   *  thing that isn't there. */
  constructor(public status: number, message: string, public routeMissing = false) { super(message) }
}

// Events made in the browser (the stand-ins for routes the engine doesn't have yet) join the engine's.
const localListeners = new Set<(e: EngineEvent) => void>();
export function emitLocal(e: EngineEvent) { localListeners.forEach((f) => f(e)); }
export function onLocal(f: (e: EngineEvent) => void) { localListeners.add(f); return () => { localListeners.delete(f); }; }

export const engineTransport: Transport = {
  kind: "engine",
  async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(path, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      let message = body.trim();
      try { const j = JSON.parse(body); message = j?.error?.message ?? j?.error ?? j?.message ?? message; } catch { /* not JSON */ }
      throw new ApiError(res.status, String(message || `${method} ${path}: ${res.status}`), res.status === 404 && !body.trim());
    }
    const text = await res.text();
    return (text ? JSON.parse(text) : {}) as T;
  },
  events(onEvent, onStatus) {
    // A WebSocket in the dev host, the app's bridge in Second Chance (host.ts).
    return listenToEvents((e) => onEvent(e as EngineEvent), onStatus);
  },
};

let transport: Transport = engineTransport;
export function setTransport(t: Transport) { transport = t; }
export function currentTransport() { return transport; }

/** Decides between the engine and the mock: `?mock` forces the mock, `?engine` the engine; otherwise the
 *  engine if it answers within a moment. */
export async function chooseTransport(): Promise<Transport> {
  const q = new URLSearchParams(location.search);
  const useMock = async () => { const { mockTransport } = await import("./mock/mockServer"); return mockTransport; };
  if (q.has("mock")) return useMock();
  if (q.has("engine")) return engineTransport;
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 1500);
    const res = await fetch("/api/programs", { signal: ctl.signal });
    clearTimeout(t);
    if (res.ok && (res.headers.get("content-type") ?? "").includes("json")) return engineTransport;
  } catch { /* no engine */ }
  return useMock();
}

const req = <T,>(method: string, path: string, body?: unknown) => transport.request<T>(method, path, body);

/** The engine, or under the mock (`?mock`) the browser's stand-in for it. */
function orMock<T>(_feature: string, real: () => Promise<T>, mock: () => Promise<T>): Promise<T> {
  return transport.kind === "mock" ? mock() : real();
}
async function pagePart(program: string, content: Content, pixelWidth: number, canvasWidth: number): Promise<ContentRender> {
  const { renderPartContent } = await import("./parts/shim");
  const { useApp } = await import("./state/app");
  return renderPartContent(content, pixelWidth, useApp.getState().media, canvasWidth, program);
}
const mockSearch = () => import("./mock/search").then((m) => m.mockSearch);
const enc = encodeURIComponent;

export const api = {
  programs: () => req<ProgramSummary[]>("GET", "/api/programs"),
  program: (slug: string) => req<Program>("GET", `/api/programs/${enc(slug)}`),
  /** The program's colours and roles, which change as its pictures do. */
  look: (slug: string) => req<Pick<Program, "colours" | "colourOrder" | "roles">>("GET", `/api/programs/${enc(slug)}/look`),
  patchMedia: (slug: string, id: string, patch: { picked?: boolean; kind?: MediaKind }) =>
    req<Media>("PATCH", `/api/programs/${enc(slug)}/media/${enc(id)}`, patch),

  treatments: () => req<Treatment[]>("GET", "/api/treatments"),
  suggestions: (slug: string, params: SuggestionParams, treatments?: string[]) =>
    req<Suggestion[]>("POST", `/api/programs/${enc(slug)}/suggestions`, { params, treatments }),

  /** `canvasWidth`: the layer's transform.width, so effects sized in canvas units come out the right size.
   *  `box`: where the PNG sits relative to the content's own box ([0,0,1,1] unless an effect draws outside). */
  renderContent: async (program: string, content: Content, pixelWidth: number, canvasWidth: number, transform?: Transform): Promise<ContentRender> => {
    // A part ("<media>/<part>[@x4]") is the engine's to render; the mock draws it in the page.
    if (transport.kind === "mock" && content.kind === "image" && content.asset.includes("/")) return pagePart(program, content, pixelWidth, canvasWidth);
    return req<ContentRender>("POST", "/api/render/content", { program, content, pixelWidth, canvasWidth, ...(transform ? { transform } : {}) });
  },
  renderShape: (program: string, shape: Shape, size: number) =>
    req<{ url: string }>("POST", "/api/render/shape", { program, shape, size }),
  renderMask: (program: string, mask: Mask, size: number) =>
    req<{ url: string }>("POST", "/api/render/mask", { program, mask, size }),
  renderIcon: (doc: Doc, appearance: Appearance, size: number, cachedOnly = false) =>
    req<{ url: string; icon: string }>("POST", "/api/render/icon", { doc, appearance, size, ...(cachedOnly ? { cachedOnly } : {}) }),

  docs: (slug: string) => req<DocsState>("GET", `/api/programs/${enc(slug)}/docs`),
  putDoc: (slug: string, doc: Doc) => req<Doc>("PUT", `/api/programs/${enc(slug)}/docs/${enc(doc.id)}`, doc),
  setCurrent: (slug: string, id: string) => req<object>("PUT", `/api/programs/${enc(slug)}/current`, { id }),
  pin: (slug: string, id: string) => req<{ pins: string[] }>("POST", `/api/programs/${enc(slug)}/pins`, { id }),
  /** Saves the doc and pins it, in one call. */
  pinDoc: (slug: string, doc: Doc) => req<{ pins: string[] }>("POST", `/api/programs/${enc(slug)}/pins`, { doc }),
  /** The pins in a new order: Design and Review show it, and saving follows it. */
  /** Makes these programs one: theirs moves into `slug`'s, and they're removed. */
  absorb: (slug: string, from: string[]) => req<ProgramSummary>("POST", `/api/programs/${enc(slug)}/absorb`, { from }),
  orderPins: (slug: string, pins: string[]) => req<{ pins: string[] }>("PUT", `/api/programs/${enc(slug)}/pins`, { pins }),
  /** The pins Review isn't keeping. */
  setDropped: (slug: string, pins: string[]) => req<{ dropped: string[] }>("PUT", `/api/programs/${enc(slug)}/dropped`, { pins }),
  unpin: (slug: string, id: string) => req<{ pins: string[] }>("DELETE", `/api/programs/${enc(slug)}/pins/${enc(id)}`),
  save: (slug: string, ids: string[]) =>
    req<{ saved: { id: string; icon: string; png: string }[] }>("POST", `/api/programs/${enc(slug)}/save`, { ids }),

  jobs: () => req<Job[]>("GET", "/api/jobs"),

  // stage 1 (in the mock, mock/search.ts stands in for the catalogues)
  sources: () => orMock("search", () => req<SourceInfo[]>("GET", "/api/sources"), async () => (await mockSearch()).sources()),
  refreshSources: (force = false) => orMock("search", () => req<SourceInfo[]>("POST", "/api/sources/refresh", { force }), async () => (await mockSearch()).sources()),
  search: (q: string) => orMock("search", () => req<{ id: string }>("POST", "/api/search", { q }), async () => (await mockSearch()).start(q)),
  searchSnapshot: (id: string) => id.startsWith("mock-search-")
    ? mockSearch().then((m) => m.snapshot(id))
    : req<SearchSnapshot>("GET", `/api/search/${enc(id)}`),
  /** Merges these hits into one program, separates one, or undoes the merges holding them. The live searches are
   *  sent again with the change. */
  changeMerges: (change: { merge: string[] } | { separate: string } | { unmerge: string[] }) =>
    req<MergeRules>("POST", "/api/merges", change),
  createProgram: (result: ProgramResult) => req<ProgramSummary>("POST", "/api/programs", { result }),
  /** `sources`: only these; `clear`: first remove every picture they found before. */
  gather: (slug: string, opts: { brave?: boolean; sources?: string[]; clear?: boolean } = {}) => req<{ jobs?: string[] }>("POST", `/api/programs/${enc(slug)}/gather`, opts),

  // models
  models: () => orMock("models", () => req<ModelStatus[]>("GET", "/api/models"), async () => MOCK_MODELS),
  downloadModel: (name: string) => req<ModelStatus>("POST", `/api/models/${enc(name)}/download`),

  // stage 2
  pick: (slug: string, id: string, picked: boolean) => req<Media>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/pick`, { picked }),
  patchMediaFields: (slug: string, id: string, patch: { rotation?: Rotation; kind?: MediaKind | "unknown"; hidden?: boolean }) =>
    req<Media>("PATCH", `/api/programs/${enc(slug)}/media/${enc(id)}`, patch),
  patchPart: (slug: string, id: string, part: string, patch: { picked?: boolean; kind?: MediaKind | "unknown"; rotation?: Rotation; name?: string; edges?: Edges }) =>
    req<Media>("PATCH", `/api/programs/${enc(slug)}/media/${enc(id)}/parts/${enc(part)}`, patch),
  /** Finds cut-outs in one frame of a video (a job; the parts arrive with a media event). */
  findFrameCutouts: (slug: string, id: string, frame: string) => req<{ job: string }>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/parts/${enc(frame)}/cutouts`),
  deletePart: (slug: string, id: string, part: string) => req<Media>("DELETE", `/api/programs/${enc(slug)}/media/${enc(id)}/parts/${enc(part)}`),
  detect: (slug: string, id: string, region: [number, number, number, number]) =>
    req<{ candidates: Candidate[] }>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/detect`, { region }),
  segment: (slug: string, id: string, prompt: { points?: Prompt["points"]; region?: Prompt["region"] }) =>
    req<{ candidates: Candidate[] }>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/segment`, prompt),
  previewCandidate: (slug: string, id: string, cand: string, edges: Edges) =>
    req<{ url: string; box?: [number, number, number, number] }>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/candidates/${enc(cand)}/preview`, { edges }),
  addPart: (slug: string, id: string, body: { candidate: string; name?: string; kind?: string; edges?: Edges; prompt?: Prompt }) =>
    req<Media>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/parts`, body),
  updatePart: (slug: string, id: string, part: string, body: { candidate: string; edges?: Edges; prompt?: Prompt }) =>
    req<Media>("PUT", `/api/programs/${enc(slug)}/media/${enc(id)}/parts/${enc(part)}`, body),
  upscale: async (program: string, asset: string, mode: "photo" | "pixel") => {
    if (transport.kind === "mock") { const { localUpscale } = await import("./parts/shim"); const { useApp } = await import("./state/app"); return localUpscale(asset, mode, useApp.getState().media, program); }
    const r = await req<{ asset: string; url: string; width: number | string; height: number | string }>("POST", "/api/upscale", { program, asset, mode });
    return { ...r, width: Number(r.width), height: Number(r.height) };   // the engine sends these as strings
  },
  assetInfo: async (slug: string, asset: string) => {
    if (transport.kind === "mock") { const { localAssetInfo } = await import("./parts/shim"); const { useApp } = await import("./state/app"); return localAssetInfo(asset, useApp.getState().media, slug); }
    const r = await req<{ width: number | string; height: number | string; pixelArt: boolean }>("GET", `/api/programs/${enc(slug)}/assets/${enc(asset)}/info`);
    return { ...r, width: Number(r.width), height: Number(r.height) };
  },
  deepen: (slug: string, id: string) => req<object>("POST", `/api/programs/${enc(slug)}/media/${enc(id)}/deepen`),
  fs: (path?: string, hidden = false) => req<FSListing>("GET", `/api/fs?${new URLSearchParams({ ...(path ? { path } : {}), ...(hidden ? { hidden: "1" } : {}) })}`),
  scans: (slug: string) => req<{ scan: string; path: string; at?: string }[]>("GET", `/api/programs/${enc(slug)}/scans`),
  extract: (slug: string, path: string) => req<{ scan: string }>("POST", `/api/programs/${enc(slug)}/extract`, { path }),
  /** Adds a picture dropped in from the computer (its bytes): a Your files picture, picked, at the top of the scale. */
  uploadPicture: async (slug: string, file: File): Promise<Media> => {
    if (transport.kind === "mock") throw new ApiError(501, "Dropping pictures in needs the engine");
    const res = await fetch(`/api/programs/${enc(slug)}/media/upload?${new URLSearchParams({ name: file.name })}`, {
      method: "POST", headers: { "Content-Type": file.type || "application/octet-stream" }, body: file,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      let message = text.trim();
      try { const j = JSON.parse(text); message = j?.error?.message ?? j?.error ?? j?.message ?? message; } catch { /* not JSON */ }
      throw new ApiError(res.status, String(message || `upload: ${res.status}`));
    }
    return (await res.json()) as Media;
  },
  /** Removes every picture these sources found ("files" for Your files), without gathering again. */
  clearSources: (slug: string, sources: string[]) => req<{ removed: number }>("POST", `/api/programs/${enc(slug)}/clear`, { sources }),
  cancelJob: (id: string) => req<{ cancelled: boolean }>("POST", `/api/jobs/${enc(id)}/cancel`),

  // the host's programs and wrapps (none under the mock, or in a host that has none)
  host: () => orMock("host", () => req<HostInfo>("GET", "/api/host").catch(() => NO_HOST), async () => NO_HOST),
  knownPrograms: () => orMock("host", () => req<KnownProgram[]>("GET", "/api/known-programs"), async () => []),
  openKnown: (id: string) => req<{ slug: string }>("POST", "/api/known-programs/open", { id }),
  wrapps: () => orMock("host", () => req<Wrapp[]>("GET", "/api/wrapps"), async () => []),
  /** Puts a saved design (`id`) on a wrapp; `anywhere` when the person chose an app outside the built wrapps. */
  tryIcon: (slug: string, id: string, wrapp: string, anywhere = false) =>
    req<{ wrapp: string; icns: string }>("POST", `/api/programs/${enc(slug)}/try-icon`, { id, wrapp, anywhere }),
  saveToBundle: (slug: string, ids: string[]) => req<SavedToBundle>("POST", `/api/programs/${enc(slug)}/save-to-bundle`, { ids }),
  /** Makes the bundle's Wrappfile give the app the first saved icon (updating the icon it has, or adding one). */
  addIconLines: (slug: string) => req<{ lines: string[]; change: "added" | "updated" | "replaced" | "unchanged" }>("POST", `/api/programs/${enc(slug)}/save-to-bundle/lines`),
};

/** What the host offers (`GET /api/host`). */
export type HostInfo = { knownPrograms: number; wrapps: boolean; saveToBundle: boolean };
const NO_HOST: HostInfo = { knownPrograms: 0, wrapps: false, saveToBundle: false };
/** A program the host has a bundle for. */
export type KnownProgram = {
  id: string; title: string; slug: string; year?: number; platforms: string[]; developer?: string; publisher?: string; opened: boolean
};
/** A wrapp the host has built. */
export type Wrapp = { name: string; path: string; bundleIdentifier?: string; modified?: string };
export type SavedToBundle = {
  bundle: string; files: string[]; allowPathAdded: boolean; manifestNote?: string; wrappfileLines?: string[]; canAddLines: boolean
};
