// The cut-out editor: draw a region, click to add (+) or remove (−), and choose how much to take from the
// answers (a small part → the whole object); grow, soften and fill its edges; save it as a new part, or update the
// part being edited. Prompts go to SAM (POST …/segment) or Vision inside a region (POST …/detect).
import { useCallback, useEffect, useRef, useState } from "react";
import type { Candidate, Edges, MediaKind, Prompt } from "../../api";
import { useApp } from "../../state/app";
import { candidatesFor, previewCandidate, saveCandidate } from "../../parts/actions";
import { KIND_LABELS, kindLabel } from "./MediaCard";
import type { EditRequest } from "./MediaInspector";

type Tool = "region" | "add" | "remove";
type State = { region?: [number, number, number, number]; points: { x: number; y: number; positive: boolean }[] };
const NO_EDGES: Edges = { grow: 0, soften: 0, fillHoles: false };
const KINDS = Object.keys(KIND_LABELS).filter((k) => k !== "unknown") as MediaKind[];

export function CutoutEditor({ req, onClose }: { req: EditRequest; onClose(): void }) {
  // Follow the media as it changes (a save updates it).
  const m = useApp((s) => s.media.get(req.m.id)) ?? req.m;
  const part = req.part;
  const [tool, setTool] = useState<Tool>(req.tool);
  const [st, setSt] = useState<State>(() => ({ region: part?.prompt?.region ?? (part ? part.box : undefined), points: part?.prompt?.points ?? [] }));
  const [history, setHistory] = useState<State[]>([]);
  const [cands, setCands] = useState<Candidate[]>([]);
  const [choice, setChoice] = useState<number>(part?.prompt?.choice ?? -1);
  const [edges, setEdges] = useState<Edges>(part?.edges ?? NO_EDGES);
  const [preview, setPreview] = useState<{ url: string; box?: [number, number, number, number] } | null>(null);
  const [engine, setEngine] = useState<"sam" | "vision" | "page" | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState(part ? part.name : "");
  const [kind, setKind] = useState<string>(part?.kind ?? "unknown");
  const [saving, setSaving] = useState(false);
  const [asking, setAsking] = useState(false);
  const seq = useRef(0);

  // ------------------------------------------------------------ asking for candidates
  const ask = useCallback(async (s: State, keepChoice?: number) => {
    if (!s.region && !s.points.length) { setCands([]); return; }
    const n = ++seq.current;
    setBusy(true); setError(null);
    try {
      const r = await candidatesFor(m, { region: s.region, points: s.points.length ? s.points : undefined });
      if (n !== seq.current) return;
      setCands(r.candidates); setEngine(r.engine);
      const best = r.candidates.reduce((bi, c, i, a) => (c.score > a[bi].score ? i : bi), 0);
      setChoice(keepChoice != null && keepChoice >= 0 && keepChoice < r.candidates.length ? keepChoice : best);
    } catch (e) {
      if (n === seq.current) setError((e as Error).message);
    } finally { if (n === seq.current) setBusy(false); }
  }, [m]);

  useEffect(() => { if (st.region || st.points.length) void ask(st, part?.prompt?.choice); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const change = (next: State) => { setHistory((h) => [...h, st]); setSt(next); void ask(next); };
  const undo = () => { const prev = history[history.length - 1]; if (!prev) return; setHistory((h) => h.slice(0, -1)); setSt(prev); void ask(prev); };

  // ------------------------------------------------------------ edges preview
  const cand = cands[choice] ?? null;
  const previewFor = useRef<string | null>(null);
  useEffect(() => {
    // Keep showing the last preview of this candidate until the new one arrives (no flicker while dragging).
    if (!cand || (!edges.grow && !edges.soften && !edges.fillHoles)) { setPreview(null); previewFor.current = null; return; }
    if (previewFor.current !== cand.id) setPreview(null);
    let live = true;
    const t = window.setTimeout(() => {
      previewCandidate(m, cand.id, edges).then((r) => { if (live) { previewFor.current = cand.id; setPreview(r); } }).catch((e) => { if (live) setError((e as Error).message); });
    }, 150);
    return () => { live = false; window.clearTimeout(t); };
  }, [cand, edges, m]);

  // ------------------------------------------------------------ keys
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (asking) { if (e.key === "Escape") { e.stopPropagation(); setAsking(false); } return; }
      if ((e.target as HTMLElement).closest("input, select, textarea")) return;
      if (e.key === "Escape") onClose();
      else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); undo(); }
      else if (e.key === "r") setTool("region");
      else if (e.key === "+" || e.key === "=") setTool("add");
      else if (e.key === "-") setTool("remove");
    };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  });

  const save = async (asNew: boolean) => {
    if (!cand) return;
    setSaving(true); setError(null);
    try {
      const prompt: Prompt = { region: st.region, points: st.points.length ? st.points : undefined, choice };
      await saveCandidate(m, cand.id, { partId: asNew ? undefined : part?.id, name: asNew || !part ? name.trim() || undefined : undefined, kind: kind !== "unknown" ? kind : undefined, edges, prompt });
      useApp.getState().say(asNew || !part ? "Saved as a new part, picked" : `Updated “${part.name}”`);
      onClose();
    } catch (e) { setError((e as Error).message); } finally { setSaving(false); }
  };

  const canSave = !!cand && !saving;
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dlg editor" role="dialog" aria-label="Edit cut-out">
        <header className="ed-bar">
          <h2>{part ? `Edit cut-out · ${part.name}` : "New cut-out"}</h2>
          <span className="muted">{kindLabel(m.kind === "unknown" ? m.name : m.kind)} · {m.source} · {m.width}×{m.height}</span>
          <span className="grow" />
          <button className="btn" onClick={onClose}>Cancel</button>
          {part && <button className="btn" disabled={!canSave} onClick={() => void save(false)}>Update “{part.name}”</button>}
          <button className="btn primary" disabled={!canSave} onClick={() => { setName(part ? `${part.name} (2)` : ""); setAsking(true); }}>Save as new part…</button>
        </header>
        <div className="ed-tip"><span className="fl">Tip</span>
          <span className="muted">{tool === "region" ? "Drag a box around what you want." : tool === "add" ? "Click what to add." : "Click what to leave out."} Then choose how much to take on the right. <kbd>R</kbd> region, <kbd>+</kbd> add, <kbd>−</kbd> remove, <kbd>⌘Z</kbd> undo.</span>
        </div>
        <div className="ed">
          <div className="tools" role="toolbar" aria-label="Tools">
            <ToolBtn on={tool === "region"} title="Region: drag a box (R)" onClick={() => setTool("region")}>▭</ToolBtn>
            <ToolBtn on={tool === "add"} title="Add by clicking (+)" onClick={() => setTool("add")}>＋</ToolBtn>
            <ToolBtn on={tool === "remove"} title="Remove by clicking (−)" onClick={() => setTool("remove")}>－</ToolBtn>
            <ToolBtn disabled title="Brush in: soon">✎</ToolBtn>
            <ToolBtn disabled title="Brush out: soon">⌫</ToolBtn>
            <span style={{ height: 8 }} />
            <ToolBtn disabled={!history.length} title="Undo (⌘Z)" onClick={undo}>↶</ToolBtn>
            <ToolBtn disabled={!st.region && !st.points.length} title="Start again" onClick={() => change({ points: [] })}>⌧</ToolBtn>
          </div>
          <EditCanvas m={m} st={st} tool={tool} cand={cand} preview={preview} busy={busy}
            onRegion={(region) => change({ ...st, region })}
            onPoint={(x, y) => change({ ...st, points: [...st.points, { x, y, positive: tool !== "remove" }] })} />
          <div className="side">
            <div className="sec2">How much to take {busy && <span className="spin" />}</div>
            {cands.length ? (
              <div className="opts">
                {cands.map((c, i) => (
                  <button key={c.id} className={"opt" + (i === choice ? " on" : "")} onClick={() => setChoice(i)} aria-pressed={i === choice}>
                    <span className="im checker"><img src={c.url} alt="" /></span>
                    <b>{cands.length > 1 ? (i === 0 ? "Smallest" : i === cands.length - 1 ? "Most" : "Middle") : "This"}</b>
                    <span className="muted">{Math.round(c.area * 100)}% · {Math.round(c.score * 100)}</span>
                  </button>
                ))}
              </div>
            ) : <p className="muted ed-note">{busy ? "Looking…" : "Draw a region, or click on the picture, to get choices."}</p>}
            {engine && <p className="faint ed-note">{engine === "sam" ? "SAM 2.1 gave these: a small part through to the whole object." : engine === "vision" ? "Vision found the subject inside your region (clicks need SAM, which isn't answering yet)." : "Made by this page from the subject mask and your region, until the engine's cut-out routes answer. Clicks only rule choices out."}</p>}
            {error && <div className="notice bad" style={{ margin: "6px 12px" }}>{error}</div>}

            <div className="sec2">Edges</div>
            <label className="kv2"><span>Grow / shrink</span><input type="range" min={-20} max={20} step={1} value={edges.grow} onChange={(e) => setEdges({ ...edges, grow: +e.target.value })} /><output>{edges.grow > 0 ? "+" : ""}{edges.grow} px</output></label>
            <label className="kv2"><span>Soften edge</span><input type="range" min={0} max={10} step={0.5} value={edges.soften} onChange={(e) => setEdges({ ...edges, soften: +e.target.value })} /><output>{edges.soften} px</output></label>
            <label className="kv2"><span>Fill holes</span><input type="checkbox" checked={edges.fillHoles} onChange={(e) => setEdges({ ...edges, fillHoles: e.target.checked })} /><span /></label>

            <div className="sec2">Result</div>
            <p className="muted ed-note">{cand ? `${Math.round((preview?.box ?? cand.box)[2] * m.width)}×${Math.round((preview?.box ?? cand.box)[3] * m.height)} px · ${Math.round(cand.area * 100)}% of the picture` : "Nothing chosen yet."}</p>
          </div>
        </div>
        {asking && (
          <div className="ask-scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) setAsking(false); }}>
            <form className="ask" role="dialog" aria-label="Save as a new part" onSubmit={(e) => { e.preventDefault(); void save(true); }}>
              <h3>Save as a new part</h3>
              <div className="ask-row">
                <span className="checker ask-th">{cand && <img src={preview?.url ?? cand.url} alt="" />}</span>
                <div className="col" style={{ gap: 8, flex: 1 }}>
                  <label className="kv2 wide"><span>Name</span><input className="text" autoFocus value={name} placeholder="e.g. Freddi" onChange={(e) => setName(e.target.value)} /></label>
                  <label className="kv2 wide"><span>Kind</span>
                    <select className="text" value={kind} onChange={(e) => setKind(e.target.value)}>
                      <option value="unknown">None</option>
                      {KINDS.map((k) => <option key={k} value={k}>{kindLabel(k)}</option>)}
                    </select>
                  </label>
                  <span className="muted" style={{ fontSize: 11.5, padding: "0 12px" }}>{cand ? `${Math.round((preview?.box ?? cand.box)[2] * m.width)}×${Math.round((preview?.box ?? cand.box)[3] * m.height)} px` : ""} · it's picked as soon as it's saved.</span>
                </div>
              </div>
              {error && <div className="notice bad">{error}</div>}
              <div className="row" style={{ justifyContent: "flex-end" }}>
                <button type="button" className="btn" onClick={() => setAsking(false)}>Cancel</button>
                <button type="submit" className="btn primary" disabled={saving}>{saving ? <><span className="spin" /> Saving…</> : "Save part"}</button>
              </div>
            </form>
          </div>
        )}
      </div>
    </div>
  );
}

function ToolBtn({ on, disabled, title, onClick, children }: { on?: boolean; disabled?: boolean; title: string; onClick?(): void; children: React.ReactNode }) {
  return <button className={"tool" + (on ? " on" : "")} disabled={disabled} title={title} aria-label={title} aria-pressed={on} onClick={onClick}>{children}</button>;
}

/** The picture (dimmed), the chosen cut-out over it (bright), the region and the clicks. */
function EditCanvas({ m, st, tool, cand, preview, busy, onRegion, onPoint }: {
  m: ReturnType<typeof useApp.getState>["media"] extends Map<string, infer T> ? T : never
  st: State; tool: Tool; cand: Candidate | null; preview: { url: string; box?: [number, number, number, number] } | null; busy: boolean
  onRegion(r: [number, number, number, number]): void; onPoint(x: number, y: number): void
}) {
  const wrap = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ w: 700, h: 560 });
  useEffect(() => {
    const el = wrap.current; if (!el) return;
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth - 40, h: el.clientHeight - 40 }));
    ro.observe(el); return () => ro.disconnect();
  }, []);
  const k = Math.min(box.w / m.width, box.h / m.height, Math.max(m.width, m.height) <= 256 ? 8 : 3);
  const W = m.width * k, H = m.height * k;
  const [drag, setDrag] = useState<{ x0: number; y0: number; x1: number; y1: number } | null>(null);
  const at = (e: React.PointerEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    return { x: Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)), y: Math.max(0, Math.min(1, (e.clientY - r.top) / r.height)) };
  };
  const region = drag ? [Math.min(drag.x0, drag.x1), Math.min(drag.y0, drag.y1), Math.abs(drag.x1 - drag.x0), Math.abs(drag.y1 - drag.y0)] : st.region;
  const pixel = Math.max(m.width, m.height) <= 256 || m.analysis.pixelArt;
  // The previewed cut-out sits where the engine says (its own box), so edges never rescale it.
  const lit = cand ? (preview ? { url: preview.url, box: preview.box ?? cand.box } : { url: cand.url, box: cand.box }) : null;
  return (
    <div className="ecanvas" ref={wrap}>
      <div className="cin" style={{ width: W, height: H, cursor: tool === "region" ? "crosshair" : "copy" }}
        onPointerDown={(e) => {
          const p = at(e);
          if (tool === "region") { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); setDrag({ x0: p.x, y0: p.y, x1: p.x, y1: p.y }); }
          else onPoint(p.x, p.y);
        }}
        onPointerMove={(e) => { if (drag) { const p = at(e); setDrag({ ...drag, x1: p.x, y1: p.y }); } }}
        onPointerUp={() => {
          if (!drag) return;
          const r: [number, number, number, number] = [Math.min(drag.x0, drag.x1), Math.min(drag.y0, drag.y1), Math.abs(drag.x1 - drag.x0), Math.abs(drag.y1 - drag.y0)];
          setDrag(null);
          if (r[2] > 0.01 && r[3] > 0.01) onRegion(r);
        }}>
        <img key={m.id} className="base" src={m.url} alt="" draggable={false} style={{ width: W, height: H, ...(pixel ? { imageRendering: "pixelated" } : {}) }} />
        {cand && lit && <img className="lit" src={lit.url} alt="" draggable={false}
          style={{ left: lit.box[0] * W, top: lit.box[1] * H, width: lit.box[2] * W, height: lit.box[3] * H, ...(pixel ? { imageRendering: "pixelated" } : {}) }} />}
        {region && <div className="region" style={{ left: region[0] * W, top: region[1] * H, width: region[2] * W, height: region[3] * H }} />}
        {st.points.map((p, i) => <span key={i} className={"pt " + (p.positive ? "plus" : "minus")} style={{ left: p.x * W, top: p.y * H }}>{p.positive ? "+" : "−"}</span>)}
        {busy && <span className="cbusy"><span className="spin" /></span>}
      </div>
    </div>
  );
}
