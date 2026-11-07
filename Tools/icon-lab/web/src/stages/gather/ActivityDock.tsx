// The activity panel docked along the bottom of stage 2: this program's work (gathering, hi-res downloads,
// analysis, scans), running then queued then done, with progress and ETAs. Collapses to one line.
import type { Job } from "../../api";
import { useJobs } from "../../state/jobs";

export const fmtEta = (s?: number) => (s == null ? "" : s < 1 ? "<1 s" : s < 90 ? `${Math.round(s)} s` : `${Math.round(s / 60)} min`);

export function useProgramJobs(slug: string): Job[] {
  const jobs = useJobs((s) => s.jobs);
  return [...jobs.values()].filter((j) => !j.program || j.program === slug);
}

export function JobRow({ j }: { j: Job }) {
  return (
    <div className={"job " + j.state} title={j.detail ? `${j.title}\n${j.detail}` : j.title}>
      {j.state === "running" ? <span className="spin" /> : j.state === "queued" ? <span>·</span> : j.state === "failed" ? <span>⚠</span> : <span style={{ color: "var(--ok)" }}>✓</span>}
      <span className="jw">{j.title}{j.detail && <span className="faint"> · {j.detail}</span>}</span>
      {j.state === "done" ? <span className="took">{took(j)}</span> : <div className="bar"><i style={{ width: `${Math.round(j.progress * 100)}%` }} /></div>}
      <span className="eta">{j.state === "done" ? "done" : j.state === "failed" ? "failed" : fmtEta(j.eta) || `${Math.round(j.progress * 100)}%`}</span>
    </div>
  );
}

export function ActivityDock({ slug, collapsed, onToggle }: { slug: string; collapsed: boolean; onToggle(): void }) {
  const jobs = useProgramJobs(slug);
  const run = jobs.filter((j) => j.state === "running"), q = jobs.filter((j) => j.state === "queued");
  const failed = jobs.filter((j) => j.state === "failed"), done = jobs.filter((j) => j.state === "done").reverse().slice(0, 12);
  const eta = Math.max(0, ...run.map((j) => j.eta ?? 0), ...q.map((j) => j.eta ?? 0));
  const picksPending = [...run, ...q].filter((j) => j.group === "hires").length;
  return (
    <div className={"dock" + (collapsed ? " collapsed" : "")}>
      <button className="dock-h" onClick={onToggle} aria-expanded={!collapsed}>
        {run.length ? <span className="spin" /> : <span style={{ color: failed.length ? "var(--bad)" : "var(--ok)" }}>●</span>}
        <b>{run.length || q.length ? `${run.length} running · ${q.length} queued` : "Nothing running"}</b>
        {failed.length > 0 && <span style={{ color: "var(--bad)" }}>{failed.length} failed</span>}
        <span className="muted">{picksPending ? `Picked images ready in about ${fmtEta(eta)}` : run.length ? `about ${fmtEta(eta)} left` : "Everything picked is ready"}</span>
        <span className="muted" style={{ marginLeft: "auto" }}>{collapsed ? "Show ▴" : "Hide ▾"}</span>
      </button>
      {!collapsed && (
        <div className="dock-jobs">
          {([["Running", run], ["Queued", q], ["Failed", failed], ["Done", done]] as const).filter(([, l]) => l.length).map(([t, l]) => (
            <div key={t} style={{ display: "contents" }}>
              <div className="jobsec">{t}</div>
              {l.map((j) => <JobRow key={j.id} j={j} />)}
            </div>
          ))}
          {!jobs.length && <div className="faint" style={{ gridColumn: "1 / -1", padding: "4px 0" }}>Nothing yet. Picking an image fetches its largest copy and analyses it more deeply.</div>}
        </div>
      )}
    </div>
  );
}

/** How long a finished job took ("took 6 s"), or nothing when the engine didn't say. */
function took(j: Job): string {
  if (!j.started || !j.finished) return "";
  const s = Math.max(0, (Date.parse(j.finished) - Date.parse(j.started)) / 1000);
  return s < 1 ? "took under a second" : s < 90 ? `took ${Math.round(s)} s` : `took ${Math.round(s / 60)} min`;
}
