// The bottom of the Layers panel: what can be added as a layer. Picked parts; every part of every picture
// (adding one doesn't pick it: picking stays a choice made in Gather); shapes and text drawn with the program's
// colours. Drag onto the canvas, or click to add to the selected group.
import { useEffect, useMemo, useRef, useState } from "react";
import type { Media, Part, ShapeType } from "../../api";
import { defaultShape, SHAPE_LABELS } from "../../lib/doc";
import { PartImg } from "../../parts/PartImage";
import { timeOrder } from "../../parts/frames";
import { renderShape } from "../../mock/raster";
import { useApp } from "../../state/app";
import { kindLabel } from "../gather/MediaCard";
import { addPartLayer, addShapeLayer } from "./actions";

export const PART_DRAG = "application/x-iconlab-part";
export const SHAPE_DRAG = "application/x-iconlab-shape";

const SHAPES: ShapeType[] = ["solid", "gradient", "pattern", "bands", "circle", "rounded-rect", "window", "crt", "disc-rims", "text"];
type Tab = "images" | "shapes";
type Which = "picked" | "all";
type GroupBy = "none" | "picture" | "kind" | "source";

function stored<T extends string>(key: string, fallback: T): [T, (v: T) => void] {
  const [v, setV] = useState<T>(() => { try { return (localStorage.getItem(key) as T) || fallback; } catch { return fallback; } });
  return [v, (x: T) => { setV(x); try { localStorage.setItem(key, x); } catch { /* fine */ } }];
}

export function AddSection({ slug }: { slug: string }) {
  const [tab, setTab] = stored<Tab>("iconlab-addtab2", "images");
  return (
    <div className="addsec">
      <div className="addtabs" role="tablist" aria-label="Add a layer">
        {([["images", "Images"], ["shapes", "Shapes & text"]] as const).map(([t, l]) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "on" : ""} onClick={() => setTab(t)}>{l}</button>
        ))}
      </div>
      <div className="addbody scroll">
        {tab === "images" ? <Images slug={slug} /> : <Shapes />}
      </div>
    </div>
  );
}

function PartTile({ m, p, label }: { m: Media; p: Part; label: string }) {
  return (
    <button className="addtile checker" draggable title={`${label}\n${p.size[0]}×${p.size[1]} · ${m.source}${p.picked ? " · picked" : ""}\nDrag onto the canvas, or click to add`}
      onDragStart={(e) => { e.dataTransfer.setData(PART_DRAG, `${m.id}/${p.id}`); e.dataTransfer.effectAllowed = "copy"; }}
      onClick={() => addPartLayer(m, p)}>
      <PartImg m={m} p={p} max={256} />
      <span className="k">{label}</span>
    </button>
  );
}

const partKind = (m: Media, p: Part) => (p.id === "whole" ? m.kind : p.kind);
const partLabel = (m: Media, p: Part) => (p.id === "whole" ? (m.kind !== "unknown" ? kindLabel(m.kind) : "Whole picture") : p.name);
const pictureLabel = (m: Media) => (m.kind !== "unknown" ? kindLabel(m.kind) : m.name);

/** Parts to add: the picked ones (default) or every part of every picture, grouped as chosen, with a search.
 *  Adding one doesn't pick it: picking stays a choice made in Gather. */
function Images({ slug }: { slug: string }) {
  const all = useApp((s) => s.program?.media);
  const [which, setWhich] = stored<Which>("iconlab-add-which", "picked");
  const [groupBy, setGroupBy] = stored<GroupBy>("iconlab-add-group", "none");
  const [q, setQ] = useState("");
  const items = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return (all ?? []).filter((m) => !m.hidden && (which === "picked" || !m.duplicateOf))
      .flatMap((m) => timeOrder(m).map((p) => ({ m, p })))
      .filter(({ m, p }) => (which === "all" || p.picked)
        && (!needle || [p.name, m.name, m.source, kindLabel(partKind(m, p))].some((s) => s.toLowerCase().includes(needle))))
      // Pictures with picks first, then by suitability; a picture's own parts (a video's frames) keep their order.
      .sort((a, b) => Number(!!b.m.parts?.some((x) => x.picked)) - Number(!!a.m.parts?.some((x) => x.picked)) || b.m.suitability - a.m.suitability || (a.m.id < b.m.id ? -1 : a.m.id > b.m.id ? 1 : 0));
  }, [all, which, q]);
  const groups = useMemo(() => {
    if (groupBy === "none") return [{ key: "all", label: "", items }];
    const by = new Map<string, { key: string; label: string; items: typeof items }>();
    for (const it of items) {
      const [key, label] = groupBy === "picture" ? [it.m.id, `${pictureLabel(it.m)} · ${it.m.source}`]
        : groupBy === "kind" ? [partKind(it.m, it.p), partKind(it.m, it.p) === "unknown" ? "No kind" : kindLabel(partKind(it.m, it.p))]
        : [it.m.source, it.m.source];
      const g = by.get(key) ?? { key, label, items: [] };
      g.items.push(it);
      by.set(key, g);
    }
    return [...by.values()];
  }, [items, groupBy]);
  return (
    <>
      <div className="row addctl">
        <span className="seg" role="radiogroup" aria-label="Which parts">
          {([["picked", "Picked"], ["all", "All"]] as const).map(([v, l]) => (
            <button key={v} role="radio" aria-checked={which === v} className={which === v ? "on" : ""} onClick={() => setWhich(v)}>{l}</button>
          ))}
        </span>
        <select className="text" value={groupBy} onChange={(e) => setGroupBy(e.target.value as GroupBy)} aria-label="Group by" title="Group by">
          <option value="none">No groups</option>
          <option value="picture">By picture</option>
          <option value="kind">By kind</option>
          <option value="source">By source</option>
        </select>
      </div>
      {(which === "all" || items.length > 9) && (
        <input className="text addsearch" placeholder="Search parts" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.stopPropagation()} aria-label="Search parts" />
      )}
      {groups.map((g) => (
        <div key={g.key} className="addgroup">
          {g.label && <div className="addgh wraps">{g.label} <span className="faint">{g.items.length}</span></div>}
          <div className="addgrid">{g.items.map(({ m, p }) => <PartTile key={m.id + "/" + p.id} m={m} p={p} label={partLabel(m, p)} />)}</div>
        </div>
      ))}
      {!items.length && (which === "picked"
        ? <div className="empty">Nothing picked yet. <a href={`#/p/${encodeURIComponent(slug)}/gather`}>Gather images</a>, or choose All.</div>
        : <div className="empty">No parts match.</div>)}
    </>
  );
}

function Shapes() {
  const colours = useApp((s) => s.program?.colours);
  return (
    <div className="addgrid">
      {SHAPES.map((t) => <ShapeTile key={t} type={t} primary={colours?.striking} secondary={colours?.["second striking"] ?? colours?.lightest} />)}
    </div>
  );
}

function ShapeTile({ type, primary, secondary }: { type: ShapeType; primary?: string; secondary?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current; if (!c) return;
    const s = renderShape(defaultShape(type, primary, secondary), 128);
    c.width = 128; c.height = 128;
    c.getContext("2d")!.drawImage(s, 0, 0);
  }, [type, primary, secondary]);
  return (
    <button className="addtile checker" draggable title={`${SHAPE_LABELS[type]}\nDrag onto the canvas, or click to add`}
      onDragStart={(e) => { e.dataTransfer.setData(SHAPE_DRAG, type); e.dataTransfer.effectAllowed = "copy"; }}
      onClick={() => addShapeLayer(type)}>
      <canvas ref={ref} />
      <span className="k">{SHAPE_LABELS[type]}</span>
    </button>
  );
}
