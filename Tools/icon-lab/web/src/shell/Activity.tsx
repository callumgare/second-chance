// The status bar's activity pill, which opens the jobs panel: running, queued and done, with progress and ETA, and
// Cancel on each running or queued job.
import { useEffect, useRef, useState } from "react";
import type { Job } from "../api";
import { JobRow } from "../stages/gather/ActivityDock";
import { useJobs } from "../state/jobs";

const fmtEta = (s?: number) => (s == null ? "" : s < 1 ? "<1 s" : s < 90 ? `${Math.round(s)} s` : `${Math.round(s / 60)} min`);

export function ActivityPill() {
  const jobs = useJobs((s) => s.jobs);
  const connection = useJobs((s) => s.connection);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const list = [...jobs.values()];
  const running = list.filter((j) => j.state === "running");
  const queued = list.filter((j) => j.state === "queued");
  const failed = list.filter((j) => j.state === "failed");
  const eta = Math.max(0, ...running.map((j) => j.eta ?? 0), ...queued.map((j) => j.eta ?? 0));

  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", down); document.addEventListener("keydown", key);
    return () => { document.removeEventListener("mousedown", down); document.removeEventListener("keydown", key); };
  }, [open]);

  const label = connection !== "open" ? (connection === "connecting" ? "Connecting to the engine…" : "Engine disconnected, retrying…")
    : running.length || queued.length ? `${running.length} running · ${queued.length} queued` : failed.length ? `${failed.length} failed` : "Idle";

  return (
    <div ref={ref}>
      <button className={"activity-pill" + (open ? " open" : "")} onClick={() => setOpen(!open)} aria-expanded={open}>
        {running.length || connection === "connecting" ? <span className="spin" /> : <span style={{ color: connection === "open" ? (failed.length ? "var(--bad)" : "var(--ok)") : "var(--warn)" }}>●</span>}
        {label}
        {running.length > 0 && eta > 0 && <span className="faint">· about {fmtEta(eta)}</span>}
        <span className="faint">{open ? "▾" : "▴"}</span>
      </button>
      {open && <JobsPanel jobs={list} />}
    </div>
  );
}

function JobsPanel({ jobs }: { jobs: Job[] }) {
  const sections: [string, Job[]][] = [
    ["Running", jobs.filter((j) => j.state === "running")],
    ["Queued", jobs.filter((j) => j.state === "queued")],
    ["Failed", jobs.filter((j) => j.state === "failed")],
    ["Done", jobs.filter((j) => j.state === "done").reverse().slice(0, 20)],
  ];
  return (
    <div className="jobs-panel" role="dialog" aria-label="Activity">
      <div className="ph">Activity <small>{jobs.length ? `${jobs.length} jobs` : "nothing yet"}</small></div>
      <div className="jobs">
        {sections.filter(([, l]) => l.length).map(([t, l]) => (
          <div key={t} style={{ display: "contents" }}>
            <div className="jobsec">{t}</div>
            {l.map((j) => <JobRow key={j.id} j={j} />)}
          </div>
        ))}
        {!jobs.length && <div className="empty">Nothing running. Renders, downloads and analysis show here.</div>}
      </div>
    </div>
  );
}

