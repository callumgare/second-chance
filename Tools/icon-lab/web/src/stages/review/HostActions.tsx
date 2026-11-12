// What the host offers for pinned designs: trying one on a built wrapp (its .icns put in the app, so the Dock and
// Finder show it). Saving to the program's bundle is part of Review's Save. docs/api.md has the routes.
import { useEffect, useState } from "react";
import { api, type Doc, type HostInfo, type Wrapp } from "../../api";
import { IconArt } from "../../components/IconArt";

export function useHost(): HostInfo | null {
  const [host, setHost] = useState<HostInfo | null>(null);
  useEffect(() => { void api.host().then(setHost); }, []);
  return host;
}

/** Choose a built wrapp and put the design on it. */
export function TryOnWrapp({ slug, doc, onClose }: { slug: string; doc: Doc; onClose(): void }) {
  const [wrapps, setWrapps] = useState<Wrapp[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api.wrapps().then(setWrapps).catch((e) => { setWrapps([]); setError((e as Error).message); }); }, []);
  const tryOn = async (w: Wrapp) => {
    setBusy(w.path); setError(null);
    try {
      await api.tryIcon(slug, doc.id, w.path);
      setDone(w.name);
    } catch (e) { setError((e as Error).message); } finally { setBusy(null); }
  };
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dlg" role="dialog" aria-label="Try on a built app">
        <header><h2>Try “{doc.name}” on a built app</h2></header>
        <div className="saved-list">
          {wrapps === null && <div className="empty"><span className="spin" /></div>}
          {wrapps?.length === 0 && !error && <div className="empty">No built apps here. Build one first (they're kept in built-apps/).</div>}
          {wrapps?.map((w) => (
            <div key={w.path} className="saved-row">
              <IconArt doc={doc} size={40} real="eager" />
              <div className="col" style={{ gap: 2, minWidth: 0 }}>
                <b>{w.name}</b>
                <span className="mono wraps" title={w.path}>{w.path}</span>
              </div>
              <button className="btn small" disabled={busy !== null} onClick={() => void tryOn(w)}>
                {busy === w.path ? <><span className="spin" /> Putting it on…</> : "Use this icon"}
              </button>
            </div>
          ))}
          {done && <div className="notice">{done} now has this icon. Open it, or look in the Dock or Finder, to see it.</div>}
          {error && <div className="notice bad">{error}</div>}
        </div>
        <footer><button className="btn primary" onClick={onClose}>Done</button></footer>
      </div>
    </div>
  );
}
