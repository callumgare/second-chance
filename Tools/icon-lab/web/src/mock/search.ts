// A stand-in for the engine's program search (stage 1) until its routes answer: a small canned catalogue
// "searched" by the real sources' names, each answering after its own delay, so the page sees results stream in,
// merge and re-rank as they will for real. Events go out through emitLocal as `search` snapshots.
import { ApiError, emitLocal, type ProgramHit, type ProgramResult, type SearchSnapshot, type SearchSource, type SourceInfo } from "../api";

export const MOCK_SOURCES: (SourceInfo & { delay: number; coverage: number })[] = [
  { id: "launchbox", name: "LaunchBox", state: "ready", local: true, delay: 60, coverage: 0.9, note: "local copy, updated weekly" },
  { id: "thegamesdb", name: "TheGamesDB", state: "ready", local: true, delay: 90, coverage: 0.7 },
  { id: "wikidata", name: "Wikidata", state: "ready", local: false, delay: 700, coverage: 0.85 },
  { id: "wikipedia", name: "Wikipedia", state: "ready", local: false, delay: 900, coverage: 0.8 },
  { id: "pcgamingwiki", name: "PCGamingWiki", state: "ready", local: false, delay: 1300, coverage: 0.5 },
  { id: "lutris", name: "Lutris", state: "ready", local: false, delay: 1100, coverage: 0.4 },
  { id: "steam", name: "Steam", state: "ready", local: false, delay: 800, coverage: 0.3 },
  { id: "gog", name: "GOG", state: "ready", local: false, delay: 1000, coverage: 0.3 },
  { id: "archive", name: "Internet Archive", state: "ready", local: false, delay: 3600, coverage: 0.7, note: "one request every 4 s" },
  { id: "macrepo", name: "Macintosh Repository", state: "ready", local: false, delay: 5200, coverage: 0.35, note: "one request every 10 s" },
  { id: "winworld", name: "WinWorld", state: "ready", local: false, delay: 2100, coverage: 0.25 },
  { id: "myabandonware", name: "MyAbandonware", state: "ready", local: false, delay: 2400, coverage: 0.5 },
  { id: "igdb", name: "IGDB", state: "needsKey", local: false, delay: 0, coverage: 0, note: "needs IGDB_CLIENT_ID and IGDB_CLIENT_SECRET in .env" },
  { id: "steamgriddb", name: "SteamGridDB", state: "needsKey", local: false, delay: 0, coverage: 0, note: "needs STEAMGRIDDB_KEY in .env" },
  { id: "screenscraper", name: "ScreenScraper", state: "needsKey", local: false, delay: 0, coverage: 0, note: "needs developer credentials" },
  { id: "mobygames", name: "MobyGames", state: "linkOnly", local: false, delay: 0, coverage: 0, note: "link only without a paid key" },
  { id: "macgarden", name: "Macintosh Garden", state: "linkOnly", local: false, delay: 0, coverage: 0, note: "forbids automated access" },
  { id: "discmaster", name: "Discmaster", state: "linkOnly", local: false, delay: 0, coverage: 0, note: "forbids automated access" },
];

type Entry = { key: string; title: string; year: number; platforms: string[]; developer: string; publisher: string; kind: string; alt?: string[] }
const CATALOGUE: Entry[] = [
  { key: "Q1426862", title: "The Logical Journey of the Zoombinis", alt: ["Zoombinis"], year: 1996, platforms: ["Windows", "Mac OS"], developer: "TERC", publisher: "Broderbund", kind: "game" },
  { key: "Q20004390", title: "Zoombinis", year: 2015, platforms: ["Windows", "Mac OS X", "iOS"], developer: "TERC, FableVision", publisher: "TERC", kind: "remake" },
  { key: "Q8077012", title: "Zoombinis Mountain Rescue", year: 2001, platforms: ["Windows", "Mac OS"], developer: "TERC", publisher: "The Learning Company", kind: "game" },
  { key: "Q8077011", title: "Zoombinis Island Odyssey", year: 2002, platforms: ["Windows", "Mac OS"], developer: "TERC", publisher: "The Learning Company", kind: "game" },
  { key: "Q1477330", title: "Myst", year: 1993, platforms: ["Mac OS", "Windows"], developer: "Cyan", publisher: "Broderbund", kind: "game" },
  { key: "Q1430227", title: "realMyst", year: 2000, platforms: ["Windows", "Mac OS"], developer: "Cyan", publisher: "Ubisoft", kind: "remake" },
  { key: "Q1424880", title: "Riven", alt: ["Riven: The Sequel to Myst"], year: 1997, platforms: ["Mac OS", "Windows"], developer: "Cyan", publisher: "Red Orb", kind: "game" },
  { key: "Q5496025", title: "Freddi Fish and the Case of the Missing Kelp Seeds", alt: ["Freddi Fish"], year: 1994, platforms: ["Windows", "Mac OS"], developer: "Humongous Entertainment", publisher: "Humongous Entertainment", kind: "game" },
  { key: "Q1070468", title: "Commander Keen in Invasion of the Vorticons", alt: ["Commander Keen"], year: 1990, platforms: ["DOS"], developer: "id Software", publisher: "Apogee", kind: "game" },
  { key: "Q1070469", title: "Commander Keen in Goodbye, Galaxy!", alt: ["Commander Keen 4"], year: 1991, platforms: ["DOS"], developer: "id Software", publisher: "Apogee", kind: "game" },
  { key: "keen-demo", title: "Commander Keen: Marooned on Mars (shareware)", year: 1990, platforms: ["DOS"], developer: "id Software", publisher: "Apogee", kind: "demo" },
  { key: "Q1428218", title: "The Oregon Trail", alt: ["Oregon Trail"], year: 1985, platforms: ["Apple II", "DOS", "Mac OS", "Windows"], developer: "MECC", publisher: "MECC", kind: "game" },
  { key: "Q7101945", title: "Oregon Trail II", year: 1995, platforms: ["Windows", "Mac OS"], developer: "MECC", publisher: "MECC", kind: "game" },
  { key: "Q4915224", title: "Bioscopia", year: 2002, platforms: ["Windows", "Mac OS"], developer: "Heureka-Klett", publisher: "Viva Media", kind: "game" },
  { key: "Q1150906", title: "Kid Pix", year: 1989, platforms: ["Mac OS", "Windows"], developer: "Craig Hickman", publisher: "Broderbund", kind: "software" },
  { key: "Q686155", title: "HyperCard", year: 1987, platforms: ["Mac OS"], developer: "Apple", publisher: "Apple", kind: "software" },
  { key: "Q1062030", title: "SimCity 2000", year: 1993, platforms: ["DOS", "Mac OS", "Windows"], developer: "Maxis", publisher: "Maxis", kind: "game" },
  { key: "Q1059040", title: "Lemmings", year: 1991, platforms: ["Amiga", "DOS", "Mac OS"], developer: "DMA Design", publisher: "Psygnosis", kind: "game" },
  { key: "Q1661796", title: "The Incredible Machine", year: 1993, platforms: ["DOS", "Mac OS"], developer: "Dynamix", publisher: "Sierra", kind: "game" },
  { key: "Q2002196", title: "Nancy Drew: Treasure in the Royal Tower", year: 2001, platforms: ["Windows"], developer: "Her Interactive", publisher: "DreamCatcher", kind: "game" },
  { key: "Q1755830", title: "Where in the World Is Carmen Sandiego?", year: 1985, platforms: ["Apple II", "DOS", "Mac OS"], developer: "Broderbund", publisher: "Broderbund", kind: "game" },
];

const norm = (s: string) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
function hash(s: string) { let h = 2166136261; for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return (h >>> 0) / 4294967296; }

function similarity(q: string, e: Entry) {
  const nq = norm(q);
  if (!nq) return 0;
  let best = 0;
  for (const t of [e.title, ...(e.alt ?? [])]) {
    const nt = norm(t);
    if (nt === nq) return 1;
    const words = nq.split(" ");
    const hit = words.filter((w) => nt.split(" ").some((x) => x.startsWith(w))).length / words.length;
    const contains = nt.includes(nq) ? 0.9 : 0;
    best = Math.max(best, contains, hit * 0.85 * Math.min(1, nq.length / Math.max(4, nt.length) + 0.5));
  }
  return best;
}

type Search = { id: string; q: string; answered: Set<string>; started: number }
const searches = new Map<string, Search>();
let seq = 0;

function snapshot(s: Search): SearchSnapshot {
  const ready = MOCK_SOURCES.filter((x) => x.state === "ready");
  const matches = CATALOGUE.map((e) => ({ e, sim: similarity(s.q, e) })).filter((m) => m.sim >= 0.35);
  const sources: SearchSource[] = MOCK_SOURCES.map((x) => ({
    id: x.id, name: x.name, state: x.state, note: x.note,
    running: x.state === "ready" && !s.answered.has(x.id),
    count: s.answered.has(x.id) ? matches.filter((m) => hash(x.id + m.e.key) < x.coverage).length : 0,
  }));
  const results: ProgramResult[] = [];
  for (const { e, sim } of matches) {
    const hits: ProgramHit[] = ready.filter((x) => s.answered.has(x.id) && hash(x.id + e.key) < x.coverage).map((x) => ({
      source: x.id, sourceId: x.id === "wikidata" ? e.key : `${x.id}-${Math.floor(hash(e.key + x.id) * 99999)}`,
      title: x.id === "launchbox" && e.alt?.[0] ? e.alt[0] : e.title, year: e.year, platforms: e.platforms,
      developer: e.developer, publisher: e.publisher, kind: e.kind,
    }));
    if (!hits.length) continue;
    const merge = hits.length > 1 ? [
      hits.some((h) => h.source === "wikidata") ? `same Wikidata item (${e.key})` : `title + year + publisher match`,
      ...(hits.length > 3 ? [`${hits.length - 1} sources carry the Wikidata id`] : []),
    ] : [];
    const era = e.year >= 1980 && e.year <= 2010 ? 8 : 0;
    const score = Math.min(100, Math.round(sim * 70 + era + Math.min(5, hits.length) * 4 + (e.kind === "remake" ? -6 : 0)));
    const links: Record<string, string> = { wikipedia: `https://en.wikipedia.org/wiki/${encodeURIComponent(e.title)}` };
    for (const x of MOCK_SOURCES.filter((y) => y.state === "linkOnly")) links[x.id] = `https://example.org/${x.id}/${encodeURIComponent(norm(e.title).replace(/ /g, "-"))}`;
    results.push({ key: "wikidata:" + e.key, title: e.title, year: e.year, platforms: e.platforms, developer: e.developer, publisher: e.publisher, kind: e.kind, ids: { wikidata: e.key }, links, hits, mergeReasons: merge, score });
  }
  results.sort((a, b) => b.score - a.score);
  return { id: s.id, q: s.q, sources, results, done: ready.every((x) => s.answered.has(x.id)) };
}

export const mockSearch = {
  sources: async (): Promise<SourceInfo[]> => MOCK_SOURCES.map(({ delay: _d, coverage: _c, ...s }) => s),
  start: async (q: string): Promise<{ id: string }> => {
    const s: Search = { id: "mock-search-" + ++seq, q, answered: new Set(), started: Date.now() };
    searches.set(s.id, s);
    // Drop older searches' timers' effects: each answer only matters to its own search.
    for (const x of MOCK_SOURCES.filter((y) => y.state === "ready")) {
      setTimeout(() => { s.answered.add(x.id); emitLocal({ type: "search", ...snapshot(s) }); }, x.delay * (0.7 + hash(q + x.id) * 0.6));
    }
    setTimeout(() => emitLocal({ type: "search", ...snapshot(s) }), 10);
    return { id: s.id };
  },
  snapshot: async (id: string): Promise<SearchSnapshot> => {
    const s = searches.get(id);
    if (!s) throw new ApiError(404, "no such search");
    return snapshot(s);
  },
};
