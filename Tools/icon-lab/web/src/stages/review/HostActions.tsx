// What the host offers for pinned designs: trying one on a built wrapp (its .icns put in the app, so the Dock and
// Finder show it), and saving them to the program's bundle (Second Chance's checkout only). docs/api.md has the routes.
import { useEffect, useState } from "react";
import { api, type Doc, type HostInfo, type SavedToBundle, type Wrapp } from "../../api";
import { IconArt } from "../../components/IconArt";
import { useApp } from "../../state/app";

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

/** Save the kept designs, in order, to the program's bundle: what was written, and the Wrappfile lines still to add. */
export function SaveToBundle({ slug, docs, onClose }: { slug: string; docs: Doc[]; onClose(): void }) {
  const bundle = useApp((s) => s.program?.bundleId);
  const [result, setResult] = useState<SavedToBundle | null>(null);
  const [busy, setBusy] = useState(false);
  const [added, setAdded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    setBusy(true); setError(null);
    try { setResult(await api.saveToBundle(slug, docs.map((d) => d.id))); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  };
  const addLines = async () => {
    setBusy(true); setError(null);
    try { await api.addIconLines(slug); setAdded(true); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  };
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dlg" role="dialog" aria-label="Save to the bundle">
        <header><h2>Save to {bundle ?? "the bundle"}</h2></header>
        <div className="saved-list">
          {!result && <>
            <p className="muted" style={{ margin: 0 }}>Writes {docs.length === 1 ? "this design" : `these ${docs.length} designs, in this order,`} to the bundle's assets/ as .icon files with their compiled .icns. The first is the app's icon. Nothing is committed.</p>
            {docs.map((d, i) => (
              <div key={d.id} className="saved-row">
                <IconArt doc={d} size={40} real="eager" />
                <b>{i + 1}. {d.name}</b>
              </div>
            ))}
          </>}
          {result && <>
            <div className="notice">Wrote {result.files.join(", ")}{result.allowPathAdded ? ", and added \"assets/\" to the manifest's allow-paths" : ""}.</div>
            {result.manifestNote && <div className="notice bad">Still to do: {result.manifestNote}.</div>}
            {result.wrappfileLines && !added && <>
              <p className="muted" style={{ margin: 0 }}>The Wrappfile doesn't give the app an icon yet. Add these lines to its stage, after its LAUNCH:</p>
              <pre className="mono">{result.wrappfileLines.join("\n")}</pre>
            </>}
            {added && <div className="notice">Added them to the Wrappfile.</div>}
            <p className="faint" style={{ margin: 0 }}>Check the changes with git, then commit them yourself.</p>
          </>}
          {error && <div className="notice bad">{error}</div>}
        </div>
        <footer>
          <button className="btn" onClick={onClose}>{result ? "Done" : "Cancel"}</button>
          {!result && <button className="btn primary" disabled={busy || !docs.length} onClick={() => void save()}>{busy ? <><span className="spin" /> Saving…</> : "Save to the bundle"}</button>}
          {result?.wrappfileLines && result.canAddLines && !added && (
            <button className="btn primary" disabled={busy} onClick={() => void addLines()}>Add them for me</button>
          )}
        </footer>
      </div>
    </div>
  );
}
