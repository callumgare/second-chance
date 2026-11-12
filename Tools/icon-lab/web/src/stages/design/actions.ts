// Edits the editor offers, as operations on the design store's doc.
import type { Doc, Layer, Media, Part, ShapeType } from "../../api";
import { findGroup, findLayer, layerIdsInOrder, makeMask, MAX_GROUPS, newGroup, newImageLayer, newPartLayer, newShapeLayer, placed, placedLayer, releaseMask, setMaskLock, setPlacedTransform, uid, withNewIds } from "../../lib/doc";
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

/** The selected layers' ids, front first (a mask after the layer it masks). */
export const selIds = () => { const st = d(); const ids = selectedLayerIds(st.doc, st.sel); const all = st.doc ? layerIdsInOrder(st.doc) : []; return all.filter((id) => ids.includes(id)); };

let rangeAnchor: string | null = null;
/** A click on a layer: plain selects it alone; ⌘ toggles it; ⇧ selects the range from the last clicked (in the
 * layers panel; on the canvas, ⇧ toggles as ⌘ does). */
export function clickLayer(id: string, mods: { shiftKey?: boolean; metaKey?: boolean; ctrlKey?: boolean }, where: "panel" | "canvas") {
  const st = d(); const doc = st.doc; if (!doc) return;
  const cur = selIds();
  if (mods.shiftKey && where === "panel" && rangeAnchor) {
    const all = layerIdsInOrder(doc);
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
  d().edit((doc) => ids.forEach((id, i) => duplicateIn(doc, id, copies[i])));
  d().select(layersSel(copies));
}

/** A copy of layer `id` (with its masks) just in front of it, a little down and to the right; a mask's copy masks
 *  the same layer. */
function duplicateIn(doc: Doc, id: string, copyId: string) {
  const hit = findLayer(doc, id); if (!hit) return;
  const c = withNewIds(hit.layer, copyId); c.name = hit.layer.name + " copy";
  const t = (hit.parent ? placed(hit.parent, hit.layer) : hit.layer).transform;
  if (hit.parent) { hit.parent.masks!.splice(hit.mi! + 1, 0, c); setPlacedTransform(doc, copyId, { ...t, x: t.x + 0.03, y: t.y + 0.03 }); }
  else { c.transform.x += 0.03; c.transform.y += 0.03; hit.group.layers.splice(hit.li, 0, c); }
}

/** Removes layer `id`, or the mask `id` from the layer it masks. */
function removeIn(doc: Doc, id: string) {
  const h = findLayer(doc, id); if (!h) return;
  if (!h.parent) { h.group.layers.splice(h.li, 1); return; }
  h.parent.masks!.splice(h.mi!, 1);
  if (!h.parent.masks!.length) delete h.parent.masks;
}

export function deleteSelected() {
  const ids = selIds(); if (!ids.length) return;
  if (ids.length === 1) { deleteLayer(ids[0]); return; }
  d().edit((doc) => { for (const id of ids) removeIn(doc, id); });
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
  d().edit((doc) => duplicateIn(doc, id, copyId));
  d().select({ kind: "layer", id: copyId });
}

export function deleteLayer(id: string) {
  const doc = d().doc; if (!doc) return;
  const hit = findLayer(doc, id); if (!hit) return;
  const next = hit.parent ?? hit.group.layers[hit.li + 1] ?? hit.group.layers[hit.li - 1];
  d().edit((x) => removeIn(x, id));
  d().select(next ? { kind: "layer", id: next.id } : { kind: "group", id: hit.group.id });
}

/** Makes layer `id` a mask of `targetId` (dragged onto it in the Layers panel, or from its menu) and selects it. */
export function maskLayer(id: string, targetId: string) {
  let ok = false;
  d().edit((doc) => { ok = makeMask(doc, id, targetId); });
  if (ok) d().select({ kind: "layer", id });
}

/** Makes mask `id` a layer of its own again, just behind the layer it masked. */
export function unmaskLayer(id: string) {
  d().edit((doc) => releaseMask(doc, id));
  d().select({ kind: "layer", id });
}

export function lockMask(id: string, locked: boolean) { d().edit((doc) => setMaskLock(doc, id, locked)); }

/** The layers just above and below `id` in the Layers panel (masks aside), across groups. */
export function neighbours(doc: Doc, id: string): { above: Layer | null; below: Layer | null } {
  const all = doc.groups.flatMap((g) => g.layers);
  const i = all.findIndex((l) => l.id === id);
  return { above: i > 0 ? all[i - 1] : null, below: i >= 0 ? all[i + 1] ?? null : null };
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

/** Moves a layer to `groupId` at `index` (front first). A mask moved there is a layer of its own again. */
export function moveLayer(doc: Doc, layerId: string, groupId: string, index: number) {
  const hit = findLayer(doc, layerId); const to = findGroup(doc, groupId);
  if (!hit || !to) return;
  let layer = hit.layer;
  if (hit.parent) {
    layer = { ...placed(hit.parent, hit.layer) }; delete layer.lock; delete layer.invert;
    removeIn(doc, layerId);
  } else hit.group.layers.splice(hit.li, 1);
  to.layers.splice(Math.max(0, Math.min(index, to.layers.length)), 0, layer);
}

export function nudge(dx: number, dy: number) {
  const ids = selIds(); if (!ids.length) return;
  d().edit((doc) => ids.forEach((id) => {
    // a mask locked to a layer that moves too moves with it
    const h = findLayer(doc, id); if (!h || (h.parent && h.layer.lock !== "canvas" && ids.includes(h.parent.id))) return;
    const t = placedLayer(doc, id)!.transform;
    setPlacedTransform(doc, id, { ...t, x: t.x + dx, y: t.y + dy });
  }), { transient: true });
  window.clearTimeout(nudgeTimer);
  nudgeTimer = window.setTimeout(() => d().commit(), 500);
}
let nudgeTimer: number | undefined;
