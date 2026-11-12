// The status bar's activity pill, which opens the jobs panel: running, queued and done, with progress and ETA.
import { useEffect, useRef, useState } from "react";
import type { Job } from "../api";
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
            {l.map((j) => (
              <div key={j.id} className={"job " + j.state} title={j.detail ?? j.title}>
                {j.state === "running" ? <span className="spin" /> : j.state === "queued" ? <span>·</span> : j.state === "failed" ? <span>⚠</span> : <span style={{ color: "var(--ok)" }}>✓</span>}
                <span className="jw">{j.title}{j.detail && <span className="faint"> · {j.detail}</span>}</span>
                {j.state === "done" ? <span className="took">{took(j)}</span> : <div className="bar"><i style={{ width: `${Math.round(j.progress * 100)}%` }} /></div>}
                <span className="eta">{j.state === "done" ? "done" : j.state === "failed" ? "failed" : fmtEta(j.eta) || `${Math.round(j.progress * 100)}%`}</span>
              </div>
            ))}
          </div>
        ))}
        {!jobs.length && <div className="empty">Nothing running. Renders, downloads and analysis show here.</div>}
      </div>
    </div>
  );
}

/** How long a finished job took ("took 6 s"), or nothing when the engine didn't say. */
function took(j: Job): string {
  if (!j.started || !j.finished) return "";
  const s = Math.max(0, (Date.parse(j.finished) - Date.parse(j.started)) / 1000);
  return s < 1 ? "took under a second" : s < 90 ? `took ${Math.round(s)} s` : `took ${Math.round(s / 60)} min`;
}
