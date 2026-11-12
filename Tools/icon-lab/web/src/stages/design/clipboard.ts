// Copy, cut and paste of layers: kept here, and written to the system clipboard as JSON with a marker so a copy
// survives a reload and passes between tabs. Anything on the clipboard without the marker is ignored.
import type { Doc, Group, Layer } from "../../api";
import { clone, findGroup, MAX_GROUPS, newGroup, placedLayer, uid, withNewIds, findLayer } from "../../lib/doc";
import { useApp } from "../../state/app";
import { layersSel, useDesign } from "../../state/design";
import { deleteGroup, deleteSelected, selIds } from "./actions";
import { copyText, readText } from "../../host";

const MARK = "icon-lab/layers@1";
type Clip = { mark: typeof MARK; program: string; doc: string; group: Group | null; layers: Layer[] };
let clip: Clip | null = null;

const d = () => useDesign.getState();
const say = (t: string, kind: "info" | "error" = "info") => useApp.getState().say(t, kind);
/** Layers that name an asset (an image, or an image mask): the engine resolves assets per program. */
const usesAssets = (l: Layer) => JSON.stringify(l).includes('"asset"');

function current(): Clip | null {
  const st = d(); const doc = st.doc; if (!doc) return null;
  if (st.sel?.kind === "group") {
    const g = findGroup(doc, st.sel.id); if (!g) return null;
    return { mark: MARK, program: doc.program, doc: doc.id, group: clone(g), layers: clone(g.layers) };
  }
  // a mask is copied as a layer of its own, where it is on the canvas
  const layers = selIds().map((id) => { const l = placedLayer(doc, id); if (!l) return null; const { lock: _l, invert: _i, ...rest } = l; return rest as Layer; }).filter((l): l is Layer => !!l);
  return layers.length ? { mark: MARK, program: doc.program, doc: doc.id, group: null, layers: clone(layers) } : null;
}

const parse = (text: string | undefined | null): Clip | null => {
  if (!text || !text.includes(MARK)) return null;
  try { const c = JSON.parse(text) as Clip; return c?.mark === MARK && Array.isArray(c.layers) ? c : null; } catch { return null; }
};

/** Copies the selection; `data` is the copy event's clipboard when there is one, else the async clipboard. */
export function copySelection(data?: DataTransfer | null): boolean {
  const c = current(); if (!c) return false;
  clip = c;
  const text = JSON.stringify(c);
  if (data) data.setData("text/plain", text);
  else void copyText(text); // when it can't, the in-app copy still works
  return true;
}

export function cutSelection(data?: DataTransfer | null) {
  const st = d();
  const group = st.sel?.kind === "group" ? st.sel.id : null;
  if (!copySelection(data)) return false;
  if (group) deleteGroup(group); else deleteSelected();
  return true;
}

/** Pastes `text` when it's ours, else what was copied here. */
export async function pasteFrom(text?: string | null) {
  let c = parse(text);
  // Without permission to read it, readText is null and ours is used.
  if (!c && text === undefined) c = parse(await readText());
  c = c ?? clip;
  if (!c) return false;
  paste(c);
  return true;
}

function paste(c: Clip) {
  const st = d(); const doc = st.doc; if (!doc) return;
  let layers = c.layers;
  if (c.program !== doc.program) {
    const ok = layers.filter((l) => !usesAssets(l));
    if (!ok.length) { say("Image layers can only be pasted into a design for the same program.", "error"); return; }
    if (ok.length < layers.length) say(`Pasted ${ok.length} of ${layers.length} layers: image layers can only be pasted into the same program's designs.`);
    layers = ok;
  }
  const off = c.doc === doc.id ? 0.02 : 0;
  const fresh = layers.map((l) => { const x = withNewIds(l); x.name = l.name + " copy"; x.transform = { ...x.transform, x: x.transform.x + off, y: x.transform.y + off }; return x; });
  const ids = fresh.map((l) => l.id);
  const sel = st.sel;
  const asGroup = !!c.group && doc.groups.length < MAX_GROUPS;
  if (c.group && !asGroup) say(`A design has at most ${MAX_GROUPS} groups, so the group's layers were pasted into an existing one.`);
  st.edit((x: Doc) => {
    // Where the selection is: its group (or the first), just above its frontmost selected layer.
    const first = sel?.kind === "layer" ? sel.id : sel?.kind === "layers" ? sel.ids[0] : null;
    const hit = first ? findLayer(x, first) : null;
    const gi = hit ? x.groups.indexOf(hit.group) : sel?.kind === "group" ? x.groups.findIndex((g) => g.id === sel.id) : 0;
    if (asGroup && c.group) {
      const g: Group = { ...clone(c.group), id: uid(), name: c.group.name + " copy", layers: fresh };
      x.groups.splice(Math.max(0, gi), 0, g);
      return;
    }
    let g = x.groups[Math.max(0, gi)];
    if (!g) { g = newGroup(); x.groups.push(g); }
    const at = hit && hit.group === g ? hit.li : 0;
    g.layers.splice(at, 0, ...fresh);
  });
  st.select(layersSel(ids));
}

/** ⌘C / ⌘X / ⌘V on the design page, outside text fields. */
export function installClipboard(): () => void {
  const typing = (t: EventTarget | null) => t instanceof HTMLElement && !!t.closest("input, textarea, select, [contenteditable]");
  const copy = (e: ClipboardEvent) => { if (typing(e.target) || window.getSelection()?.toString()) return; if (copySelection(e.clipboardData)) e.preventDefault(); };
  const cut = (e: ClipboardEvent) => { if (typing(e.target) || window.getSelection()?.toString()) return; if (cutSelection(e.clipboardData)) e.preventDefault(); };
  const pasteE = (e: ClipboardEvent) => { if (typing(e.target)) return; e.preventDefault(); void pasteFrom(e.clipboardData?.getData("text/plain") ?? null); };
  document.addEventListener("copy", copy); document.addEventListener("cut", cut); document.addEventListener("paste", pasteE);
  return () => { document.removeEventListener("copy", copy); document.removeEventListener("cut", cut); document.removeEventListener("paste", pasteE); };
}
