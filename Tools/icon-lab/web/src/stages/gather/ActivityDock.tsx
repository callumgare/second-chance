// The activity panel docked along the bottom of stage 2: this program's work (gathering, hi-res downloads,
// analysis, scans), running then queued then failed then done, with progress and ETAs. Resized by its top edge, as
// Design's suggestions are, and collapsed to one line. Every running or queued job can be cancelled (what it had
// already found is kept); a scan's job opens to its tree.
import { api, type Job } from "../../api";
import { useApp } from "../../state/app";
import { useJobs } from "../../state/jobs";
import { useScans } from "../../state/scans";
import { ResizeHandle } from "../../components/ResizeHandle";
import { ScanTreeBody } from "./ScanTree";

/** The engine's lane a job runs in (`Jobs.Lane`): a queued job waits only for running ones in its own lane. */
const laneOf = (group?: string) => (group === "gather" || group === "match" || group === "sources" ? "network" : group === "scan" ? "files" : "compute");

/** Other programs' running jobs that this program's queued ones wait for (those in the same lanes), when none of its
 *  own is running: what holds it up, and when the first of them should be done. */
function useHeldBy(slug: string, queued: Job[], running: Job[]) {
  const all = useJobs((s) => s.jobs);
  const programs = useApp((s) => s.programs);
  if (running.length || !queued.length) return null;
  const lanes = new Set(queued.map((j) => laneOf(j.group)));
  const others = [...all.values()].filter((j) => j.state === "running" && j.program && j.program !== slug && lanes.has(laneOf(j.group)));
  if (!others.length) return null;
  const names = [...new Set(others.map((j) => programs?.find((p) => p.slug === j.program)?.title ?? j.program!))];
  const etas = others.map((j) => j.eta).filter((e): e is number => e != null);
  const progress = others.reduce((n, j) => n + j.progress, 0) / others.length;
  return { count: others.length, names, soonest: etas.length ? Math.min(...etas) : null, progress };
}

export const fmtEta = (s?: number) => (s == null ? "" : s < 1 ? "<1 s" : s < 90 ? `${Math.round(s)} s` : `${Math.round(s / 60)} min`);

export function useProgramJobs(slug: string): Job[] {
  const jobs = useJobs((s) => s.jobs);
  return [...jobs.values()].filter((j) => !j.program || j.program === slug);
}

const cancel = (j: Job) => api.cancelJob(j.id)
  .then((r) => { if (!r.cancelled) useApp.getState().say(`“${j.title}” had already finished`); })
  .catch((e) => useApp.getState().say(`Couldn't cancel “${j.title}”: ${(e as Error).message}`, "error"));

/** A job's line: its state, title and detail, progress or how long it took, and Cancel while it's running or
 *  queued. A scan's job (`expandable`) opens to its tree. */
export function JobRow({ j, expandable }: { j: Job; expandable?: boolean }) {
  const open = useScans((s) => (j.scan ? !!s.open[j.scan] : false));
  const live = j.state === "running" || j.state === "queued";
  const canOpen = expandable && !!j.scan;
  return (
    <>
      <div className={"job " + j.state + (canOpen ? " has-tree" : "")} title={j.detail ? `${j.title}\n${j.detail}` : j.title}>
        {j.state === "running" ? <span className="spin" /> : j.state === "queued" ? <span>·</span> : j.state === "failed" ? <span>{j.detail?.startsWith("cancelled") ? "–" : "⚠"}</span> : <span style={{ color: "var(--ok)" }}>✓</span>}
        <span className="jw">
          {canOpen
            ? <button className="linkish job-open" aria-expanded={open} onClick={() => useScans.getState().setOpen(j.scan!, !open)}>{open ? "▾" : "▸"} {j.title}</button>
            : j.title}
          {j.detail && <span className="faint"> · {j.detail}</span>}
        </span>
        {j.state === "done" ? <span className="took">{took(j)}</span> : <div className="bar"><i style={{ width: `${Math.round(j.progress * 100)}%` }} /></div>}
        <span className="eta">{j.state === "done" ? "done" : j.state === "failed" ? (j.detail?.startsWith("cancelled") ? "cancelled" : "failed") : fmtEta(j.eta) || `${Math.round(j.progress * 100)}%`}</span>
        {live ? <button className="icon-btn job-cancel" onClick={() => void cancel(j)} aria-label={`Cancel ${j.title}`} title="Cancel (what it found so far is kept)">×</button> : <span />}
      </div>
      {canOpen && open && <div className="job-tree"><ScanTreeBody scanId={j.scan!} job={j} /></div>}
    </>
  );
}

export const DOCK_H = 236, DOCK_MIN = 90, DOCK_BAR = 34;

/** Collapsed is just its smallest height (its bar alone): dragged down to it, or toggled to it and back. */
export function ActivityDock({ slug, collapsed, onToggle, height, maxHeight, onResize, onResizing }: {
  slug: string; collapsed: boolean; onToggle(): void; height: number; maxHeight: number; onResize(h: number): void; onResizing?(v: boolean): void
}) {
  const jobs = useProgramJobs(slug);
  const run = jobs.filter((j) => j.state === "running"), q = jobs.filter((j) => j.state === "queued");
  const failed = jobs.filter((j) => j.state === "failed"), done = jobs.filter((j) => j.state === "done").reverse();
  const eta = Math.max(0, ...run.map((j) => j.eta ?? 0), ...q.map((j) => j.eta ?? 0));
  const picksPending = [...run, ...q].filter((j) => j.group === "hires").length;
  const live = [...run, ...q];
  const cancelAll = () => { for (const j of live) void cancel(j); };
  const held = useHeldBy(slug, q, run);
  const heldText = held && `${held.count} running for ${held.names.length === 1 ? held.names[0] : `${held.names.length} other programs`}`;
  return (
    <div className={"dock" + (collapsed ? " collapsed" : "")}>
      <ResizeHandle edge label="Resize the activity panel" height={height} min={DOCK_MIN} max={maxHeight} reset={DOCK_H} collapsed={DOCK_BAR}
        onResize={onResize} onResizing={onResizing} />
      <div className="dock-h">
        <button className="dock-toggle" onClick={onToggle} aria-expanded={!collapsed}>
          {run.length ? <span className="spin" /> : <span style={{ color: failed.length ? "var(--bad)" : "var(--ok)" }}>●</span>}
          <b>{run.length || q.length ? `${run.length} running · ${q.length} queued` : "Nothing running"}</b>
          {held && <span className="muted">waiting: {heldText}</span>}
          {failed.length > 0 && <span style={{ color: "var(--bad)" }}>{failed.length} failed or cancelled</span>}
          <span className="muted">{picksPending ? `Picked images ready in about ${fmtEta(eta)}` : run.length ? `about ${fmtEta(eta)} left` : "Everything picked is ready"}</span>
        </button>
        {live.length > 1 && <button className="btn small ghost" onClick={cancelAll} title="Cancel every running and queued job: what they found so far is kept">Cancel all</button>}
        <button className="btn small ghost" onClick={onToggle} aria-expanded={!collapsed}>{collapsed ? "⌃ Expand" : "⌄ Collapse"}</button>
      </div>
      {!collapsed && (
        <div className="dock-jobs">
          {held && (
            <>
              <div className="jobsec">Running</div>
              <div className="held-by" title={held.names.join(", ")}>
                <span className="spin" /> {heldText}{held.names.length > 1 ? ` (${held.names.join(", ")})` : ""}, which this program's queued work waits for.
                {" "}{held.soonest != null ? `The first should be done in about ${fmtEta(held.soonest)}.`
                  : held.progress >= 0.01 ? `They're ${Math.round(held.progress * 100)}% done on average.` : "They've only just started."}
              </div>
            </>
          )}
          {([["Running", run], ["Queued", q], ["Failed or cancelled", failed], ["Done", done]] as const).filter(([, l]) => l.length).map(([t, l]) => (
            <div key={t} style={{ display: "contents" }}>
              <div className="jobsec">{t}</div>
              {l.map((j) => <JobRow key={j.id} j={j} expandable />)}
            </div>
          ))}
          {!jobs.length && <div className="faint" style={{ gridColumn: "1 / -1", padding: "4px 0" }}>Nothing yet. Picking an image fetches its largest copy and analyses it more deeply.</div>}
        </div>
      )}
    </div>
  );
}

/** How long a finished job took ("took 6 s"), or nothing when the engine didn't say. */
export function took(j: Job): string {
  if (!j.started || !j.finished) return "";
  const s = Math.max(0, (Date.parse(j.finished) - Date.parse(j.started)) / 1000);
  return s < 1 ? "took under a second" : s < 90 ? `took ${Math.round(s)} s` : `took ${Math.round(s / 60)} min`;
}
