// What the whole app shares: which API it talks to, the programs, and the open program with its media.
import { create } from "zustand";
import { api, type Media, type Program, type ProgramSummary } from "../api";
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
    if (get().program?.slug === slug) return;
    const c0 = cachedProgram(slug);
    const cached = c0 ? { ...c0, media: c0.media.map((m) => withParts(slug, m)) } : c0;
    set({ program: cached, programError: null, media: new Map((cached?.media ?? []).map((m) => [m.id, m])) });
    try {
      const raw = await api.program(slug);
      if (get().program && get().program?.slug !== slug) return;   // moved on meanwhile
      remember(raw);
      const p = { ...raw, media: raw.media.map((m) => withParts(slug, m)) };
      set({ program: p, media: new Map(p.media.map((m) => [m.id, m])) });
    } catch (e) {
      if (!cached) set({ programError: (e as Error).message });
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
