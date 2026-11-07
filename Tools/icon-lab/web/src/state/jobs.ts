// The engine's jobs, kept from its event stream (and /api/jobs for a page that connects late).
import { create } from "zustand";
import { api, currentTransport, onLocal, type EngineEvent, type Job } from "../api";
import { useApp } from "./app";
import { applyScanLine } from "./scans";
import { useSearch } from "./search";
import { useModels } from "./models";

type JobsState = {
  jobs: Map<string, Job>
  connection: "connecting" | "open" | "closed"
  finishedAt: Map<string, number>
}

export const useJobs = create<JobsState>(() => ({ jobs: new Map(), connection: "connecting", finishedAt: new Map() }));

type RenderListener = (key: string, url: string) => void;
const renderListeners = new Set<RenderListener>();
export function onRenderEvent(f: RenderListener) { renderListeners.add(f); return () => { renderListeners.delete(f); }; }

function apply(e: EngineEvent) {
  if (e.type === "job") {
    useJobs.setState((s) => {
      const jobs = new Map(s.jobs);
      jobs.set(e.job.id, e.job);
      const finishedAt = new Map(s.finishedAt);
      if ((e.job.state === "done" || e.job.state === "failed") && !finishedAt.has(e.job.id)) finishedAt.set(e.job.id, Date.now());
      // Keep the done list short.
      const done = [...jobs.values()].filter((j) => j.state === "done");
      if (done.length > 40) for (const j of done.slice(0, done.length - 40)) { jobs.delete(j.id); finishedAt.delete(j.id); }
      return { jobs, finishedAt };
    });
  } else if (e.type === "media") {
    useApp.getState().upsertMedia(e.program, e.media);
  } else if (e.type === "render") {
    renderListeners.forEach((f) => f(e.key, e.url));
  } else if (e.type === "search") {
    const { type: _t, ...snap } = e;
    useSearch.getState().snapshot(snap);
  } else if (e.type === "scan") {
    applyScanLine(e.program, e.scan, e.event);
  } else if (e.type === "media-removed") {
    useApp.getState().removeMedia(e.program, e.ids);
  } else if (e.type === "model") {
    useModels.getState().apply(e.model);
  }
}

let stop: (() => void) | null = null;
let stopLocal: (() => void) | null = null;
export function connectEvents() {
  stop?.();
  stopLocal?.();
  stopLocal = onLocal(apply);
  stop = currentTransport().events(apply, (connection) => {
    useJobs.setState({ connection });
    if (connection === "open") {
      api.jobs().then((list) => list.forEach((job) => apply({ type: "job", job }))).catch(() => { /* fine: events will fill in */ });
    }
  });
}
