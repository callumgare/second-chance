// A small status of the on-device models in the status bar, opening to the list: each one's state, size and
// licence, and a Download button for those not here yet. Downloads also show in the activity panel.
import { useEffect, useRef, useState } from "react";
import { useModels } from "../state/models";

const mb = (n: number) => `${Math.round(n / 1e6)} MB`;

export function ModelsPill() {
  const { models, error, load, download } = useModels();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!open) return;
    void load();
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", down); document.addEventListener("keydown", key);
    return () => { document.removeEventListener("mousedown", down); document.removeEventListener("keydown", key); };
  }, [open, load]);
  if (!models) return null;
  const ready = models.filter((m) => m.state === "ready").length;
  const busy = models.filter((m) => m.state === "downloading" || m.state === "compiling");
  const failed = models.filter((m) => m.state === "failed").length;
  return (
    <div ref={ref} style={{ marginLeft: "auto", position: "relative" }}>
      <button className={"activity-pill" + (open ? " open" : "")} onClick={() => setOpen(!open)} aria-expanded={open} title="On-device models">
        {busy.length ? <span className="spin" /> : <span style={{ color: failed ? "var(--bad)" : ready === models.length ? "var(--ok)" : "var(--faint)" }}>◆</span>}
        Models {ready}/{models.length}{busy.length ? ` · downloading ${busy.map((m) => m.name).join(", ")}` : ""}
      </button>
      {open && (
        <div className="jobs-panel models-panel" role="dialog" aria-label="Models">
          <div className="ph">On-device models <small>downloaded when first needed, then kept</small></div>
          <div className="models-list">
            {error && <div className="notice bad">{error}</div>}
            {models.map((m) => (
              <div key={m.name} className="model">
                <span className={"mstate " + m.state}>{m.state === "downloading" || m.state === "compiling" ? <span className="spin" /> : m.state === "ready" ? "✓" : m.state === "failed" ? "⚠" : "·"}</span>
                <span className="col" style={{ gap: 1, minWidth: 0 }}>
                  <b className="wraps">{m.name}</b>
                  <span className="faint wraps" title={m.purpose}>{m.purpose}</span>
                  <span className="faint">{mb(m.size)} · {m.source ? <a href={m.source} target="_blank" rel="noreferrer">{m.licence}</a> : m.licence}</span>
                  {m.state === "failed" && m.error && <span style={{ color: "var(--bad)" }}>{m.error}</span>}
                  {m.state === "downloading" && m.progress != null && <span className="bar" style={{ marginTop: 3 }}><i style={{ width: `${Math.round(m.progress * 100)}%` }} /></span>}
                </span>
                <span>
                  {m.state === "ready" ? <span className="faint">ready</span>
                    : m.state === "downloading" ? <span className="faint">{Math.round((m.progress ?? 0) * 100)}%</span>
                    : m.state === "compiling" ? <span className="faint">compiling</span>
                    : <button className="btn small" onClick={() => void download(m.name)}>{m.state === "failed" ? "Retry" : "Download"}</button>}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
