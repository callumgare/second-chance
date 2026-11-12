// The inspector shows what's selected: a layer (placement, opacity, content, effects, masks) or a mask, a group (its
// glass) or the icon (its fill).
import type { Doc, Group, Layer, Media, Role, Transform } from "../../../api";
import { findGroup, findLayer, placedLayer, setPlacedTransform } from "../../../lib/doc";
import { useApp } from "../../../state/app";
import { useDesign } from "../../../state/design";
import { ColourField, NumberField, Seg, Slider, Toggle } from "../../../components/controls";
import { deleteSelected, editLive, lockMask, selIds, toggleHiddenSelected, unmaskLayer } from "../actions";
import { ColourRow, EffectsEditor, MaskEditor, ShapeEditor, type Update } from "./parts";
import { LayerThumb } from "../LayersPanel";
import { UpscaleSection } from "./Upscale";
import { CurrentPart, InspectorSubpage, PartChooser } from "./Subpage";
import { useCallback, useEffect, useState } from "react";
import { XYPad } from "../../../components/XYPad";

const commit = () => useDesign.getState().commit();

function editor(): Update<Doc> {
  return (fn, live) => {
    if (live) editLive((d) => { fn(d); });
    else useDesign.getState().edit((d) => { fn(d); });
  };
}

type Sub = "image" | "mask" | number | null; // number: a mask effect's index

/** Whether a part can be used as a silhouette: a cut-out, or a picture with transparency of its own. */
const silhouetteOK = (m: Media, p: { hasMask: boolean; id: string }) => p.hasMask || !!m.analysis.hasAlpha;

export function Inspector() {
  const doc = useDesign((s) => s.doc);
  const sel = useDesign((s) => s.sel);
  const [sub, setSub] = useState<Sub>(null);
  const selKey = sel ? sel.kind + ":" + ("id" in sel ? sel.id : "ids" in sel ? sel.ids.join(",") : "") : "";
  useEffect(() => setSub(null), [selKey]);
  const back = useCallback(() => setSub(null), []);
  if (!doc) return <section className="panel inspector" />;
  const hit = sel?.kind === "layer" ? findLayer(doc, sel.id) : null;
  const group = sel?.kind === "group" ? findGroup(doc, sel.id) : null;
  if (hit && sub) {
    const l = hit.layer, c = l.content;
    const edit = (fn: (x: Layer) => void) => useDesign.getState().edit((d) => { const h = findLayer(d, l.id); if (h) fn(h.layer); });
    return (
      <section className="panel inspector">
        {sub === "image" && c.kind === "image" ? (
          <InspectorSubpage title={`Image for “${l.name}”`} onBack={back}>
            <PartChooser value={c.asset} filter={(_m, p) => p.picked} showCurrent note="The parts picked in Gather. Pick more there to see them here."
              onChoose={(a) => edit((x) => { if (x.content.kind === "image") { x.content.asset = a; x.content.crop = null; if (a.includes("/")) x.content.cutout = false; } })} />
          </InspectorSubpage>
        ) : typeof sub === "number" && c.kind === "image" && c.effects[sub]?.op === "mask" && (c.effects[sub] as any).mask.kind === "image" ? (
          <InspectorSubpage title={`Silhouette masking “${l.name}”`} onBack={back}>
            <PartChooser value={(c.effects[sub] as any).mask.asset} filter={silhouetteOK} note="Cut-outs, and pictures with transparency of their own: the layer shows only where the chosen one has pixels."
              onChoose={(a) => edit((x) => { const fx = x.content.kind === "image" ? x.content.effects[sub] : null; if (fx?.op === "mask" && fx.mask.kind === "image") fx.mask.asset = a; })} />
          </InspectorSubpage>
        ) : sub === "mask" && l.mask?.kind === "image" ? (
          <InspectorSubpage title={`Silhouette masking “${l.name}”`} onBack={back}>
            <PartChooser value={l.mask.asset} filter={silhouetteOK} note="Cut-outs, and pictures with transparency of their own: the layer shows only where the chosen one has pixels."
              onChoose={(a) => edit((x) => { if (x.mask?.kind === "image") x.mask.asset = a; })} />
          </InspectorSubpage>
        ) : <InspectorSubpage title="" onBack={back}><div className="empty">Nothing to choose here.</div></InspectorSubpage>}
      </section>
    );
  }
  return (
    <section className="panel inspector">
      {hit ? <LayerInspector doc={doc} layer={hit.layer} group={hit.group} parent={hit.parent} onSub={setSub} />
        : sel?.kind === "layers" ? <SelectionSummary doc={doc} />
        : group ? <><SelectionSummary doc={doc} group /><GroupInspector group={group} /></>
        : <IconInspector doc={doc} />}
    </section>
  );
}

/** Several layers (or a group's) selected: how many, and what applies to them all. */
function SelectionSummary({ doc, group }: { doc: Doc; group?: boolean }) {
  const ids = selIds();
  const layers = ids.map((id) => findLayer(doc, id)?.layer).filter((l): l is Layer => !!l);
  if (!layers.length) return null;
  const opacity = layers.reduce((a, l) => a + l.opacity, 0) / layers.length;
  const same = layers.every((l) => Math.abs(l.opacity - layers[0].opacity) < 0.005);
  const allHidden = layers.every((l) => l.hidden);
  const setOpacity = (v: number) => editLive((d) => ids.forEach((id) => { const h = findLayer(d, id); if (h) h.layer.opacity = v; }));
  return (
    <div className="insp sel-summary">
      <div className="sec">{layers.length === 1 ? "1 layer" : `${layers.length} layers`}{group ? " in this group" : " selected"}</div>
      <Slider label={same ? "Opacity" : "Opacity (mixed)"} value={opacity} min={0} max={1} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={setOpacity} onCommit={commit} />
      <div className="row" style={{ gap: 6 }}>
        <button className="btn small" onClick={toggleHiddenSelected} title="Hide or show them all (H)">{allHidden ? "Show all" : "Hide all"}</button>
        {!group && <button className="btn small" onClick={deleteSelected} title="Delete them all (⌫)">Delete {layers.length} layers</button>}
      </div>
      {!group && <p className="faint note">Drag the box on the canvas to move them together, or a corner to scale them. ⇧ or ⌘-click a layer to add or remove it.</p>}
    </div>
  );
}

const ROLES: Role[] = ["subject", "logo", "backdrop", "pattern", "frame", "icon", "disc", "decoration"];

function LayerInspector({ doc, layer, group, parent, onSub }: { doc: Doc; layer: Layer; group: Group; parent?: Layer; onSub(s: Sub): void }) {
  const mediaMap = useApp((s) => s.media);
  const edit = editor();
  const upd: Update<Layer> = (fn, live) => edit((d) => { const h = findLayer(d, layer.id); if (h) { const r = fn(h.layer); if (r) Object.assign(h.layer, r); } }, live);
  // Placement is where the layer is on the canvas: a locked mask's own transform is relative to the layer it masks.
  const t = placedLayer(doc, layer.id)?.transform ?? layer.transform;
  const place = (fn: (t: Transform) => void, live = false) => edit((d) => {
    const cur = placedLayer(d, layer.id); if (!cur) return;
    const nt = { ...cur.transform }; fn(nt); setPlacedTransform(d, layer.id, nt);
  }, live);
  const setT = (k: keyof Transform, v: number, live = false) => place((x) => { x[k] = v; }, live);
  const locked = !!parent && layer.lock !== "canvas";
  const c = layer.content;
  // An old document's layer.mask shows as a canvas-locked mask effect; the first edit moves it there for good.
  const shownEffects = c.kind === "image" ? (layer.mask ? [...c.effects, { op: "mask" as const, mask: layer.mask, lock: "canvas" as const }] : c.effects) : [];
  const m = c.kind === "image" ? mediaMap.get(c.asset.split("/")[0].replace(/@(x4|px4)$/, "")) : undefined;
  return (
    <div className="insp">
      <div className="row" style={{ alignItems: "flex-start" }}>
        <LayerThumb program={doc.program} layer={layer} size={44} />
        <div className="col" style={{ gap: 2, minWidth: 0, flex: 1 }}>
          <b className="wraps">{layer.name}</b>
          <span className="faint wraps" style={{ fontSize: 11 }}>
            {parent
              ? <>masking <a href="#" onClick={(e) => { e.preventDefault(); useDesign.getState().select({ kind: "layer", id: parent.id }); }}>{parent.name}</a></>
              : <>in <a href="#" onClick={(e) => { e.preventDefault(); useDesign.getState().select({ kind: "group", id: group.id }); }}>{group.name}</a></>}
            {m && <> · {m.kind.replace("-", " ")}, {m.source}</>}
          </span>
        </div>
        <select className="text" value={layer.role ?? ""} onChange={(e) => upd((l) => { l.role = (e.target.value || undefined) as Role | undefined; })} title="What the layer is (for “adjust all”)">
          <option value="">no role</option>
          {ROLES.map((r) => <option key={r}>{r}</option>)}
        </select>
      </div>

      {parent && <>
        <div className="sec">Mask</div>
        <p className="faint note">“{parent.name}” shows only where this has pixels{layer.invert ? " (inverted: only where it has none)" : ""}. Its own colours don't show.</p>
        <Toggle label={`Locked to “${parent.name}”: moves and scales with it`} checked={locked} onChange={(v) => lockMask(layer.id, v)} />
        <Toggle label="Invert (keep what's outside it)" checked={!!layer.invert} onChange={(v) => upd((l) => { l.invert = v || undefined; })} />
        <div className="row" style={{ gap: 4, marginTop: 6 }}>
          <button className="btn small" onClick={() => place((x) => Object.assign(x, placedLayer(doc, parent.id)!.transform))} title={`Put it exactly over “${parent.name}”`}>Match the layer</button>
          <button className="btn small" onClick={() => unmaskLayer(layer.id)} title="Make it a layer of its own again, just behind the one it masked">Stop masking</button>
        </div>
      </>}

      <div className="sec">Placement <span className="faint" style={{ textTransform: "none", letterSpacing: 0, fontWeight: 400 }}>pt of 1024{locked ? ", on the canvas" : ""}</span></div>
      <XYPad label="Layer position" x={t.x} y={t.y} xRange={[-0.25, 1.25]} yRange={[-0.25, 1.25]} centre={[0.5, 0.5]} frame={[0, 0, 1, 1]} step={1 / 1024}
        onChange={(x, y, live) => place((p) => { p.x = x; p.y = y; }, live)} />
      <div className="fields">
        {([["width", "Width"]] as const).map(([k, label]) => (
          <label key={k}>
            <NumberField className="text" value={Math.round(t[k] * 1024 * 10) / 10} step={1} onChange={(v) => setT(k, v / 1024)} />{label}
          </label>
        ))}
        <label><NumberField className="text" value={t.rotation} step={1} onChange={(v) => setT("rotation", v)} />Angle°</label>
      </div>
      <div className="row" style={{ flexWrap: "wrap", gap: 4, marginTop: 6 }}>
        <button className="btn small" onClick={() => place((p) => { p.x = 0.5; p.y = 0.5; })}>Centre</button>
        <button className="btn small" onClick={() => place((p) => Object.assign(p, { x: 0.5, y: 0.5, width: 1, rotation: 0 }))}>Fill canvas</button>
        <button className="btn small" onClick={() => place((p) => { p.rotation = 0; })} disabled={!t.rotation}>Straighten</button>
        {m?.analysis.flatSides.includes("bottom") && <button className="btn small" title="Its picture's bottom edge is cut straight: sit it on the icon's bottom edge" onClick={() => place((p) => { const aspect = (m.analysis.subjectBox ? m.analysis.subjectBox[2] * m.width / (m.analysis.subjectBox[3] * m.height) : m.width / m.height); p.y = 1 - p.width / aspect / 2; p.rotation = 0; })}>Sit on bottom edge</button>}
      </div>
      <Slider label="Opacity" value={layer.opacity} min={0} max={1} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => upd((l) => { l.opacity = v; }, true)} onCommit={commit} />

      {c.kind === "image" ? <>
        <UpscaleSection program={doc.program} layer={layer} />
        <div className="sec">Image</div>
        <CurrentPart asset={c.asset} onChange={() => onSub("image")} />
        <div className="row" style={{ gap: 12, marginTop: 4, flexWrap: "wrap" }}>
          {!c.asset.includes("/") && <span title={m?.cutout ? "Cut to the image's subject mask" : "This image has no subject cut-out"}>
            <Toggle label="Cut-out" checked={c.cutout} onChange={(v) => upd((l) => { if (l.content.kind === "image") { l.content.cutout = v; l.content.crop = null; } })} />
          </span>}
          <Seg value={c.smoothing} options={["smooth", "pixel"] as const} labels={{ smooth: "Smooth", pixel: "Pixels" }} onChange={(v) => upd((l) => { if (l.content.kind === "image") l.content.smoothing = v; })} />
        </div>
        {c.crop && <div className="row" style={{ marginTop: 4 }}><span className="faint" style={{ fontSize: 11 }}>Cropped to {c.crop.map((v) => Math.round(v * 100) + "%").join(" ")}</span><button className="btn small" onClick={() => upd((l) => { if (l.content.kind === "image") l.content.crop = null; })}>Uncrop</button></div>}
        <div className="sec">Effects <span className="faint" style={{ textTransform: "none", letterSpacing: 0, fontWeight: 400 }}>applied top to bottom</span></div>
        <EffectsEditor effects={shownEffects}
          maskCtx={{ layerAsset: c.asset, layerTransform: t, onChooseImage: (i) => onSub(i) }}
          update={(fn, live) => upd((l) => { convertLegacyMask(l); if (l.content.kind === "image") { const r = fn(l.content.effects); if (r) l.content.effects = r; } }, live)} />
      </> : <>
        <div className="sec">Shape</div>
        <ShapeEditor shape={c.shape} update={(fn, live) => upd((l) => { if (l.content.kind === "shape") { const r = fn(l.content.shape); if (r) l.content.shape = r; } }, live)} />
      </>}

      {!parent && !!layer.masks?.length && <>
        <div className="sec">Masks</div>
        <p className="faint note">It shows only where {layer.masks.length === 1 ? "its mask has" : "all its masks have"} pixels. To add one, drag a layer onto it in the Layers panel.</p>
        <div className="col" style={{ gap: 2 }}>
          {layer.masks.map((x) => <a key={x.id} href="#" onClick={(e) => { e.preventDefault(); useDesign.getState().select({ kind: "layer", id: x.id }); }}>{x.name}{x.hidden ? " (off)" : ""}</a>)}
        </div>
      </>}

      {c.kind === "shape" && layer.mask && <>
        <div className="sec">Mask</div>
      <MaskEditor onChooseImage={() => onSub("mask")} mask={layer.mask} layerTransform={t}
        update={(fn, live) => upd((l) => { const r = fn(l.mask ?? null); if (r !== undefined) l.mask = r; }, live)} />
      </>}
    </div>
  );
}

function GroupInspector({ group }: { group: Group }) {
  const edit = editor();
  const upd: Update<Group> = (fn, live) => edit((d) => { const g = d.groups.find((x) => x.id === group.id); if (g) fn(g); }, live);
  const gl = group.glass;
  // Absent: neutral when there's a shadow, else off. Off keeps the percent, so switching back restores it.
  const shadowKind = gl.shadowKind ?? (gl.shadow > 0 ? "neutral" : "none");
  return (
    <div className="insp">
      <div className="sec">Group</div>
      <label className="kv wide"><span>Name</span><input className="text" value={group.name} onChange={(e) => upd((g) => { g.name = e.target.value; }, true)} onKeyDown={(e) => e.stopPropagation()} /></label>
      <Toggle label="Hidden" checked={!!group.hidden} onChange={(v) => upd((g) => { g.hidden = v || undefined; })} />
      {/* In Icon Composer's order: the glass's mode, specular, blur, translucency, then the shadow. */}
      <div className="sec">Liquid Glass</div>
      <div className="kv wide tight"><span>Mode</span><Seg value={gl.lighting ?? "individual"} fill options={["individual", "combined"] as const} onChange={(v) => upd((g) => { g.glass.lighting = v; })} /></div>
      <Toggle label="Specular highlight" checked={gl.specular} onChange={(v) => upd((g) => { g.glass.specular = v; })} />
      <div className="kv glass-toggle"><span><Toggle label="Blur" checked={gl.blur != null} onChange={(v) => upd((g) => { g.glass.blur = v ? 0.5 : null; })} /></span>
        {gl.blur != null ? <><input type="range" min={0} max={1} step={0.01} value={gl.blur} onChange={(e) => upd((g) => { g.glass.blur = +e.target.value; }, true)} onPointerUp={commit} /><span className="faint" style={{ textAlign: "right" }}>{Math.round(gl.blur * 100)}%</span></> : <span />}
      </div>
      <div className="kv glass-toggle"><span><Toggle label="Translucent" checked={gl.translucency != null} onChange={(v) => upd((g) => { g.glass.translucency = v ? 0.5 : null; })} /></span>
        {gl.translucency != null ? <><input type="range" min={0} max={1} step={0.01} value={gl.translucency} onChange={(e) => upd((g) => { g.glass.translucency = +e.target.value; }, true)} onPointerUp={commit} /><span className="faint" style={{ textAlign: "right" }}>{Math.round(gl.translucency * 100)}%</span></> : <span /> }
      </div>
      <div className="kv wide tight"><span>Shadow</span><Seg value={shadowKind} fill options={["none", "neutral", "chromatic"] as const} labels={{ none: "Off" }}
        onChange={(v) => upd((g) => { g.glass.shadowKind = v; if (v !== "none" && !g.glass.shadow) g.glass.shadow = 0.5; })} /></div>
      <Slider label="Opacity" value={gl.shadow} min={0} max={1} step={0.01} disabled={shadowKind === "none"} format={(v) => `${Math.round(v * 100)}%`}
        onChange={(v) => upd((g) => { g.glass.shadow = v; if (!g.glass.shadowKind) g.glass.shadowKind = "neutral"; }, true)} onCommit={commit} />
      <p className="faint note">The sketch shows the shadow but not the glass. Switch the canvas to <b>Final</b> for ictool's real render.</p>
      <div className="sec">Layers</div>
      <div className="col" style={{ gap: 2 }}>
        {group.layers.map((l) => <a key={l.id} href="#" onClick={(e) => { e.preventDefault(); useDesign.getState().select({ kind: "layer", id: l.id }); }}>{l.name}</a>)}
        {!group.layers.length && <span className="faint">Empty</span>}
      </div>
    </div>
  );
}

function IconInspector({ doc }: { doc: Doc }) {
  const edit = editor();
  const docs = useDesign((s) => s.docs);
  const parent = doc.parent ? docs[doc.parent] : null;
  return (
    <div className="insp">
      <div className="sec">Icon</div>
      <label className="kv wide"><span>Name</span><input className="text" value={doc.name} onChange={(e) => edit((d) => { d.name = e.target.value; }, true)} onKeyDown={(e) => e.stopPropagation()} /></label>
      <div className="sec">Background fill</div>
      <div className="kv wide"><span>Kind</span><Seg value={doc.fill.kind} options={["gradient", "solid", "none"] as const} onChange={(v) => edit((d) => { d.fill.kind = v; })} /></div>
      {doc.fill.kind !== "none" && <>
        <ColourRow label="Colour" value={doc.fill.color} onChange={(v) => edit((d) => { d.fill.color = v; }, true)} />
        <div className="kv wide"><span>Dark</span><ColourField label="Dark appearance" value={doc.fill.dark} allowNone onChange={(v) => edit((d) => { if (v) d.fill.dark = v; else delete d.fill.dark; }, true)} /></div>
        <p className="faint note">Gradient is Icon Composer's automatic one from the colour. Dark defaults to the colour at 45 %.</p>
      </>}
      <div className="sec">About this design</div>
      <dl className="facts">
        <dt>Made from</dt><dd>{doc.origin ? `the ${doc.origin.treatment} suggestion` : "scratch"}</dd>
        <dt>Derived from</dt><dd>{parent ? parent.name : doc.parent ? <span className="mono">{doc.parent.slice(0, 8)}</span> : "nothing"}</dd>
        <dt>Groups</dt><dd>{doc.groups.length} · {doc.groups.reduce((n, g) => n + g.layers.length, 0)} layers</dd>
        <dt>Id</dt><dd className="mono">{doc.id.slice(0, 8)}</dd>
      </dl>
    </div>
  );
}

/** Moves an old document's `layer.mask` into the effects, as a mask that stays put on the canvas. */
function convertLegacyMask(l: Layer) {
  if (!l.mask || l.content.kind !== "image") return;
  l.content.effects = [...l.content.effects, { op: "mask", mask: l.mask, lock: "canvas" }];
  l.mask = null;
}
