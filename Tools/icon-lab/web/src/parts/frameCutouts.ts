// "Find cut-outs" on a video frame: starts the engine's job, tracks it per media/frame (so a row's spinner survives
// the inspector moving on), and says "None found in frame n" when the media that comes back has none for it.
import { create } from "zustand";
import { api, type Media } from "../api";
import { useApp } from "../state/app";
import { useJobs } from "../state/jobs";

type Tracked = { media: string; frame: string; job: string | null; done: boolean; start: Media | undefined };
export const useFrameCutouts = create<{ running: Record<string, Tracked> }>(() => ({ running: {} }));
const keyOf = (media: string, frame: string) => `${media}/${frame}`;

export const frameCutoutsBusy = (s: { running: Record<string, Tracked> }, media: string, frame: string) => !!s.running[keyOf(media, frame)];

function finish(k: string, failed?: string) {
  const t = useFrameCutouts.getState().running[k];
  if (!t) return;
  useFrameCutouts.setState((s) => { const running = { ...s.running }; delete running[k]; return { running }; });
  const n = t.frame.replace(/^frame-/, "");
  if (failed) { useApp.getState().say(`Couldn't find cut-outs in frame ${n}: ${failed}`, "error"); return; }
  const m = useApp.getState().media.get(t.media);
  if (m && !(m.parts ?? []).some((p) => p.frame === t.frame)) useApp.getState().say(`None found in frame ${n}`, "info");
}

// A job's end, then the media event that carries its parts: whichever comes second settles it.
useJobs.subscribe((s) => {
  for (const [k, t] of Object.entries(useFrameCutouts.getState().running)) {
    const j = t.job ? s.jobs.get(t.job) : undefined;
    if (!j || t.done) continue;
    if (j.state === "failed") finish(k, j.detail ?? "the job failed");
    else if (j.state === "done") {
      useFrameCutouts.setState((st) => ({ running: { ...st.running, [k]: { ...t, done: true } } }));
      const before = useApp.getState().media.get(t.media);
      // Its media event came first: settle now.
      if (before !== t.start) { finish(k); continue; }
      // The media event normally follows; if it never does, settle on what's there.
      const unsub = useApp.subscribe((a) => { if (a.media.get(t.media) !== before) { unsub(); clearTimeout(timer); finish(k); } });
      const timer = setTimeout(() => { unsub(); finish(k); }, 4000);
    }
  }
});

export async function findFrameCutouts(m: Media, frame: string) {
  const slug = useApp.getState().program?.slug;
  if (!slug) return;
  const k = keyOf(m.id, frame);
  useFrameCutouts.setState((s) => ({ running: { ...s.running, [k]: { media: m.id, frame, job: null, done: false, start: useApp.getState().media.get(m.id) } } }));
  try {
    const { job } = await api.findFrameCutouts(slug, m.id, frame);
    useFrameCutouts.setState((s) => ({ running: { ...s.running, [k]: { ...s.running[k], job } } }));
    // The job may have ended before we knew its id.
    const j = useJobs.getState().jobs.get(job);
    if (j) useJobs.setState({ jobs: new Map(useJobs.getState().jobs) });
  } catch (e) { finish(k, (e as Error).message); }
}
