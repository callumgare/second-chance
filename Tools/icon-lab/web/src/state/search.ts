// Stage 1's search: the snapshots of each search as its sources answer (`search` events, or polling).
import { create } from "zustand";
import { api, type SearchSnapshot, type SourceInfo } from "../api";

type SearchState = {
  q: string
  current: string | null          // the search id the page shows
  snapshots: Record<string, SearchSnapshot>
  sources: SourceInfo[] | null
  error: string | null
  run(q: string): Promise<void>
  snapshot(s: SearchSnapshot): void
  loadSources(): Promise<void>
}

let pollTimer: number | undefined;

export const useSearch = create<SearchState>((set, get) => ({
  q: "",
  current: null,
  snapshots: {},
  sources: null,
  error: null,

  async run(q) {
    set({ q, error: null });
    window.clearInterval(pollTimer);
    if (!q.trim()) { set({ current: null }); return; }
    try {
      const { id } = await api.search(q.trim());
      if (get().q !== q) return;
      set({ current: id });
      // Events bring snapshots; poll as well in case they don't (a socket that dropped).
      pollTimer = window.setInterval(async () => {
        const cur = get().current;
        if (cur !== id) { window.clearInterval(pollTimer); return; }
        if (get().snapshots[id]?.done) { window.clearInterval(pollTimer); return; }
        try { get().snapshot(await api.searchSnapshot(id)); } catch { /* next time */ }
      }, 1500);
    } catch (e) {
      set({ error: (e as Error).message });
    }
  },

  snapshot(s) {
    set((st) => ({ snapshots: { ...st.snapshots, [s.id]: s } }));
  },

  async loadSources() {
    try { set({ sources: await api.sources() }); } catch (e) { set({ sources: [], error: (e as Error).message }); }
  },
}));
