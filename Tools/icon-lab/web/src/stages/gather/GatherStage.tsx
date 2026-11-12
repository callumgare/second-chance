// Stage 2: gather images. Everything found for the program, "From your files" first and then online, each
// sorted by suitability; filters; duplicates folded under their best copy; keyboard culling; the inspector; the
// activity panel docked below; "Add from files" for our own path browser and scans.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Media } from "../../api";
import { go } from "../../lib/router";
import { useApp } from "../../state/app";
import { useJobs } from "../../state/jobs";
import { StatusSlot, TitleActions } from "../../shell/slots";
import { kindLabel, MediaCard, pickState, type Thumbs } from "./MediaCard";
import { pickAll } from "../../parts/actions";
import { Seg } from "../../components/controls";
import { MediaInspector, type EditRequest } from "./MediaInspector";
import { CutoutEditor } from "./CutoutEditor";
import { SourcesPanel } from "./SourcesPanel";
import { ActivityDock } from "./ActivityDock";
import { FilesDialog } from "./FilesDialog";
import { WaitingDialog } from "./WaitingDialog";
import "./gather.css";

const CARD = 156, GAP = 10, HEAD = 40, ROW = CARD + 56 + GAP;
type Sort = "suitability" | "size" | "source" | "newest";
type Filters = { kinds: Set<string>; source: string; minSize: number; subject: boolean; text: boolean; simple: boolean; hideDupes: boolean; picked: boolean; sort: Sort }
const DEFAULT_FILTERS: Filters = { kinds: new Set(), source: "all", minSize: 0, subject: false, text: false, simple: false, hideDupes: true, picked: false, sort: "suitability" };

type Group = "local" | "online" | "unrelated";
type Item = { type: "head"; group: Group; shown: number; total: number } | { type: "row"; cards: Media[]; group: Group } | { type: "empty"; group: Group };
/** Pictures from a general search (Commons, Openverse) carry `relevance`; catalogue pictures count as relevant. */
const UNRELATED = 0.4;
const relevance = (m: Media) => m.relevance ?? 1;

export function GatherStage({ slug }: { slug: string }) {
  const program = useApp((s) => (s.program?.slug === slug ? s.program : null));
  const [f, setF] = useState<Filters>(DEFAULT_FILTERS);
  const [srcCollapsed, setSrcCollapsed] = useState(() => { try { return localStorage.getItem("iconlab-sources") === "0"; } catch { return false; } });
  const toggleSources = () => setSrcCollapsed((c) => { try { localStorage.setItem("iconlab-sources", c ? "1" : "0"); } catch { /* fine */ } return !c; });
  const [selId, setSelId] = useState<string | null>(null);
  const [dockCollapsed, setDockCollapsed] = useState(false);
  const [files, setFiles] = useState<{ open: boolean; scan: string | null }>({ open: false, scan: null });
  const [waiting, setWaiting] = useState(false);
  const [editing, setEditing] = useState<EditRequest | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(900);
  useEffect(() => {
    const el = scroller.current; if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth - 28));
    ro.observe(el); return () => ro.disconnect();
  }, [program != null]);

  const [showHidden, setShowHidden] = useState(false);
  const everything = program?.media;
  // Hidden pictures are left out of the grid and every count, unless "Show hidden" is on.
  const all = useMemo(() => (everything ?? []).filter((m) => showHidden || !m.hidden), [everything, showHidden]);
  const hiddenCount = (everything ?? []).filter((m) => m.hidden).length;
  // Duplicates fold under the best copy: the root of each duplicateOf chain.
  const { rootOf, stackSize } = useMemo(() => {
    const byId = new Map(all.map((m) => [m.id, m]));
    const rootOf = new Map<string, string>();
    for (const m of all) {
      let r = m, guard = 0;
      while (r.duplicateOf && byId.has(r.duplicateOf) && guard++ < 10) r = byId.get(r.duplicateOf)!;
      rootOf.set(m.id, r.id);
    }
    const stackSize = new Map<string, number>();
    for (const r of rootOf.values()) stackSize.set(r, (stackSize.get(r) ?? 0) + 1);
    return { rootOf, stackSize };
  }, [all]);

  const kindsPresent = useMemo(() => {
    const c = new Map<string, number>();
    for (const m of all) if (!f.hideDupes || rootOf.get(m.id) === m.id) c.set(m.kind, (c.get(m.kind) ?? 0) + 1);
    return [...c.entries()].sort((a, b) => (a[0] === "unknown" ? 1 : b[0] === "unknown" ? -1 : b[1] - a[1]));
  }, [all, rootOf, f.hideDupes]);
  const sources = useMemo(() => [...new Set(all.map((m) => m.source))].sort((a, b) => (a === "Your files" ? -1 : b === "Your files" ? 1 : a.localeCompare(b))), [all]);

  const visible = useMemo(() => {
    const order = new Map(all.map((m, i) => [m.id, i]));
    const pass = (m: Media) => (!f.kinds.size || f.kinds.has(m.kind)) && (f.source === "all" || m.source === f.source)
      && Math.max(m.width, m.height) >= f.minSize && (!f.subject || m.analysis.subject) && (!f.text || m.analysis.text.length > 0 || m.analysis.textFraction > 0.02)
      && (!f.simple || m.analysis.busyness <= 0.6) && (!f.picked || m.picked)
      && (!f.hideDupes || rootOf.get(m.id) === m.id || m.picked);
    const sorter = (a: Media, b: Media) => f.sort === "size" ? b.width * b.height - a.width * a.height
      : f.sort === "source" ? a.source.localeCompare(b.source) || b.suitability - a.suitability
      : f.sort === "newest" ? (order.get(b.id)! - order.get(a.id)!)
      : b.suitability * relevance(b) - a.suitability * relevance(a);
    const list = all.filter(pass);
    const local = list.filter((m) => m.source === "Your files").sort(sorter);
    const others = list.filter((m) => m.source !== "Your files").sort(sorter);
    const online = others.filter((m) => relevance(m) >= UNRELATED);
    const unrelated = others.filter((m) => relevance(m) < UNRELATED);
    return { local, online, unrelated };
  }, [all, f, rootOf]);
  const totals = {
    local: all.filter((m) => m.source === "Your files").length,
    online: all.filter((m) => m.source !== "Your files" && relevance(m) >= UNRELATED).length,
    unrelated: all.filter((m) => m.source !== "Your files" && relevance(m) < UNRELATED).length,
  };
  const [showUnrelated, setShowUnrelated] = useState(false);

  const cols = Math.max(1, Math.floor((width + GAP) / (CARD + GAP)));
  const items: Item[] = useMemo(() => {
    const out: Item[] = [];
    for (const g of ["local", "online", "unrelated"] as const) {
      const list = visible[g];
      if (g === "unrelated" && !list.length) continue;
      out.push({ type: "head", group: g, shown: list.length, total: totals[g] });
      if (g === "unrelated" && !showUnrelated) continue;
      if (!list.length) out.push({ type: "empty", group: g });
      for (let i = 0; i < list.length; i += cols) out.push({ type: "row", group: g, cards: list.slice(i, i + cols) });
    }
    return out;
  }, [visible, cols, totals.local, totals.online, totals.unrelated, showUnrelated]); // eslint-disable-line react-hooks/exhaustive-deps
  const flat = useMemo(() => [...visible.local, ...visible.online, ...(showUnrelated ? visible.unrelated : [])], [visible, showUnrelated]);

  const v = useVirtualizer({
    count: items.length, getScrollElement: () => scroller.current, overscan: 4,
    // Keys, not indexes, so a size measured for a header isn't reused for the row that moves into its place.
    getItemKey: (i) => { const it = items[i]; return it.type === "row" ? `${it.group}:${it.cards[0].id}` : `${it.type}:${it.group}`; },
    estimateSize: (i) => (items[i].type === "head" ? HEAD : items[i].type === "empty" ? 60 : ROW),
  });

  const sel = all.find((m) => m.id === selId) ?? null;
  useEffect(() => { if (!selId && flat.length) setSelId(flat[0].id); }, [flat, selId]);

  // The grid picks every part or none: a half-picked picture's circle picks the rest.
  const pick = useCallback((m: Media, value?: boolean) => {
    const v = value ?? pickState(m) !== "all";
    void pickAll(m, v).catch((e) => useApp.getState().say("Couldn't change the pick: " + (e as Error).message, "error"));
  }, []);
  const [thumbs, setThumbsState] = useState<Thumbs>(() => { try { return (localStorage.getItem("iconlab-thumbs") as Thumbs) || "whole"; } catch { return "whole"; } });
  const setThumbs = (t: Thumbs) => { setThumbsState(t); try { localStorage.setItem("iconlab-thumbs", t); } catch { /* fine */ } };
  const select = useCallback((m: Media) => setSelId(m.id), []);
  const hide = useCallback((m: Media, hidden: boolean) => void useApp.getState().setHidden(m.id, hidden), []);
  const reveal = (id: string) => {
    setSelId(id);
    const idx = items.findIndex((it) => it.type === "row" && it.cards.some((c) => c.id === id));
    if (idx >= 0) v.scrollToIndex(idx, { align: "auto" });
  };

  // Keyboard culling: arrows move, P picks, X unpicks, Space toggles.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (files.open || waiting || editing) return;
      if ((e.target as HTMLElement).closest("input, select, textarea") || e.metaKey || e.ctrlKey || e.altKey) return;
      const i = flat.findIndex((m) => m.id === selId);
      const cur = flat[i];
      const groupStart = cur && cur.source === "Your files" ? 0 : visible.local.length;
      const posInGroup = i - groupStart;
      let next = -1;
      switch (e.key) {
        case "ArrowRight": next = Math.min(flat.length - 1, i + 1); break;
        case "ArrowLeft": next = Math.max(0, i - 1); break;
        case "ArrowDown": {
          const groupLen = cur?.source === "Your files" ? visible.local.length : visible.online.length;
          next = posInGroup + cols < groupLen ? i + cols : cur?.source === "Your files" && visible.online.length ? visible.local.length + Math.min(posInGroup % cols, visible.online.length - 1) : i;
          break;
        }
        case "ArrowUp":
          next = posInGroup - cols >= 0 ? i - cols : cur?.source !== "Your files" && visible.local.length ? Math.max(0, visible.local.length - 1 - ((visible.local.length - 1) % cols) + (posInGroup % cols)) : i;
          next = Math.min(next, flat.length - 1);
          break;
        case "p": case "P": if (cur) { e.preventDefault(); pick(cur, true); next = Math.min(flat.length - 1, i + 1); } break;
        case "x": case "X": if (cur) { e.preventDefault(); pick(cur, false); next = Math.min(flat.length - 1, i + 1); } break;
        case "h": case "H": if (cur) {
          e.preventDefault();
          const after = flat[i + 1] ?? flat[i - 1];
          hide(cur, !cur.hidden);
          if (!cur.hidden && !showHidden && after) reveal(after.id);
          return;
        } break;
        case " ": if (cur) { e.preventDefault(); pick(cur); } return;
        case "Home": next = 0; break;
        case "End": next = flat.length - 1; break;
        default: return;
      }
      if (next >= 0 && flat[next]) { e.preventDefault(); reveal(flat[next].id); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // Online gathering still running for this program (jobs that aren't hi-res or scans).
  const jobs = useJobs((s) => s.jobs);
  const gathering = [...jobs.values()].filter((j) => j.program === slug && (j.state === "running" || j.state === "queued") && j.group !== "hires" && j.group !== "scan");
  const scanning = [...jobs.values()].filter((j) => j.program === slug && (j.state === "running" || j.state === "queued") && j.group === "scan");
  const picked = all.filter((m) => m.picked);
  const pending = picked.filter((m) => m.hires === "queued" || m.hires === "running");
  const folded = all.length - [...stackSize.keys()].length;

  if (!program) return <div className="empty"><span className="spin" /> Loading…</div>;
  const set = (p: Partial<Filters>) => setF((x) => ({ ...x, ...p }));
  const toggleKind = (k: string) => setF((x) => { const kinds = new Set(x.kinds); kinds.has(k) ? kinds.delete(k) : kinds.add(k); return { ...x, kinds }; });
  const filtered = f.kinds.size || f.source !== "all" || f.minSize || f.subject || f.text || f.simple || f.picked;

  return (
    <div className={"s2" + (dockCollapsed ? " dock-min" : "") + (srcCollapsed ? " src-min" : "")}>
      <div className="filters">
        <div className="fg"><span className="fl">Kind</span>
          {kindsPresent.map(([k, n]) => <button key={k} className={"chip" + (f.kinds.has(k) ? " on" : "")} onClick={() => toggleKind(k)}>{kindLabel(k)} <span className="ct">{n}</span></button>)}
        </div>
        <div className="fg"><span className="fl">Source</span>
          <select className="text" value={f.source} onChange={(e) => set({ source: e.target.value })}>
            <option value="all">All sources</option>{sources.map((s) => <option key={s}>{s}</option>)}
          </select>
        </div>
        <div className="fg"><span className="fl">At least</span>
          <select className="text" value={f.minSize} onChange={(e) => set({ minSize: +e.target.value })}>
            {[[0, "Any size"], [256, "256 px"], [512, "512 px"], [1024, "1024 px"]].map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
        </div>
        <div className="fg">
          <button className={"chip" + (f.subject ? " on" : "")} onClick={() => set({ subject: !f.subject })}>Has subject</button>
          <button className={"chip" + (f.text ? " on" : "")} onClick={() => set({ text: !f.text })}>Has text</button>
          <button className={"chip" + (f.simple ? " on" : "")} onClick={() => set({ simple: !f.simple })}>Busyness ≤ moderate</button>
          <button className={"chip" + (f.picked ? " on" : "")} onClick={() => set({ picked: !f.picked })}>Picked</button>
          <label className="chip"><input type="checkbox" checked={f.hideDupes} onChange={(e) => set({ hideDupes: e.target.checked })} /> Fold duplicates</label>
          <label className="chip" title="Pictures you hid: they're never used in suggestions"><input type="checkbox" checked={showHidden} onChange={(e) => setShowHidden(e.target.checked)} /> Show hidden{hiddenCount ? <span className="ct">{hiddenCount}</span> : null}</label>
          <span className="fl" style={{ marginLeft: 6 }}>Thumbnails</span>
          <Seg value={thumbs} options={["whole", "parts"] as const} labels={{ whole: "Whole pictures", parts: "Parts" }} onChange={setThumbs} />
          {filtered ? <button className="btn small ghost" onClick={() => setF({ ...DEFAULT_FILTERS, sort: f.sort, hideDupes: f.hideDupes })}>Clear</button> : null}
        </div>
        <div className="fg" style={{ marginLeft: "auto" }}><span className="fl">Sort</span>
          <select className="text" value={f.sort} onChange={(e) => set({ sort: e.target.value as Sort })}>
            <option value="suitability">Suitability</option><option value="size">Size</option><option value="source">Source</option><option value="newest">Newest found</option>
          </select>
        </div>
      </div>

      <SourcesPanel slug={slug} media={all} selected={f.source} onSelect={(s) => set({ source: s })} collapsed={srcCollapsed} onToggle={toggleSources} />
      <div className="gridwrap" ref={scroller} role="grid" aria-label="Images">
        <div style={{ height: v.getTotalSize(), position: "relative" }}>
          {v.getVirtualItems().map((vi) => {
            const it = items[vi.index];
            return (
              <div key={vi.key} className="vrow" style={{ transform: `translateY(${vi.start}px)`, height: vi.size }}>
                {it.type === "head" ? (
                  <div className="groupt">
                    {it.group === "unrelated" ? (
                      <button className="linkish unrel" onClick={() => setShowUnrelated(!showUnrelated)} aria-expanded={showUnrelated}
                        title="Pictures from general searches that probably aren't of this program. They can still be picked.">
                        {showUnrelated ? "▾" : "▸"} Probably unrelated ({it.shown === it.total ? it.total : `${it.shown} of ${it.total}`})
                      </button>
                    ) : <>
                      {it.group === "local" ? "From your files" : "Online"}
                      <small>{it.shown === it.total ? `${it.total}` : `${it.shown} shown of ${it.total}`}</small>
                    </>}
                    {it.group === "local" && <>
                      {scanning.length > 0 && <span className="row muted" style={{ gap: 5, fontWeight: 400 }}><span className="spin" /> scanning</span>}
                      <button className="btn small" onClick={() => setFiles({ open: true, scan: null })}>Add from files…</button>
                    </>}
                    {it.group === "online" && gathering.length > 0 && <span className="row muted" style={{ gap: 5, fontWeight: 400 }}><span className="spin" /> {gatherText(gathering)}</span>}
                  </div>
                ) : it.type === "empty" ? (
                  <p className="faint empty-group">{it.group === "local"
                    ? (totals.local ? "Nothing here matches the filters." : "Nothing yet. Add a game's app, disc image, installer or folder: its own icons are often the best start.")
                    : (totals.online ? "Nothing here matches the filters." : gathering.length ? "Searching image sites…" : "Nothing found online.")}</p>
                ) : (
                  <div className="mrow" style={{ gridTemplateColumns: `repeat(${cols}, ${CARD}px)` }}>
                    {it.cards.map((m) => <MediaCard key={m.id} m={m} selected={m.id === selId} stack={f.hideDupes && rootOf.get(m.id) === m.id ? stackSize.get(m.id) ?? 1 : 1} thumbs={thumbs} onSelect={select} onPick={pick} onHide={hide} />)}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>

      <MediaInspector m={sel} all={all} onSelect={reveal} onEdit={setEditing} />
      {editing && <CutoutEditor req={editing} onClose={() => setEditing(null)} />}
      <ActivityDock slug={slug} collapsed={dockCollapsed} onToggle={() => setDockCollapsed(!dockCollapsed)} />

      {files.open && <FilesDialog slug={slug} scan={files.scan} onClose={() => setFiles({ open: false, scan: null })}
        onShowImages={() => {
          setFiles({ open: false, scan: null });
          setF({ ...DEFAULT_FILTERS, sort: "newest", hideDupes: f.hideDupes });
          const newest = [...all].reverse().find((m) => m.source === "Your files");
          if (newest) setSelId(newest.id);
          v.scrollToIndex(0);
        }} />}
      {waiting && <WaitingDialog slug={slug} pending={pending} onClose={() => setWaiting(false)} onContinue={() => { setWaiting(false); go(slug, "design"); }} />}

      <TitleActions.Fill>
        <button className="btn" onClick={() => setFiles({ open: true, scan: null })}>Add from files…</button>
        <button className="btn primary" disabled={!picked.length} title={picked.length ? "" : "Pick at least one image (P)"}
          onClick={() => (pending.length ? setWaiting(true) : go(slug, "design"))}>Design icon →</button>
      </TitleActions.Fill>
      <StatusSlot.Fill>
        <span>{picked.length} picked</span>
        <span>{all.length} images · {totals.local} from your files, {totals.online} online{folded > 0 ? `, ${folded} duplicates folded` : ""}</span>
        <span className="faint">←→↑↓ move · P pick · X unpick · Space toggles · H hide</span>
      </StatusSlot.Fill>
    </div>
  );
}

/** "Still gathering from Internet Archive (downloading 8 of 33) and 2 more" from the running gather jobs. */
function gatherText(jobs: { title: string; detail?: string; group?: string; state: string }[]) {
  const g = jobs.filter((j) => j.group === "gather");
  const running = g.filter((j) => j.state === "running");
  if (!g.length) return jobs.length === 1 ? (jobs[0].detail ?? jobs[0].title) : `${jobs.length} jobs`;
  const name = (t: string) => t.replace(/^Gather\s*·\s*/, "");
  const first = running[0] ?? g[0];
  const rest = g.length - 1;
  return `still gathering from ${name(first.title)}${first.detail ? ` (${first.detail.toLowerCase()})` : ""}${rest > 0 ? ` and ${rest} more` : ""}`;
}
