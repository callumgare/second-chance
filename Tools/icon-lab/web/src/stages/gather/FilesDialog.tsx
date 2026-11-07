// "Add from files": our own path browser (real paths, nothing uploaded) over GET /api/fs, then the scan:
// POST …/extract, with the unpacking drawn as a tree as it streams in. The wrapps the host has built (GET /api/wrapps)
// are listed above the browser, each a one-click scan.
import { useCallback, useEffect, useRef, useState } from "react";
import { api, type FSEntry, type FSListing, type Wrapp } from "../../api";
import { useScans } from "../../state/scans";
import { ScanView } from "./ScanTree";

const TYPE_LABELS: Record<string, string> = {
  wrapp: "Game app", app: "Mac app", "disc-image": "Disc image", installer: "Installer", archive: "Archive", program: "Program", image: "Image", folder: "Folder", other: "",
};
const ICONS: Record<string, string> = { wrapp: "▣", app: "▢", "disc-image": "◎", installer: "⬇", archive: "▤", program: "▶", image: "▨", folder: "▸", other: "·" };
const SCANNABLE = new Set(["wrapp", "app", "disc-image", "installer", "archive", "program", "image", "folder"]);

const LAST = "iconlab-files:last";
const remember = (p: string) => { try { localStorage.setItem(LAST, p); } catch { /* unavailable */ } };
const recall = () => { try { return localStorage.getItem(LAST) ?? undefined; } catch { return undefined; } };

const fmtSize = (n?: number) => n == null ? "" : n < 1024 ? `${n} B` : n < 1024 ** 2 ? `${Math.round(n / 1024)} KB` : n < 1024 ** 3 ? `${(n / 1024 ** 2).toFixed(n < 10 * 1024 ** 2 ? 1 : 0)} MB` : `${(n / 1024 ** 3).toFixed(1)} GB`;

export function FilesDialog({ slug, scan: initialScan, onClose, onShowImages }: { slug: string; scan: string | null; onClose(): void; onShowImages(): void }) {
  const [cols, setCols] = useState<FSListing[]>([]);
  const [places, setPlaces] = useState<FSEntry[]>([]);
  const [sel, setSel] = useState<FSEntry | null>(null);
  const [pathText, setPathText] = useState("");
  const [hidden, setHidden] = useState(false);
  const [recognised, setRecognised] = useState(false);
  const [view, setView] = useState<"columns" | "list">("columns");
  const [error, setError] = useState<string | null>(null);
  const [scanError, setScanError] = useState<string | null>(null);
  const [starting, setStarting] = useState(false);
  const [scan, setScan] = useState<string | null>(initialScan);
  const [wrapps, setWrapps] = useState<Wrapp[]>([]);
  useEffect(() => { api.wrapps().then(setWrapps).catch(() => setWrapps([])); }, []);
  const colsRef = useRef<HTMLDivElement>(null);

  const open = useCallback(async (path: string | undefined, at = 0, select?: string) => {
    setError(null);
    try {
      const l = await api.fs(path, hidden);
      setPlaces(l.places);
      setCols((c) => [...c.slice(0, at), l]);
      setPathText(select ?? l.path);
      if (select) setSel(l.entries.find((e) => e.path === select) ?? null); else setSel(null);
      remember(l.path);
      requestAnimationFrame(() => colsRef.current?.scrollTo({ left: colsRef.current.scrollWidth, behavior: "smooth" }));
    } catch (e) {
      // A path to a file: open its folder and select it.
      if (path && path.includes("/") && at === 0 && !select) {
        const parent = path.replace(/\/[^/]+\/?$/, "") || "/";
        if (parent !== path) { await open(parent, 0, path.replace(/\/$/, "")); return; }
      }
      setError((e as Error).message);
    }
  }, [hidden]);

  useEffect(() => { if (!scan) void open(cols[cols.length - 1]?.path ?? recall()); }, [hidden]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape" && !(e.target as HTMLElement).closest("input")) onClose(); };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [onClose]);

  const startScan = async (path: string) => {
    setStarting(true); setScanError(null);
    try {
      const r = await api.extract(slug, path);
      useScans.getState().start(r.scan, slug, path);
      setScan(r.scan);
    } catch (e) {
      setScanError((e as Error).message);
    } finally { setStarting(false); }
  };

  const target = sel ?? (cols.length ? { name: cols[cols.length - 1].path.split("/").pop() || "/", path: cols[cols.length - 1].path, dir: true, type: "folder" as const } : null);
  const shownEntries = (l: FSListing) => l.entries.filter((e) => !recognised || e.dir || e.type !== "other");

  if (scan) {
    return (
      <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
        <div className="dlg wide" role="dialog" aria-label="Finding images in your files">
          <ScanView scanId={scan} onClose={onClose} onShowImages={onShowImages} onAnother={() => { setScan(null); void open(cols[cols.length - 1]?.path ?? recall()); }} />
        </div>
      </div>
    );
  }

  const lastCol = cols[cols.length - 1];
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dlg wide" role="dialog" aria-label="Add images from your files">
        <header>
          <h2>Add images from your files</h2>
          <form className="pathbar" onSubmit={(e) => { e.preventDefault(); void open(pathText.trim().replace(/^~(?=\/|$)/, places.find((p) => p.name === "Home")?.path ?? "~"), 0); }}>
            <span className="faint">Path</span>
            <input value={pathText} onChange={(e) => setPathText(e.target.value)} spellCheck={false} aria-label="Path" placeholder="Type or paste a path, then Enter"
              onKeyDown={(e) => e.stopPropagation()} />
            <button className="btn small" type="submit">Go</button>
          </form>
          <div className="places">
            {places.map((p) => <button key={p.path} className={"chip" + (lastCol?.path.startsWith(p.path) && cols.length === 1 && lastCol.path === p.path ? " on" : "")} onClick={() => void open(p.path, 0)}>{p.name}</button>)}
            <span className="grow" />
            <button className={"chip" + (recognised ? " on" : "")} onClick={() => setRecognised(!recognised)}>Recognised items only</button>
            <button className={"chip" + (hidden ? " on" : "")} onClick={() => setHidden(!hidden)}>Show hidden files</button>
            <span className="seg"><button className={view === "columns" ? "on" : ""} onClick={() => setView("columns")}>Columns</button><button className={view === "list" ? "on" : ""} onClick={() => setView("list")}>List</button></span>
          </div>
        </header>
        {wrapps.length > 0 && (
          <div className="places wrapps" aria-label="Built game apps">
            <span className="faint">Built apps</span>
            {wrapps.map((w) => (
              <button key={w.path} className="chip" title={`Scan ${w.path}`} disabled={starting} onClick={() => void startScan(w.path)}>▣ {w.name}</button>
            ))}
          </div>
        )}
        <div className="browser">
          {error && <div className="notice bad">{error}</div>}
          {view === "columns" ? (
            <div className="cols" ref={colsRef}>
              {cols.map((l, i) => (
                <div key={l.path + i} className="col" role="listbox" aria-label={l.path}>
                  {i === 0 && l.parent && <div className="fi dim" onClick={() => void open(l.parent!, 0)}><span className="ic">↰</span><span>Enclosing folder</span><span /></div>}
                  {shownEntries(l).map((e) => (
                    <FileRow key={e.path} e={e} selected={sel?.path === e.path || cols[i + 1]?.path === e.path}
                      onClick={() => { if (e.dir && e.type === "folder") void open(e.path, i + 1); else { setCols((c) => c.slice(0, i + 1)); setSel(e); setPathText(e.path); } }}
                      onOpen={() => { if (e.dir && e.type === "folder") void open(e.path, i + 1); else if (SCANNABLE.has(e.type)) void startScan(e.path); }} />
                  ))}
                  {!shownEntries(l).length && <div className="faint" style={{ padding: "6px 10px" }}>Empty</div>}
                </div>
              ))}
              <What e={target} />
            </div>
          ) : (
            <div className="listview">
              {lastCol?.parent && <div className="fi dim" onClick={() => void open(lastCol.parent!, 0)}><span className="ic">↰</span><span>Enclosing folder</span><span /><span /></div>}
              {lastCol && shownEntries(lastCol).map((e) => (
                <FileRow key={e.path} e={e} wide selected={sel?.path === e.path}
                  onClick={() => { setSel(e); setPathText(e.path); }}
                  onOpen={() => { if (e.dir && e.type === "folder") void open(e.path, 0); else if (SCANNABLE.has(e.type)) void startScan(e.path); }} />
              ))}
            </div>
          )}
        </div>
        {scanError && <div className="notice bad" style={{ margin: "0 16px 8px" }}>Couldn't scan: {scanError}</div>}
        <footer>
          <span className="muted" style={{ marginRight: "auto" }}>Pick a game's app, disc image, installer or game folder. Nothing in it is run.</span>
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn primary" disabled={!target || !SCANNABLE.has(target.type) || starting} onClick={() => target && void startScan(target.path)}>
            {starting ? <><span className="spin" /> Starting…</> : target && target !== sel ? "Scan this folder" : "Scan for images"}
          </button>
        </footer>
      </div>
    </div>
  );
}

function FileRow({ e, selected, wide, onClick, onOpen }: { e: FSEntry; selected: boolean; wide?: boolean; onClick(): void; onOpen(): void }) {
  const label = TYPE_LABELS[e.type];
  return (
    <div className={"fi" + (selected ? " sel" : "") + (e.type === "other" && !e.dir ? " dim" : "") + (wide ? " wide" : "")} onClick={onClick} onDoubleClick={onOpen} role="option" aria-selected={selected} title={e.hint ?? e.path}>
      <span className="ic">{ICONS[e.type] ?? "·"}</span>
      <span className="ellipsis">{e.name}</span>
      {wide && <span className="faint">{e.hint ?? ""}</span>}
      {wide && <span className="faint size">{fmtSize(e.size)}</span>}
      {label && e.type !== "folder" ? <span className="tag">{label}</span> : e.dir ? <span className="faint">›</span> : <span />}
    </div>
  );
}

function What({ e }: { e: (FSEntry & { hint?: string }) | null }) {
  if (!e) return <div className="what" />;
  const scannable = SCANNABLE.has(e.type);
  return (
    <div className="what">
      <h3 className="wraps" title={e.path}>{e.name}</h3>
      {TYPE_LABELS[e.type] && <span className="tag" style={{ justifySelf: "start" }}>{TYPE_LABELS[e.type]}</span>}
      {e.hint && <span className="muted">{e.hint}</span>}
      {e.size != null && <span className="muted">{fmtSize(e.size)}</span>}
      <span className="mono path">{e.path}</span>
      <p className="faint" style={{ margin: 0 }}>
        {scannable ? (e.type === "folder" ? "Scanning a folder looks in everything inside it." : "Scanning opens containers and installers without running anything.") : "This isn't something we know how to look inside."}
      </p>
    </div>
  );
}
