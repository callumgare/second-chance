// "Design icon →" while picked images are still being fetched or analysed: wait (and go on by itself when
// they're ready), continue now, or keep picking.
import { useEffect } from "react";
import type { Media } from "../../api";
import { fmtEta, JobRow, useProgramJobs } from "./ActivityDock";

export function WaitingDialog({ slug, pending, onContinue, onClose }: { slug: string; pending: Media[]; onContinue(): void; onClose(): void }) {
  const jobs = useProgramJobs(slug).filter((j) => j.group === "hires" && (j.state === "running" || j.state === "queued"));
  const eta = Math.max(0, ...jobs.map((j) => j.eta ?? 0));
  const progress = jobs.length ? jobs.reduce((s, j) => s + j.progress, 0) / jobs.length : 1;
  useEffect(() => { if (!pending.length) onContinue(); }, [pending.length, onContinue]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [onClose]);
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dlg narrow" role="dialog" aria-label="Getting your picks ready">
        <header>
          <h2>Getting your picks ready</h2>
          <div className="row"><div className="bar" style={{ flex: 1 }}><i style={{ width: `${Math.round(progress * 100)}%` }} /></div><span className="muted">{eta ? `about ${fmtEta(eta)}` : "almost there"}</span></div>
        </header>
        <div className="dlg-body">
          <p style={{ margin: 0 }}>Designing starts on its own once {pending.length === 1 ? "this finishes" : `these ${pending.length} finish`}:</p>
          {jobs.length ? jobs.slice(0, 6).map((j) => <JobRow key={j.id} j={j} />) : pending.map((m) => <div key={m.id} className="job running"><span className="spin" /><span className="jw">{m.name}</span><span /><span className="eta">{m.hires}</span></div>)}
          <p className="faint" style={{ margin: 0 }}>If you continue now, suggestions use the smaller copies and update as the rest arrive.</p>
        </div>
        <footer>
          <button className="btn" style={{ marginRight: "auto" }} onClick={onClose}>Keep picking</button>
          <button className="btn" onClick={onContinue}>Continue now</button>
          <button className="btn primary" disabled><span className="spin" /> Continuing when ready…</button>
        </footer>
      </div>
    </div>
  );
}
