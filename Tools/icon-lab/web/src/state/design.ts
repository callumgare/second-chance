// Stage 3's state: the document being edited (with undo), the history of documents, pins, suggestions and
// the view's toggles. Edits go through `edit`, which keeps pins frozen: editing a pinned doc forks it first.
import { create } from "zustand";
import { api, type Appearance, type Doc, type Suggestion, type SuggestionParams, type Treatment } from "../api";
import { clone, findGroup, findLayer, forkDoc, newDoc, visualKey } from "../lib/doc";
import { useApp } from "./app";
import { applyLocally } from "./adjustLocal";
import { resources } from "../render/resources";
import { sketchRequests } from "../render/sketch";

export type Selection = { kind: "layer"; id: string } | { kind: "layers"; ids: string[] } | { kind: "group"; id: string } | { kind: "icon" } | null;

/** The layers a selection covers: one, several, or a group's (front first). */
export function selectedLayerIds(doc: Doc | null, sel: Selection): string[] {
  if (!doc || !sel) return [];
  if (sel.kind === "layer") return [sel.id];
  if (sel.kind === "layers") return sel.ids;
  if (sel.kind === "group") return findGroup(doc, sel.id)?.layers.map((l) => l.id) ?? [];
  return [];
}

/** A selection of these layers: none is the icon, one a layer, more a multiple selection. */
export function layersSel(ids: string[]): Selection {
  const u = [...new Set(ids)];
  return u.length === 0 ? { kind: "icon" } : u.length === 1 ? { kind: "layer", id: u[0] } : { kind: "layers", ids: u };
}
export type Backdrop = "desktop" | "grey" | "dark";

const HISTORY = 200;

type DesignState = {
  slug: string | null
  loading: boolean
  doc: Doc | null
  docs: Record<string, Doc> // every doc we know of (history)
  pins: string[]
  sel: Selection
  appearance: Appearance
  backdrop: Backdrop
  /** The canvas shows ictool's real render ("Final") rather than the sketch ("Preview"). Any edit goes back to Preview. */
  glass: boolean
  /** Suggestions as real renders ("Final") or sketches ("Preview"). Adjusting goes back to Preview. */
  finalSuggestions: boolean
  grid: boolean
  past: Doc[]
  future: Doc[]
  transientBase: Doc | null
  saving: "idle" | "pending" | "saving" | "saved" | "error"

  params: SuggestionParams
  treatments: Treatment[]
  enabled: string[] | null // treatments to show; null = all
  suggestions: Suggestion[]
  suggLoading: boolean
  galleryOpen: boolean

  keep: Record<string, boolean>
  /** Designs saved this session (for the Review step's summary). */
  savedIds: string[]

  load(slug: string): Promise<void>
  select(sel: Selection): void
  /** Applies `fn` to a copy of the doc. `transient` edits (a drag) don't each make an undo step: the step is
   *  made by `commit` when the gesture ends. */
  edit(fn: (d: Doc) => void, opts?: { transient?: boolean }): void
  commit(): void
  undo(): void
  redo(): void
  replaceDoc(d: Doc): void
  pinCurrent(): Promise<void>
  unpin(id: string): Promise<void>
  openPin(id: string): void
  openSuggestion(s: Suggestion): Promise<void>
  setParams(p: Partial<SuggestionParams>): void
  resetParams(): void
  setEnabled(keys: string[] | null): void
  refreshSuggestions(): Promise<void>
  set(p: Partial<Pick<DesignState, "appearance" | "backdrop" | "glass" | "finalSuggestions" | "grid" | "galleryOpen" | "keep" | "saving" | "savedIds">>): void
}

let suggSeq = 0;
/** The engine's latest suggestions, which "adjust all" moves from in the page. */
let baseSuggestions: Suggestion[] = [];

export const useDesign = create<DesignState>((set, get) => ({
  slug: null,
  loading: false,
  doc: null,
  docs: {},
  pins: [],
  sel: null,
  appearance: "light",
  backdrop: "desktop",
  glass: false,
  finalSuggestions: false,
  grid: false,
  past: [],
  future: [],
  transientBase: null,
  saving: "idle",
  params: {},
  treatments: [],
  enabled: null,
  suggestions: [],
  suggLoading: false,
  galleryOpen: false,
  keep: {},
  savedIds: [],

  async load(slug) {
    if (get().slug === slug && get().doc) return;
    set({ slug, loading: true, doc: null, docs: {}, pins: [], past: [], future: [], sel: null, suggestions: [], params: loadParams(slug), keep: {}, savedIds: [] });
    const [state, treatments] = await Promise.all([
      api.docs(slug).catch(() => ({ docs: [], pins: [], current: null })),
      api.treatments().catch(() => [] as Treatment[]),
    ]);
    if (get().slug !== slug) return;
    const docs = Object.fromEntries(state.docs.map((d) => [d.id, d]));
    set({ docs, pins: state.pins, treatments, keep: Object.fromEntries(state.pins.map((p) => [p, true])) });
    let doc = state.current ? docs[state.current] : null;
    if (doc) {
      // Edit at once; suggestions fill in when they come.
      set({ doc, loading: false, sel: firstLayerSel(doc) });
      void get().refreshSuggestions();
      return;
    }
    await get().refreshSuggestions();
    if (get().slug !== slug) return;
    if (!doc) {
      const first = get().suggestions[0];
      if (first) { await get().openSuggestion(first); set({ loading: false, past: [] }); return; }
      doc = newDoc(slug);
    }
    set({ doc, loading: false, sel: firstLayerSel(doc) });
  },

  select(sel) { set({ sel }); },

  edit(fn, opts) {
    const s = get();
    if (!s.doc) return;
    let base = s.doc;
    let next = clone(base);
    // A pin never changes: the first edit after loading a pin continues on a copy.
    if (s.pins.includes(base.id)) {
      next = forkDoc(base);
    }
    fn(next);
    if (visualKey(next) === visualKey(base) && next.name === base.name) return;
    if (opts?.transient) {
      set({ doc: next, transientBase: s.transientBase ?? base, future: [], glass: false });
    } else {
      const from = s.transientBase ?? base;
      set({ doc: next, transientBase: null, past: [...s.past, from].slice(-HISTORY), future: [], saving: "pending", glass: false });
    }
  },

  commit() {
    const s = get();
    if (!s.transientBase || !s.doc) return;
    set({ past: [...s.past, s.transientBase].slice(-HISTORY), transientBase: null, future: [], saving: "pending" });
  },

  undo() {
    const s = get();
    if (!s.past.length || !s.doc) return;
    const prev = s.past[s.past.length - 1];
    set({ doc: prev, past: s.past.slice(0, -1), future: [s.doc, ...s.future], transientBase: null, sel: keepSel(prev, s.sel), saving: "pending", glass: false });
  },

  redo() {
    const s = get();
    if (!s.future.length || !s.doc) return;
    const next = s.future[0];
    set({ doc: next, future: s.future.slice(1), past: [...s.past, s.doc], transientBase: null, sel: keepSel(next, s.sel), saving: "pending", glass: false });
  },

  replaceDoc(d) {
    const s = get();
    set({ doc: d, past: s.doc ? [...s.past, s.doc].slice(-HISTORY) : s.past, future: [], transientBase: null, sel: keepSel(d, s.sel) ?? firstLayerSel(d), saving: "pending", glass: false });
  },

  async pinCurrent() {
    const s = get();
    if (!s.doc || !s.slug) return;
    const snap = clone(s.doc);
    // Pinned at once, so an edit made while the requests are out forks rather than changing the pin.
    set({ pins: [...s.pins, snap.id], docs: { ...s.docs, [snap.id]: snap }, keep: { ...s.keep, [snap.id]: true } });
    try {
      const { pins } = await (useApp.getState().transport === "mock" ? api.putDoc(s.slug, snap).then(() => api.pin(s.slug!, snap.id)) : api.pinDoc(s.slug, snap));
      set({ pins });
      useApp.getState().say(`Pinned “${snap.name}”`);
    } catch (e) {
      set({ pins: get().pins.filter((p) => p !== snap.id) });
      useApp.getState().say("Couldn't pin: " + (e as Error).message, "error");
    }
  },

  async unpin(id) {
    const s = get();
    if (!s.slug) return;
    try {
      const { pins } = await api.unpin(s.slug, id);
      set({ pins });
    } catch (e) { useApp.getState().say("Couldn't unpin: " + (e as Error).message, "error"); }
  },

  openPin(id) {
    const d = get().docs[id];
    if (d) get().replaceDoc(clone(d));
  },

  async openSuggestion(sugg) {
    const s = get();
    if (!s.slug) return;
    const source = clone(sugg.doc);
    const copy = forkDoc(source);
    get().replaceDoc(copy);
    set({ docs: { ...get().docs, [source.id]: source, [copy.id]: copy } });
    try {
      await api.putDoc(s.slug, source);
    } catch (e) { useApp.getState().say("Couldn't save the suggestion: " + (e as Error).message, "error"); }
  },

  setParams(p) {
    const params = { ...get().params, ...p };
    for (const k of Object.keys(params) as (keyof SuggestionParams)[]) if (params[k] === undefined || params[k] === "") delete params[k];
    // At once, in the page: every suggestion moved to the new params; the engine's own docs follow.
    const app = useApp.getState();
    const roles = JSON.stringify(params.roles ?? {}) === JSON.stringify(get().params.roles ?? {});
    const local = roles ? baseSuggestions.map((s) => applyLocally(s, params, app.program?.colours ?? {}, app.media)) : get().suggestions;
    set({ params, finalSuggestions: false, suggestions: local });
    if (get().slug) saveParams(get().slug!, params);
    scheduleSuggestions();
  },

  resetParams() {
    set({ params: {}, finalSuggestions: false });
    if (get().slug) saveParams(get().slug!, {});
    scheduleSuggestions();
  },

  setEnabled(enabled) { set({ enabled, finalSuggestions: false }); scheduleSuggestions(); },

  async refreshSuggestions() {
    const s = get();
    if (!s.slug) return;
    const seq = ++suggSeq;
    set({ suggLoading: true });
    try {
      const list = await api.suggestions(s.slug, s.params, s.enabled ?? undefined);
      if (seq !== suggSeq) return;
      // Swap the engine's docs in once their pictures are here, so the tiles don't flash.
      const media = useApp.getState().media;
      await Promise.race([
        Promise.all(list.map((x) => resources.ensure(sketchRequests(x.doc, 96, media)))),
        new Promise((r) => setTimeout(r, 2500)),
      ]);
      if (seq !== suggSeq) return;
      baseSuggestions = list;
      set({ suggestions: list, suggLoading: false });
    } catch (e) {
      if (seq === suggSeq) set({ suggLoading: false });
      useApp.getState().say("Couldn't make suggestions: " + (e as Error).message, "error");
    }
  },

  set(p) { set(p); },
}));

let suggTimer: number | undefined;
function scheduleSuggestions() {
  window.clearTimeout(suggTimer);
  suggTimer = window.setTimeout(() => void useDesign.getState().refreshSuggestions(), 250);
}

function firstLayerSel(d: Doc): Selection {
  const l = d.groups.find((g) => g.layers.length)?.layers[0];
  return l ? { kind: "layer", id: l.id } : { kind: "icon" };
}

function keepSel(d: Doc, sel: Selection): Selection {
  if (!sel) return null;
  if (sel.kind === "layer") return findLayer(d, sel.id) ? sel : firstLayerSel(d);
  if (sel.kind === "group") return findGroup(d, sel.id) ? sel : firstLayerSel(d);
  if (sel.kind === "layers") { const ids = sel.ids.filter((id) => findLayer(d, id)); return ids.length ? layersSel(ids) : firstLayerSel(d); }
  return sel;
}

// "Adjust all" settings are a per-program preference: remembered in this browser only.
function loadParams(slug: string): SuggestionParams {
  try { return JSON.parse(localStorage.getItem("iconlab-params:" + slug) ?? "{}"); } catch { return {}; }
}
function saveParams(slug: string, p: SuggestionParams) {
  try { localStorage.setItem("iconlab-params:" + slug, JSON.stringify(p)); } catch { /* unavailable */ }
}

/** Does the current doc look the same as a pinned one? */
export function pinnedMatch(s: Pick<DesignState, "doc" | "docs" | "pins">): string | null {
  if (!s.doc) return null;
  const k = visualKey(s.doc);
  return s.pins.find((p) => s.docs[p] && visualKey(s.docs[p]) === k) ?? null;
}
