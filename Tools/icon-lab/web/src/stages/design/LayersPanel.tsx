// The layers: up to four groups, front first, each with its layers. Select, hide, rename, duplicate, delete;
// drag to reorder or move a layer to another group.
import { useEffect, useRef, useState } from "react";
import { DndContext, DragOverlay, PointerSensor, KeyboardSensor, useDroppable, useSensor, useSensors, closestCenter, type DragEndEvent, type DragOverEvent, type DragStartEvent } from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import type { Doc, Group, Layer } from "../../api";
import { findLayer, MAX_GROUPS } from "../../lib/doc";
import { resources } from "../../render/resources";
import { useDesign } from "../../state/design";
import { Menu, usePopup } from "../../components/Popup";
import { AddSection } from "./AddSection";
import { ResizeHandle } from "../../components/ResizeHandle";
import { copySelection, cutSelection, pasteFrom } from "./clipboard";
import { addGroup, clickLayer, deleteGroup, deleteLayer, deleteSelected, duplicateLayer, duplicateSelected, editLayer, moveGroup, moveLayer, selIds } from "./actions";

export function LayersPanel() {
  const doc = useDesign((s) => s.doc);
  const sel = useDesign((s) => s.sel);
  const [dragging, setDragging] = useState<string | null>(null);
  const panel = useRef<HTMLElement>(null);
  const [addH, setAddHState] = useState(() => { try { return Number(localStorage.getItem("iconlab-addh")) || ADD_H; } catch { return ADD_H; } });
  const setAddH = (h: number) => { setAddHState(h); try { localStorage.setItem("iconlab-addh", String(Math.round(h))); } catch { /* fine */ } };
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );
  if (!doc) return <section className="panel layers" />;

  const groupOf = (d: Doc, id: string) => (id.startsWith("group:") ? d.groups.find((g) => "group:" + g.id === id) : findLayer(d, id)?.group);

  const onStart = (e: DragStartEvent) => { setDragging(String(e.active.id)); useDesign.getState().select({ kind: "layer", id: String(e.active.id) }); };
  const onOver = (e: DragOverEvent) => {
    const { active, over } = e;
    if (!over) return;
    const d = useDesign.getState().doc!;
    const from = groupOf(d, String(active.id)), to = groupOf(d, String(over.id));
    if (!from || !to || from.id === to.id) return;
    const index = String(over.id).startsWith("group:") ? to.layers.length : to.layers.findIndex((l) => l.id === over.id);
    useDesign.getState().edit((x) => moveLayer(x, String(active.id), to.id, index), { transient: true });
  };
  const onEnd = (e: DragEndEvent) => {
    setDragging(null);
    const { active, over } = e;
    const st = useDesign.getState();
    if (over && !String(over.id).startsWith("group:") && active.id !== over.id) {
      const d = st.doc!;
      const to = groupOf(d, String(over.id));
      if (to) {
        const index = to.layers.findIndex((l) => l.id === over.id);
        st.edit((x) => moveLayer(x, String(active.id), to.id, index));
        return;
      }
    }
    st.commit();
  };

  const dragged = dragging ? findLayer(doc, dragging)?.layer : null;
  return (
    <section className="panel layers" ref={panel}>
      <div className="ph">Layers <small>{doc.groups.length} of {MAX_GROUPS} groups · front first</small></div>
      <div className="ltree">
      <div className="scroll" role="tree" aria-label="Layers">
        <DndContext sensors={sensors} collisionDetection={closestCenter} onDragStart={onStart} onDragOver={onOver} onDragEnd={onEnd} onDragCancel={() => { setDragging(null); useDesign.getState().commit(); }}>
          {doc.groups.map((g, i) => <GroupRows key={g.id} g={g} index={i} count={doc.groups.length} program={doc.program} selected={sel} />)}
          <DragOverlay dropAnimation={null}>{dragged ? <div className="lr drag-overlay"><span /><LayerThumb program={doc.program} layer={dragged} /><span className="ellipsis">{dragged.name}</span><span /></div> : null}</DragOverlay>
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
  const { setNodeRef, isOver } = useDroppable({ id: "group:" + g.id });
  const on = selected?.kind === "group" && selected.id === g.id;
  const st = useDesign.getState;
  return (
    <div ref={setNodeRef} className={"lgroup" + (isOver ? " over" : "")}>
      <div className={"lr g" + (on ? " on" : "")} onClick={() => st().select({ kind: "group", id: g.id })} role="treeitem" aria-expanded={open}>
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
        <SortableContext items={g.layers.map((l) => l.id)} strategy={verticalListSortingStrategy}>
          {g.layers.map((l) => <LayerRow key={l.id} l={l} program={program} on={(selected?.kind === "layer" && selected.id === l.id) || (selected?.kind === "layers" && selected.ids.includes(l.id))} inGroup={on} />)}
          {!g.layers.length && <div className="lr in faint empty-group">Empty: drag a layer here</div>}
        </SortableContext>
      )}
    </div>
  );
}

function LayerRow({ l, program, on, inGroup }: { l: Layer; program: string; on: boolean; inGroup?: boolean }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: l.id });
  const menu = usePopup();
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => { if (on) ref.current?.scrollIntoView({ block: "nearest" }); }, [on]);
  const fx = l.content.kind === "image" ? l.content.effects.length : 0;
  return (
    <div ref={(el) => { setNodeRef(el); ref.current = el; }} className={"lr in" + (on ? " on" : "") + (inGroup ? " ingroup" : "") + (l.hidden ? " hidden" : "")}
      style={{ transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.35 : undefined }}
      onClick={(e) => clickLayer(l.id, e, "panel")} {...attributes} {...listeners} role="treeitem" aria-selected={on}>
      <button className={"icon-btn" + (l.hidden ? " off" : "")} onClick={(e) => { e.stopPropagation(); editLayer(l.id, (x) => { x.hidden = !x.hidden || undefined; }); }} onPointerDown={(e) => e.stopPropagation()} aria-label={l.hidden ? "Show layer" : "Hide layer"}>{l.hidden ? "◌" : "●"}</button>
      <LayerThumb program={program} layer={l} />
      <span className="lname">
        <Rename value={l.name} onChange={(name) => editLayer(l.id, (x) => { x.name = name; })} />
        <span className="badges">
          {l.mask && <span className="tag" title={`Mask: ${l.mask.kind}`}>mask</span>}
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
      ]} />
    </div>
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

