// Edits the editor offers, as operations on the design store's doc.
import type { Doc, Layer, Media, Part, ShapeType } from "../../api";
import { clone, findGroup, findLayer, MAX_GROUPS, newGroup, newImageLayer, newPartLayer, newShapeLayer, uid } from "../../lib/doc";
import { useApp } from "../../state/app";
import { layersSel, selectedLayerIds, useDesign } from "../../state/design";

const d = () => useDesign.getState();

/** Edits made continuously (a colour picker being dragged) become one undo step once they settle. */
let liveTimer: number | undefined;
export function editLive(fn: (doc: Doc) => void) {
  d().edit(fn, { transient: true });
  window.clearTimeout(liveTimer);
  liveTimer = window.setTimeout(() => d().commit(), 450);
}

export function editLayer(id: string, fn: (l: Layer) => void, live = false) {
  const f = (doc: Doc) => { const hit = findLayer(doc, id); if (hit) fn(hit.layer); };
  if (live) editLive(f); else d().edit(f);
}

/** The group a new layer goes in: the selected layer's or group, else a new group at the front (if there's
 *  room), else the front group. */
function targetGroup(doc: Doc, newGroupName: string) {
  const sel = d().sel;
  if (sel?.kind === "layer") { const hit = findLayer(doc, sel.id); if (hit) return hit.group; }
  if (sel?.kind === "group") { const g = findGroup(doc, sel.id); if (g) return g; }
  if (doc.groups.length < MAX_GROUPS) { const g = newGroup(newGroupName); doc.groups.unshift(g); return g; }
  return doc.groups[0];
}

export function addPartLayer(m: Media, p: Part, at?: { x: number; y: number }, inNewGroup = false) {
  addLayer(newPartLayer(m, p, at), inNewGroup);
}

export function addMediaLayer(m: Media, at?: { x: number; y: number }, inNewGroup = false) {
  addLayer(newImageLayer(m, at), inNewGroup);
}

function addLayer(layer: Layer, inNewGroup: boolean) {
  d().edit((doc) => {
    let g;
    if (inNewGroup && doc.groups.length < MAX_GROUPS) { g = newGroup(layer.name.slice(0, 20)); doc.groups.unshift(g); }
    else g = targetGroup(doc, layer.name.slice(0, 20));
    g.layers.unshift(layer);
  });
  d().select({ kind: "layer", id: layer.id });
}

/** Puts dropped layers in: into a group at an index (the Layers panel), or as a click adds them (each image in a new
 *  group of its own on the canvas). The first is selected. */
export function insertLayers(layers: Layer[], where?: { group: string; index: number }) {
  if (!layers.length) return;
  if (!where) { for (const l of [...layers].reverse()) addLayer(l, l.content.kind === "image"); }
  else d().edit((doc) => {
    const g = findGroup(doc, where.group) ?? targetGroup(doc, layers[0].name.slice(0, 20));
    g.layers.splice(Math.max(0, Math.min(where.index, g.layers.length)), 0, ...layers);
  });
  d().select({ kind: "layer", id: layers[0].id });
}

export function addShapeLayer(type: ShapeType) {
  const colours = useApp.getState().program?.colours ?? {};
  const layer = newShapeLayer(type, colours.striking, colours["second striking"]);
  d().edit((doc) => targetGroup(doc, layer.name).layers.unshift(layer));
  d().select({ kind: "layer", id: layer.id });
}

export function addGroup() {
  const g = newGroup(`Group ${d().doc!.groups.length + 1}`);
  d().edit((doc) => { if (doc.groups.length < MAX_GROUPS) doc.groups.unshift(g); });
  d().select({ kind: "group", id: g.id });
}

/** The selected layers' ids, front first. */
export const selIds = () => { const st = d(); const ids = selectedLayerIds(st.doc, st.sel); const all = st.doc?.groups.flatMap((g) => g.layers.map((l) => l.id)) ?? []; return all.filter((id) => ids.includes(id)); };

let rangeAnchor: string | null = null;
/** A click on a layer: plain selects it alone; ⌘ toggles it; ⇧ selects the range from the last clicked (in the
 * layers panel; on the canvas, ⇧ toggles as ⌘ does). */
export function clickLayer(id: string, mods: { shiftKey?: boolean; metaKey?: boolean; ctrlKey?: boolean }, where: "panel" | "canvas") {
  const st = d(); const doc = st.doc; if (!doc) return;
  const cur = selIds();
  if (mods.shiftKey && where === "panel" && rangeAnchor) {
    const all = doc.groups.flatMap((g) => g.layers.map((l) => l.id));
    const a = all.indexOf(rangeAnchor), b = all.indexOf(id);
    if (a >= 0 && b >= 0) { st.select(layersSel(all.slice(Math.min(a, b), Math.max(a, b) + 1))); return; }
  }
  rangeAnchor = id;
  if (mods.metaKey || mods.ctrlKey || mods.shiftKey) st.select(layersSel(cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  else st.select({ kind: "layer", id });
}

/** Duplicates every selected layer (each just in front of itself) and selects the copies. */
export function duplicateSelected() {
  const ids = selIds(); if (!ids.length) return;
  const copies = ids.map(() => uid());
  d().edit((doc) => ids.forEach((id, i) => {
    const hit = findLayer(doc, id); if (!hit) return;
    const c = clone(hit.layer); c.id = copies[i]; c.name = hit.layer.name + " copy";
    c.transform.x += 0.03; c.transform.y += 0.03;
    hit.group.layers.splice(hit.li, 0, c);
  }));
  d().select(layersSel(copies));
}

export function deleteSelected() {
  const ids = selIds(); if (!ids.length) return;
  if (ids.length === 1) { deleteLayer(ids[0]); return; }
  d().edit((doc) => { for (const g of doc.groups) g.layers = g.layers.filter((l) => !ids.includes(l.id)); });
  d().select({ kind: "icon" });
}

/** Hides every selected layer, or shows them all when they're all hidden already. */
export function toggleHiddenSelected() {
  const st = d(); const ids = selIds(); if (!ids.length || !st.doc) return;
  const doc = st.doc;
  const allHidden = ids.every((id) => findLayer(doc, id)?.layer.hidden);
  st.edit((x) => ids.forEach((id) => { const h = findLayer(x, id); if (h) h.layer.hidden = allHidden ? undefined : true; }));
}

export function duplicateLayer(id: string) {
  const copyId = uid();
  d().edit((doc) => {
    const hit = findLayer(doc, id); if (!hit) return;
    const c = clone(hit.layer); c.id = copyId; c.name = hit.layer.name + " copy";
    c.transform.x += 0.03; c.transform.y += 0.03;
    hit.group.layers.splice(hit.li, 0, c);
  });
  d().select({ kind: "layer", id: copyId });
}

export function deleteLayer(id: string) {
  const doc = d().doc; if (!doc) return;
  const hit = findLayer(doc, id); if (!hit) return;
  const next = hit.group.layers[hit.li + 1] ?? hit.group.layers[hit.li - 1];
  d().edit((x) => { const h = findLayer(x, id); if (h) h.group.layers.splice(h.li, 1); });
  d().select(next ? { kind: "layer", id: next.id } : { kind: "group", id: hit.group.id });
}

export function deleteGroup(id: string) {
  d().edit((doc) => { doc.groups = doc.groups.filter((g) => g.id !== id); });
  d().select({ kind: "icon" });
}

export function moveGroup(id: string, by: number) {
  d().edit((doc) => {
    const i = doc.groups.findIndex((g) => g.id === id), j = i + by;
    if (i < 0 || j < 0 || j >= doc.groups.length) return;
    const [g] = doc.groups.splice(i, 1); doc.groups.splice(j, 0, g);
  });
}

/** Moves a layer to `groupId` at `index` (front first). */
export function moveLayer(doc: Doc, layerId: string, groupId: string, index: number) {
  const hit = findLayer(doc, layerId); const to = findGroup(doc, groupId);
  if (!hit || !to) return;
  hit.group.layers.splice(hit.li, 1);
  to.layers.splice(Math.max(0, Math.min(index, to.layers.length)), 0, hit.layer);
}

export function nudge(dx: number, dy: number) {
  const ids = selIds(); if (!ids.length) return;
  d().edit((doc) => ids.forEach((id) => { const h = findLayer(doc, id); if (h) { h.layer.transform.x += dx; h.layer.transform.y += dy; } }), { transient: true });
  window.clearTimeout(nudgeTimer);
  nudgeTimer = window.setTimeout(() => d().commit(), 500);
}
let nudgeTimer: number | undefined;
