// On-device models (GET /api/models, `model` events): which are here, downloading or missing.
import { create } from "zustand";
import { api, type ModelStatus } from "../api";

type ModelsState = { models: ModelStatus[] | null; error: string | null; load(): Promise<void>; apply(m: ModelStatus): void; download(name: string): Promise<void> }

export const useModels = create<ModelsState>((set, get) => ({
  models: null,
  error: null,
  async load() {
    try { set({ models: await api.models(), error: null }); } catch (e) { set({ models: [], error: (e as Error).message }); }
  },
  apply(m) {
    const list = get().models ?? [];
    set({ models: list.some((x) => x.name === m.name) ? list.map((x) => (x.name === m.name ? m : x)) : [...list, m] });
  },
  async download(name) {
    try { get().apply(await api.downloadModel(name)); } catch (e) { set({ error: (e as Error).message }); }
  },
}));
