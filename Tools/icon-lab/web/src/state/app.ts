// What the whole app shares: which API it talks to, the programs, and the open program with its media.
import { create } from "zustand";
import { api, ApiError, type Media, type Program, type ProgramSummary } from "../api";
import { withParts } from "../parts/shim";

// Stable empties for selectors (a new {} or [] each time would re-render for ever).
export const NO_COLOURS: Record<string, string> = {};
export const NO_MEDIA: Media[] = [];
export const NO_ROLES: Record<string, string | undefined> = {};

type AppState = {
  transport: "engine" | "mock" | null
  programs: ProgramSummary[] | null
  program: Program | null
  programError: string | null
  media: Map<string, Media>
  loadPrograms(): Promise<void>
  loadProgram(slug: string): Promise<void>
  setPicked(id: string, picked: boolean): Promise<void>
  setKind(id: string, kind: Media["kind"]): Promise<void>
  upsertMedia(program: string, m: Media): void
  toast: { text: string; kind: "info" | "error"; action?: { label: string; run(): void } } | null
  say(text: string, kind?: "info" | "error", action?: { label: string; run(): void }): void
  setHidden(id: string, hidden: boolean): Promise<void>
  removeMedia(program: string, ids: string[]): void
}

let toastTimer: number | undefined;

// The program asked for last: a fetch that answers after another program was asked for is dropped.
let wanted: string | null = null;

// A program's colours and roles follow from its pictures (the subject image's palette), and gathering and analysis
// change them long after the program was opened: asked for again a moment after its pictures change, so a palette
// that was empty when the program opened fills in without a reload.
let lookTimer: number | undefined;
function refreshLookSoon(slug: string) {
  window.clearTimeout(lookTimer);
  lookTimer = window.setTimeout(async () => {
    try {
      const look = await api.look(slug);
      const p = useApp.getState().program;
      if (!p || p.slug !== slug) return;
      if (JSON.stringify([p.colours, p.colourOrder, p.roles]) === JSON.stringify([look.colours, look.colourOrder, look.roles])) return;
      const next = { ...p, ...look };
      remember(next);
      useApp.setState({ program: next });
    } catch { /* the next change asks again */ }
  }, 800);
}

// Programs seen before open at once from their last copy (memory, then localStorage), and refresh behind it.
const seen = new Map<string, Program>();
const storeKey = (slug: string) => `iconlab.program.${slug}`;
function cachedProgram(slug: string): Program | null {
  const m = seen.get(slug);
  if (m) return m;
  try {
    const raw = localStorage.getItem(storeKey(slug));
    return raw ? (JSON.parse(raw) as Program) : null;
  } catch { return null; }
}
function forget(slug: string) {
  seen.delete(slug);
  try { localStorage.removeItem(storeKey(slug)); } catch { /* blocked */ }
}
function remember(p: Program) {
  seen.set(p.slug, p);
  try { localStorage.setItem(storeKey(p.slug), JSON.stringify(p)); } catch { /* full or blocked: memory still has it */ }
}

export const useApp = create<AppState>((set, get) => ({
  transport: null,
  programs: null,
  program: null,
  programError: null,
  media: new Map(),
  toast: null,

  async loadPrograms() {
    try { set({ programs: await api.programs() }); }
    catch (e) { get().say("Couldn't list programs: " + (e as Error).message, "error"); set({ programs: [] }); }
  },

  async loadProgram(slug) {
    wanted = slug;
    // Shown at once from what the page has (the open program, else its last copy), then always fetched again: the
    // engine may have changed it meanwhile (another program combined into it, pictures added while it was away).
    let cached: Program | null = get().program?.slug === slug ? get().program : null;
    if (!cached) {
      const c0 = cachedProgram(slug);
      cached = c0 ? { ...c0, media: c0.media.map((m) => withParts(slug, m)) } : null;
      set({ program: cached, programError: null, media: new Map((cached?.media ?? []).map((m) => [m.id, m])) });
    }
    try {
      const raw = await api.program(slug);
      if (wanted !== slug) return;   // moved on meanwhile
      remember(raw);
      const p = { ...raw, media: raw.media.map((m) => withParts(slug, m)) };
      set({ program: p, media: new Map(p.media.map((m) => [m.id, m])) });
    } catch (e) {
      // gone (combined into another program): its remembered copy goes too
      if (e instanceof ApiError && e.status === 404 && !e.routeMissing) {
        forget(slug);
        if (wanted === slug) set({ program: null, media: new Map(), programError: "This program isn't here any more: it may have been combined with another. Find it again in Find." });
      } else if (!cached) set({ programError: (e as Error).message });
    }
  },

  async setPicked(id, picked) {
    const p = get().program;
    if (!p) return;
    const apply = (val: boolean) => {
      const prog = get().program;
      if (!prog) return;
      const media = prog.media.map((m) => (m.id === id ? { ...m, picked: val } : m));
      set({ program: { ...prog, media }, media: new Map(media.map((m) => [m.id, m])) });
    };
    apply(picked);
    try {
      const m = await api.pick(p.slug, id, picked);
      if (m && (m as Media).id) get().upsertMedia(p.slug, m as Media);
    } catch (e) { apply(!picked); get().say("Couldn't change the pick: " + (e as Error).message, "error"); }
  },

  async setKind(id, kind) {
    const p = get().program;
    if (!p) return;
    try { get().upsertMedia(p.slug, await api.patchMediaFields(p.slug, id, { kind })); }
    catch (e) { get().say("Couldn't change the kind: " + (e as Error).message, "error"); }
  },

  removeMedia(program, ids) {
    const p = get().program;
    if (!p || p.slug !== program) return;
    const gone = new Set(ids);
    const media = p.media.filter((m) => !gone.has(m.id));
    set({ program: { ...p, media }, media: new Map(media.map((m) => [m.id, m])) });
    refreshLookSoon(program);
  },

  upsertMedia(program, raw) {
    const p = get().program;
    if (!p || p.slug !== program) return;
    const m = withParts(program, raw);
    const exists = p.media.some((x) => x.id === m.id);
    const media = exists ? p.media.map((x) => (x.id === m.id ? m : x)) : [...p.media, m];
    const next = { ...p, media };
    seen.set(next.slug, next);
    set({ program: next, media: new Map(media.map((x) => [x.id, x])) });
    refreshLookSoon(program);
  },

  async setHidden(id, hidden) {
    const p = get().program;
    if (!p) return;
    const before = get().media.get(id);
    if (!before) return;
    get().upsertMedia(p.slug, { ...before, hidden });
    if (hidden) get().say("Hidden: it won't be used in suggestions", "info", { label: "Undo", run: () => void get().setHidden(id, false) });
    try { get().upsertMedia(p.slug, await api.patchMediaFields(p.slug, id, { hidden })); }
    catch (e) { get().upsertMedia(p.slug, before); get().say("Couldn't " + (hidden ? "hide" : "unhide") + " it: " + (e as Error).message, "error"); }
  },

  say(text, kind = "info", action) {
    set({ toast: { text, kind, action } });
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => set({ toast: null }), kind === "error" || action ? 6000 : 2500);
  },
}));
