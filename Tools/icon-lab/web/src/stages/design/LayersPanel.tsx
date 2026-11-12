// The layers: up to four groups, front first, each with its layers and, nested under a layer, its masks. Select,
// hide, rename, duplicate, delete; drag to move a layer (or a group's layers to another group), or onto another layer
// to make it that layer's mask (and a mask out again to make it a layer). While a row is dragged the rows stay where
// they are, the dragged one greyed: the layer a drop would mask is outlined, and where a drop would move it is a line
// between rows. Tiles from the Add section and pictures from the computer can be dropped on a group, before the
// layer they're dropped on.
import { createContext, useContext, useEffect, useRef, useState } from "react";
import { DndContext, DragOverlay, PointerSensor, KeyboardSensor, useDraggable, useSensor, useSensors, type DragEndEvent, type DragMoveEvent, type DragStartEvent } from "@dnd-kit/core";
import type { Doc, Group, Layer } from "../../api";
import { canMask, findLayer, MAX_GROUPS } from "../../lib/doc";
import { resources } from "../../render/resources";
import { useDesign } from "../../state/design";
import { Menu, usePopup } from "../../components/Popup";
import { AddSection } from "./AddSection";
import { ResizeHandle } from "../../components/ResizeHandle";
import { copySelection, cutSelection, pasteFrom } from "./clipboard";
import { designDrag, layersFromDrop } from "../../lib/drop";
import { addGroup, insertLayers, clickLayer, deleteGroup, deleteLayer, deleteSelected, duplicateLayer, duplicateSelected, editLayer, lockMask, maskLayer, moveLayer, moveGroup, neighbours, selIds, unmaskLayer } from "./actions";

/** What dropping the dragged row would do: mask a layer, or move it to before `index` in a group (`index` the
 *  group's layer count for its back). Null does nothing. */
type Drop = { kind: "mask"; id: string } | { kind: "line"; group: string; index: number } | null;
const DropTarget = createContext<Drop>(null);

/** The drop at a point, read from where the rows are (they don't move during a drag). Over a layer's row, its top
 *  quarter is before it, its bottom quarter after it, and its middle masks it (or, if it can't, before or after it
 *  by which half); over its masks' rows, masks it too. Over a group's row, its front. */
function dropAt(doc: Doc, active: string, x: number, y: number): Drop {
  const hit = findLayer(doc, active);
  if (!hit) return null;
  const line = (group: string, index: number): Drop =>
    // next to where it already is: no move
    !hit.parent && group === hit.group.id && (index === hit.li || index === hit.li + 1) ? null : { kind: "line", group, index };
  // undefined: it can't mask that layer, so the drop is a move instead
  const mask = (id: string): Drop | undefined => (id === hit.parent?.id ? null : canMask(doc, active, id) ? { kind: "mask", id } : undefined);
  for (const gel of document.querySelectorAll<HTMLElement>(".layers [data-group]")) {
    const r = gel.getBoundingClientRect();
    if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
    const g = doc.groups.find((v) => v.id === gel.dataset.group);
    if (!g) return null;
    const head = gel.querySelector(".lr.g");
    if (head && y <= head.getBoundingClientRect().bottom) return line(g.id, 0);
    const wraps = [...gel.querySelectorAll<HTMLElement>("[data-layer-wrap]")];
    if (!wraps.length) return line(g.id, g.layers.length);   // empty, or folded: its back
    for (const [i, w] of wraps.entries()) {
      if (y > w.getBoundingClientRect().bottom) continue;
      const id = w.dataset.layerWrap ?? "";
      if (id === active) return null;
      const hr = w.querySelector("[data-layer-head]")?.getBoundingClientRect();
      if (!hr) return null;
      const q = hr.height / 4;
      if (y < hr.top + q) return line(g.id, i);
      const middle = y <= hr.bottom - q, overMasks = y > hr.bottom;
      if (middle || overMasks) {
        const m = mask(id);
        if (m !== undefined) return m;
        if (middle) return line(g.id, y < hr.top + hr.height / 2 ? i : i + 1);
      }
      return line(g.id, i + 1);
    }
    return line(g.id, g.layers.length);
  }
  return null;
}

const sameDrop = (a: Drop, b: Drop) => JSON.stringify(a) === JSON.stringify(b);

export function LayersPanel() {
  const doc = useDesign((s) => s.doc);
  const sel = useDesign((s) => s.sel);
  const [dragging, setDragging] = useState<string | null>(null);
  const [drop, setDrop] = useState<Drop>(null);
  const panel = useRef<HTMLElement>(null);
  const [addH, setAddHState] = useState(() => { try { return Number(localStorage.getItem("iconlab-addh")) || ADD_H; } catch { return ADD_H; } });
  const setAddH = (h: number) => { setAddHState(h); try { localStorage.setItem("iconlab-addh", String(Math.round(h))); } catch { /* fine */ } };
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor),
  );
  if (!doc) return <section className="panel layers" />;

  const onStart = (e: DragStartEvent) => { setDragging(String(e.active.id)); setDrop(null); useDesign.getState().select({ kind: "layer", id: String(e.active.id) }); };
  const onMove = (e: DragMoveEvent) => {
    // the pointer, or for the keyboard the dragged row's middle
    const p = e.activatorEvent as PointerEvent | MouseEvent | KeyboardEvent;
    const r = e.active.rect.current.translated;
    const at = "clientX" in p ? { x: p.clientX + e.delta.x, y: p.clientY + e.delta.y } : r ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : null;
    if (!at) return;
    const t = dropAt(useDesign.getState().doc!, String(e.active.id), at.x, at.y);
    if (!sameDrop(t, drop)) setDrop(t);
  };
  const onEnd = (e: DragEndEvent) => {
    setDragging(null);
    const target = drop;
    setDrop(null);
    if (!target) return;
    const st = useDesign.getState();
    const id = String(e.active.id);
    if (target.kind === "mask") { maskLayer(id, target.id); return; }
    const hit = findLayer(st.doc!, id);
    if (!hit) return;
    // moveLayer takes it out first, so a place further down its own group is one less
    const index = !hit.parent && hit.group.id === target.group && hit.li < target.index ? target.index - 1 : target.index;
    st.edit((x) => moveLayer(x, id, target.group, index));
  };

  const dragged = dragging ? findLayer(doc, dragging)?.layer : null;
  return (
    <section className="panel layers" ref={panel}>
      <div className="ph">Layers <small>{doc.groups.length} of {MAX_GROUPS} groups · front first</small></div>
      <div className="ltree">
      <div className="scroll" role="tree" aria-label="Layers">
        <DndContext sensors={sensors} onDragStart={onStart} onDragMove={onMove} onDragEnd={onEnd} onDragCancel={() => { setDragging(null); setDrop(null); }}>
          <DropTarget.Provider value={drop}>
          {doc.groups.map((g, i) => <GroupRows key={g.id} g={g} index={i} count={doc.groups.length} program={doc.program} selected={sel} />)}
          </DropTarget.Provider>
          <DragOverlay dropAnimation={null}>{dragged ? <div className="lr drag-overlay"><span /><LayerThumb program={doc.program} layer={dragged} /><span className="ellipsis">{dragged.name}{drop?.kind === "mask" ? <span className="faint"> · as a mask</span> : null}</span><span /></div> : null}</DragOverlay>
        </DndContext>
        <div className={"lr fill" + (sel?.kind === "icon" ? " on" : "")} onClick={() => useDesign.getState().select({ kind: "icon" })} role="treeitem">
          <span />
          <span className="mini" style={{ background: doc.fill.kind === "none" ? undefined : doc.fill.kind === "gradient" ? `linear-gradient(${doc.fill.color}, ${doc.fill.color}cc)` : doc.fill.color }} />
          <span className="ellipsis">Background <span className="faint">· {doc.fill.kind}</span></span>
          <span />
        </div>
      </div>
      <button className="add-group" disabled={doc.groups.length >= MAX_GROUPS} onClick={addGroup}
        title={doc.groups.length >= MAX_GROUPS ? "Icon Composer allows four groups" : "Add a group at the front"}>＋ Group</button>
      </div>
      <ResizeHandle label="Resize the Add section" height={addH} min={MIN_ADD} max={Math.max(MIN_ADD, (panel.current?.clientHeight ?? 800) - MIN_TREE - 80)} reset={ADD_H} onResize={setAddH} />
      <div className="addwrap" style={{ height: addH }}><AddSection slug={doc.program} /></div>
    </section>
  );
}

function GroupRows({ g, index, count, program, selected }: { g: Group; index: number; count: number; program: string; selected: ReturnType<typeof useDesign.getState>["sel"] }) {
  const [open, setOpen] = useState(true);
  const menu = usePopup();
  const on = selected?.kind === "group" && selected.id === g.id;
  const st = useDesign.getState;
  const drop = useContext(DropTarget);
  const lineAt = drop?.kind === "line" && drop.group === g.id ? drop.index : null;
  const isOn = (id: string) => (selected?.kind === "layer" && selected.id === id) || (selected?.kind === "layers" && selected.ids.includes(id));
  const [fileOver, setFileOver] = useState(false);
  // Dropped on a layer: before it; on the group's row: at the front; anywhere else in the group: at the back.
  const onDrop = (e: React.DragEvent) => {
    setFileOver(false);
    if (!designDrag(e.dataTransfer)) return;
    e.preventDefault();
    const row = (e.target as HTMLElement).closest("[data-layer-index]") as HTMLElement | null;
    const index = row ? Number(row.dataset.layerIndex) : (e.target as HTMLElement).closest(".lr.g") ? 0 : g.layers.length;
    void layersFromDrop(program, e.dataTransfer).then((layers) => insertLayers(layers, { group: g.id, index }));
  };
  return (
    <div data-group={g.id} className={"lgroup" + (fileOver ? " over" : "")}
      onDragOver={(e) => { if (designDrag(e.dataTransfer)) { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; setFileOver(true); } }}
      onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setFileOver(false); }} onDrop={onDrop}>
      <div className={"lr g" + (on ? " on" : "") + (!open && lineAt != null ? " mask-target" : "")} onClick={() => st().select({ kind: "group", id: g.id })} role="treeitem" aria-expanded={open}>
        <button className="icon-btn" onClick={(e) => { e.stopPropagation(); setOpen(!open); }} aria-label={open ? "Collapse" : "Expand"}>{open ? "▾" : "▸"}</button>
        <Rename value={g.name} onChange={(name) => st().edit((d) => { const x = d.groups.find((y) => y.id === g.id); if (x) x.name = name; })} />
        <span className="faint gbadge">{g.glass.specular ? "glass" : "flat"}{g.glass.shadow ? " · shadow" : ""}</span>
        <button className={"icon-btn" + (g.hidden ? " off" : "")} onClick={(e) => { e.stopPropagation(); st().edit((d) => { const x = d.groups.find((y) => y.id === g.id); if (x) x.hidden = !x.hidden || undefined; }); }} aria-label={g.hidden ? "Show group" : "Hide group"} title={g.hidden ? "Show" : "Hide"}>{g.hidden ? "◌" : "●"}</button>
        <button className="icon-btn" onClick={(e) => { e.stopPropagation(); menu.toggle(e.currentTarget); }} aria-label="Group menu">⋯</button>
        <Menu anchor={menu.anchor} onClose={menu.close} items={[
          { label: "Bring forward", onClick: () => moveGroup(g.id, -1), disabled: index === 0 },
          { label: "Send backward", onClick: () => moveGroup(g.id, 1), disabled: index === count - 1 },
          "-",
          { label: "Copy group", hint: "⌘C", onClick: () => { st().select({ kind: "group", id: g.id }); copySelection(); } },
          { label: "Cut group", hint: "⌘X", onClick: () => { st().select({ kind: "group", id: g.id }); cutSelection(); } },
          { label: "Paste", hint: "⌘V", onClick: () => { st().select({ kind: "group", id: g.id }); void pasteFrom(); } },
          "-",
          { label: "Delete group", onClick: () => deleteGroup(g.id) },
        ]} />
      </div>
      {open && (
        <>
          {g.layers.map((l, i) => <LayerRow key={l.id} index={i} l={l} program={program} on={isOn(l.id)} isOn={isOn} inGroup={on}
            line={lineAt === i ? "before" : lineAt === g.layers.length && i === g.layers.length - 1 ? "after" : undefined} />)}
          {!g.layers.length && <div className={"lr in faint empty-group" + (lineAt != null ? " mask-target" : "")}>Empty: drag a layer here</div>}
        </>
      )}
    </div>
  );
}

function LayerRow({ l, index, program, on, isOn, inGroup, line }: { l: Layer; index: number; program: string; on: boolean; isOn(id: string): boolean; inGroup?: boolean; line?: "before" | "after" }) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({ id: l.id });
  const menu = usePopup();
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => { if (on) ref.current?.scrollIntoView({ block: "nearest" }); }, [on]);
  const drop = useContext(DropTarget);
  const target = drop?.kind === "mask" && drop.id === l.id;
  const fx = l.content.kind === "image" ? l.content.effects.length : 0;
  const doc = useDesign((s) => s.doc);
  const near = doc && !l.masks?.length ? neighbours(doc, l.id) : { above: null, below: null };
  return (
    <div ref={setNodeRef} data-layer-wrap={l.id} className={"lwrap" + (isDragging ? " dragging" : "") + (line ? " drop-" + line : "")}>
    <div ref={ref} className={"lr in" + (on ? " on" : "") + (inGroup ? " ingroup" : "") + (l.hidden ? " hidden" : "") + (target ? " mask-target" : "")}
      onClick={(e) => clickLayer(l.id, e, "panel")} {...attributes} {...listeners} role="treeitem" aria-selected={on} data-layer-index={index} data-layer-head={l.id}
      title={target ? `Drop to mask “${l.name}” with it` : undefined}>
      <button className={"icon-btn" + (l.hidden ? " off" : "")} onClick={(e) => { e.stopPropagation(); editLayer(l.id, (x) => { x.hidden = !x.hidden || undefined; }); }} onPointerDown={(e) => e.stopPropagation()} aria-label={l.hidden ? "Show layer" : "Hide layer"}>{l.hidden ? "◌" : "●"}</button>
      <LayerThumb program={program} layer={l} />
      <span className="lname">
        <Rename value={l.name} onChange={(name) => editLayer(l.id, (x) => { x.name = name; })} />
        <span className="badges">
          {l.mask && <span className="tag" title={`Mask: ${l.mask.kind}`}>mask</span>}
          {!!l.masks?.length && <span className="tag" title="Shown only where its masks, nested under it, have pixels">masked</span>}
          {fx > 0 && <span className="tag" title="Effects">fx {fx}</span>}
          {l.opacity < 1 && <span className="tag">{Math.round(l.opacity * 100)}%</span>}
        </span>
      </span>
      <button className="icon-btn" onClick={(e) => { e.stopPropagation(); menu.toggle(e.currentTarget); }} onPointerDown={(e) => e.stopPropagation()} aria-label="Layer menu">⋯</button>
      <Menu anchor={menu.anchor} onClose={menu.close} items={[
        // Copy and cut take the row (and the rest of the selection when it's part of one).
        { label: "Copy", hint: "⌘C", onClick: () => { if (!on) clickLayer(l.id, {}, "panel"); copySelection(); } },
        { label: "Cut", hint: "⌘X", onClick: () => { if (!on) clickLayer(l.id, {}, "panel"); cutSelection(); } },
        { label: "Paste", hint: "⌘V", onClick: () => { if (!on) clickLayer(l.id, {}, "panel"); void pasteFrom(); } },
        "-",
        // On a row that's part of a multiple selection, they act on all of it.
        { label: on && selIds().length > 1 ? `Duplicate ${selIds().length} layers` : "Duplicate", hint: "⌘D", onClick: () => (on && selIds().length > 1 ? duplicateSelected() : duplicateLayer(l.id)) },
        { label: on && selIds().length > 1 ? `Delete ${selIds().length} layers` : "Delete", hint: "⌫", onClick: () => (on && selIds().length > 1 ? deleteSelected() : deleteLayer(l.id)) },
        // Using this layer to mask a neighbour, as dragging it onto that layer does.
        ...(near.above || near.below ? ["-" as const] : []),
        ...(near.above ? [{ label: "Mask the layer above", hint: near.above.name, onClick: () => maskLayer(l.id, near.above!.id) }] : []),
        ...(near.below ? [{ label: "Mask the layer below", hint: near.below.name, onClick: () => maskLayer(l.id, near.below!.id) }] : []),
      ]} />
    </div>
    {(l.masks ?? []).map((m) => <MaskRow key={m.id} m={m} parent={l} program={program} on={isOn(m.id)} />)}
    </div>
  );
}

/** A mask, nested under the layer it masks: drag it onto another layer to mask that one instead, or between layers
 *  to make it a layer of its own. */
function MaskRow({ m, parent, program, on }: { m: Layer; parent: Layer; program: string; on: boolean }) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({ id: m.id });
  const menu = usePopup();
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => { if (on) ref.current?.scrollIntoView({ block: "nearest" }); }, [on]);
  const locked = m.lock !== "canvas";
  const lockTitle = locked ? `Moves and scales with “${parent.name}”: click to place it on its own` : `Placed on its own: click to lock it to “${parent.name}”`;
  return (
    <div ref={(el) => { setNodeRef(el); ref.current = el; }} className={"lr in mask" + (on ? " on" : "") + (m.hidden ? " hidden" : "") + (isDragging ? " dragging" : "")}
      onClick={(e) => clickLayer(m.id, e, "panel")} {...attributes} {...listeners} role="treeitem" aria-selected={on} aria-level={3}>
      <button className={"icon-btn" + (m.hidden ? " off" : "")} onClick={(e) => { e.stopPropagation(); editLayer(m.id, (x) => { x.hidden = !x.hidden || undefined; }); }} onPointerDown={(e) => e.stopPropagation()} aria-label={m.hidden ? "Turn the mask on" : "Turn the mask off"} title={m.hidden ? "Off: click to mask with it again" : "Click to stop masking with it for now"}>{m.hidden ? "◌" : "●"}</button>
      <LayerThumb program={program} layer={m} size={24} />
      <span className="lname">
        <Rename value={m.name} onChange={(name) => editLayer(m.id, (x) => { x.name = name; })} />
        <span className="badges">
          <span className="tag" title={`Masks “${parent.name}”: it shows only where this has pixels${m.invert ? " (inverted: where this has none)" : ""}`}>{m.invert ? "mask, inverted" : "mask"}</span>
        </span>
      </span>
      <button className={"icon-btn lock" + (locked ? "" : " off")} onClick={(e) => { e.stopPropagation(); lockMask(m.id, !locked); }} onPointerDown={(e) => e.stopPropagation()}
        aria-label={locked ? "Unlock from the layer" : "Lock to the layer"} aria-pressed={locked} title={lockTitle}>{locked ? <LockIcon /> : <LockIcon open />}</button>
      <button className="icon-btn" onClick={(e) => { e.stopPropagation(); menu.toggle(e.currentTarget); }} onPointerDown={(e) => e.stopPropagation()} aria-label="Mask menu">⋯</button>
      <Menu anchor={menu.anchor} onClose={menu.close} items={[
        { label: locked ? "Unlock from the layer" : "Lock to the layer", onClick: () => lockMask(m.id, !locked) },
        { label: m.invert ? "Don't invert" : "Invert", onClick: () => editLayer(m.id, (x) => { x.invert = !x.invert || undefined; }) },
        "-",
        { label: "Stop masking", onClick: () => unmaskLayer(m.id) },
        { label: "Duplicate", hint: "⌘D", onClick: () => duplicateLayer(m.id) },
        { label: "Delete", hint: "⌫", onClick: () => deleteLayer(m.id) },
      ]} />
    </div>
  );
}

function LockIcon({ open }: { open?: boolean }) {
  return (
    <svg width="11" height="12" viewBox="0 0 11 12" aria-hidden fill="none" stroke="currentColor" strokeWidth="1.4">
      <rect x="1" y="5.5" width="9" height="6" rx="1.2" fill="currentColor" stroke="none" />
      <path d={open ? "M3 5.5V3.5a2.5 2.5 0 0 1 4.9-.7" : "M3 5.5V3.5a2.5 2.5 0 0 1 5 0v2"} />
    </svg>
  );
}

/** A name that becomes a text field on double-click. */
function Rename({ value, onChange }: { value: string; onChange(v: string): void }) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(value);
  if (!editing) return <span className="ellipsis" onDoubleClick={(e) => { e.stopPropagation(); setText(value); setEditing(true); }} title="Double-click to rename">{value}</span>;
  const done = () => { setEditing(false); if (text.trim() && text !== value) onChange(text.trim()); };
  return <input className="text" autoFocus value={text} onChange={(e) => setText(e.target.value)} onBlur={done}
    onPointerDown={(e) => e.stopPropagation()} onClick={(e) => e.stopPropagation()}
    onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter") done(); if (e.key === "Escape") setEditing(false); }} />;
}

export function LayerThumb({ program, layer, size = 30 }: { program: string; layer: Layer; size?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const draw = () => {
      const c = ref.current; if (!c) return;
      const pr = window.devicePixelRatio || 1, px = Math.round(size * pr);
      c.width = px; c.height = px;
      const g = c.getContext("2d")!;
      g.clearRect(0, 0, px, px);
      const got = layer.content.kind === "image" ? resources.content(program, layer.content, px * 1.5, layer.transform.width) : resources.shape(program, layer.content.shape, 64);
      if (!got) return;
      const iw = got.img.width, ih = got.img.height;
      const k = Math.min(px / iw, px / ih);
      g.imageSmoothingEnabled = !(layer.content.kind === "image" && layer.content.smoothing === "pixel");
      g.drawImage(got.img, (px - iw * k) / 2, (px - ih * k) / 2, iw * k, ih * k);
    };
    draw();
    return resources.subscribe(draw);
  }, [program, layer.content, layer.transform.width, size]);
  return <span className="mini checker" style={{ width: size, height: size }}><canvas ref={ref} style={{ width: size, height: size }} /></span>;
}

const ADD_H = 300, MIN_TREE = 120, MIN_ADD = 150;

