// The inspector's editors for a shape, a layer's effects and its mask. Each takes a value and an `update`
// that edits a copy (`live` while a control is being dragged, committed when it's let go).
import type { Effect, EffectOp, Mask, Media, PatternKind, Shape, ShapeType, Transform } from "../../../api";
import { NO_COLOURS, NO_MEDIA } from "../../../state/app";
import { defaultEffect, defaultMask, defaultShape, EFFECT_LABELS, SHAPE_LABELS, type MaskKind } from "../../../lib/doc";
import { ColourField, Seg, Slider, Toggle } from "../../../components/controls";
import { Menu, usePopup } from "../../../components/Popup";
import { useApp } from "../../../state/app";
import { useDesign } from "../../../state/design";
import { CurrentPart } from "./Subpage";
import { XYPad } from "../../../components/XYPad";
import { useReorder } from "../../../lib/reorder";

export type Update<T> = (fn: (v: T) => T | void, live?: boolean) => void;
const commit = () => useDesign.getState().commit();

// ---------------------------------------------------------------- shapes

export function ShapeEditor({ shape, update, kinds }: { shape: Shape; update: Update<Shape>; kinds?: ShapeType[] }) {
  const named = useApp((s) => s.program?.colours ?? NO_COLOURS);
  const set = <K extends string>(k: K, v: unknown, live = false) => update((s) => { (s as any)[k] = v; }, live);
  return (
    <div className="col">
      <label className="kv wide"><span>Shape</span>
        <select className="text" value={shape.type} onChange={(e) => update(() => defaultShape(e.target.value as ShapeType, named.striking, named["second striking"]))}>
          {(kinds ?? (Object.keys(SHAPE_LABELS) as ShapeType[])).map((t) => <option key={t} value={t}>{SHAPE_LABELS[t]}</option>)}
        </select>
      </label>
      {shape.type === "solid" && <ColourRow label="Colour" value={shape.color} onChange={(v) => set("color", v, true)} />}
      {shape.type === "gradient" && <>
        <ColourStops kind="gradient" stops={[["From", shape.from], ["To", shape.to]]}
          onChange={(i, v) => set(i ? "to" : "from", v, true)}
          onMove={() => update((s) => { const g = s as Extract<Shape, { type: "gradient" }>; [g.from, g.to] = [g.to, g.from]; })} />
        <Slider label="Angle" value={shape.angle} min={0} max={360} step={1} format={(v) => `${Math.round(v)}°`} onChange={(v) => set("angle", v, true)} onCommit={commit} />
      </>}
      {shape.type === "pattern" && <>
        <label className="kv wide"><span>Pattern</span>
          <select className="text" value={shape.pattern} onChange={(e) => set("pattern", e.target.value as PatternKind)}>
            {["stripes", "dots", "grid", "checker", "rays"].map((p) => <option key={p}>{p}</option>)}
          </select>
        </label>
        <ColourRow label="Ground" value={shape.a} onChange={(v) => set("a", v, true)} />
        <ColourRow label="Marks" value={shape.b} onChange={(v) => set("b", v, true)} />
      </>}
      {shape.type === "bands" && <>
        <ColourStops kind="bands" stops={shape.colors.map((c, i) => [`Band ${i + 1}`, c])}
          onChange={(i, v) => update((s) => { (s as any).colors[i] = v; }, true)}
          onMove={(from, to) => update((s) => { const l = (s as any).colors as string[]; const [c] = l.splice(from, 1); l.splice(to, 0, c); })}
          onRemove={shape.colors.length < 2 ? undefined : (i) => update((s) => { (s as any).colors.splice(i, 1); })} />
        <button className="btn small" style={{ justifySelf: "start" }} onClick={() => update((s) => { (s as any).colors.push(shape.colors[shape.colors.length - 1] ?? "#888888"); })}>＋ Band</button>
      </>}
      {shape.type === "window" && <>
        <ColourRow label="Frame" value={shape.frame} onChange={(v) => set("frame", v, true)} />
        <ColourRow label="Title bar" value={shape.bar} onChange={(v) => set("bar", v, true)} />
      </>}
      {shape.type === "crt" && <ColourRow label="Bezel" value={shape.bezel} onChange={(v) => set("bezel", v, true)} />}
      {shape.type === "circle" && <>
        <ColourRow label="Colour" value={shape.color} onChange={(v) => set("color", v, true)} />
        <Slider label="Radius" value={shape.radius} min={0.02} max={0.72} step={0.002} format={(v) => `${Math.round(v * 1024)} pt`} onChange={(v) => set("radius", v, true)} onCommit={commit} />
      </>}
      {shape.type === "rounded-rect" && <>
        <ColourRow label="Colour" value={shape.color} onChange={(v) => set("color", v, true)} />
        <PadRow label="Top left">
          <XYPad label="Rectangle's top-left corner" x={shape.rect[0]} y={shape.rect[1]} xRange={[-0.25, 1.25]} yRange={[-0.25, 1.25]} centre={[0.15, 0.15]} frame={[0, 0, 1, 1]} step={1 / 1024}
            onChange={(x, y, live) => { update((s) => { const r = [...(s as any).rect]; r[0] = x; r[1] = y; (s as any).rect = r; }, live); if (!live) commit(); }} />
        </PadRow>
        {(["Width", "Height"] as const).map((label, j) => { const i = j + 2; return (
          <Slider key={label} label={label} value={shape.rect[i]} min={0.02} max={1.2} step={0.002} format={(v) => `${Math.round(v * 1024)}`}
            onChange={(v) => update((s) => { const r = [...(s as any).rect]; r[i] = v; (s as any).rect = r; }, true)} onCommit={commit} />
        ); })}
        <Slider label="Corner" value={shape.radius} min={0} max={0.5} step={0.002} format={(v) => `${Math.round(v * 1024)} pt`} onChange={(v) => set("radius", v, true)} onCommit={commit} />
      </>}
      {shape.type === "disc-rims" && <ColourRow label="Colour" value={shape.color} onChange={(v) => set("color", v, true)} />}
      {shape.type === "text" && <>
        <label className="kv wide"><span>Text</span><input className="text" value={shape.text} maxLength={4} onChange={(e) => set("text", e.target.value, true)} onBlur={commit} onKeyDown={(e) => e.stopPropagation()} /></label>
        <label className="kv wide"><span>Font</span>
          <select className="text" value={shape.font} onChange={(e) => set("font", e.target.value)}>
            {["Arial Black", "Helvetica Neue", "Georgia", "Futura", "American Typewriter", "Chalkboard SE", "Copperplate", "Impact", "Menlo"].map((f) => <option key={f}>{f}</option>)}
          </select>
        </label>
        <Slider label="Size" value={shape.size ?? 0.86} min={0.1} max={1.4} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set("size", v, true)} onCommit={commit} />
        <ColourRow label="Colour" value={shape.color} onChange={(v) => set("color", v, true)} />
      </>}
    </div>
  );
}

export function ColourRow({ label, value, onChange, allowNone }: { label: string; value: string | undefined; onChange(v: string): void; allowNone?: boolean }) {
  return (
    <div className="kv wide"><span>{label}</span><ColourField label={label} value={value} allowNone={allowNone} onChange={(v) => v && onChange(v)} /></div>
  );
}

/** Colours in an order that matters (a gradient's ends, a gradient map's shadows and highlights, bands), each
 *  dragged by its handle to a new place. The labels stay where they are: dragging a colour to the top makes it
 *  the first. */
function ColourStops({ kind, stops, onChange, onMove, onRemove }: {
  kind: string; stops: [string, string][]; onChange(i: number, v: string): void; onMove(from: number, to: number): void
  onRemove?(i: number): void
}) {
  const r = useReorder(kind, onMove);
  return <>
    {stops.map(([label, c], i) => (
      <div key={i} className={"kv wide stop" + (r.dragging === i ? " dragging" : "")} {...r.row(i)}>
        <span className="row" style={{ gap: 3 }}>
          <span className="grip" {...r.handle(i)} title="Drag to reorder" aria-label={`Move ${label}`}>⠿</span>{label}
        </span>
        <span className="row">
          <ColourField label={label} value={c} onChange={(v) => v && onChange(i, v)} />
          {onRemove && <button className="icon-btn" onClick={() => onRemove(i)} aria-label={`Remove ${label}`}>✕</button>}
        </span>
      </div>
    ))}
  </>;
}

// ---------------------------------------------------------------- effects

export type MaskCtx = { layerAsset?: string; layerTransform: Transform; onChooseImage(index: number): void };

export function EffectsEditor({ effects, update, maskCtx }: { effects: Effect[]; update: Update<Effect[]>; maskCtx: MaskCtx }) {
  const add = usePopup();
  const named = useApp((s) => s.program?.colours ?? NO_COLOURS);
  const moveTo = (i: number, j: number) => update((list) => { if (j < 0 || j >= list.length) return; const [e] = list.splice(i, 1); list.splice(j, 0, e); });
  const move = (i: number, by: number) => moveTo(i, i + by);
  const r = useReorder("effects", moveTo);
  return (
    <div className="col">
      {effects.map((e, i) => (
        <div key={i} className={"fx" + (r.dragging === i ? " dragging" : "")} {...r.row(i)}>
          <div className="fx-h" {...r.handle(i)} title="Drag to change the order effects are applied in">
            <span className="grip" aria-hidden>⠿</span>
            <b>{EFFECT_LABELS[e.op]}</b>
            <span className="grow" />
            <button className="icon-btn" disabled={i === 0} onClick={() => move(i, -1)} aria-label="Apply earlier" title="Apply earlier">↑</button>
            <button className="icon-btn" disabled={i === effects.length - 1} onClick={() => move(i, 1)} aria-label="Apply later" title="Apply later">↓</button>
            <button className="icon-btn" onClick={() => update((l) => { l.splice(i, 1); })} aria-label="Remove effect" title="Remove">✕</button>
          </div>
          {e.op === "mask"
            ? <MaskEffectParams e={e} ctx={maskCtx} index={i} update={(fn, live) => update((l) => { const r = fn(l[i]); if (r) l[i] = r; }, live)} />
            : <EffectParams e={e} update={(fn, live) => update((l) => { const r = fn(l[i]); if (r) l[i] = r; }, live)} />}
        </div>
      ))}
      {!effects.length && <div className="faint" style={{ fontSize: 11.5 }}>No effects: the image as it is.</div>}
      <button className="btn small" style={{ justifySelf: "start" }} onClick={(ev) => add.toggle(ev.currentTarget)}>＋ Effect ▾</button>
      <Menu anchor={add.anchor} onClose={add.close} items={(Object.keys(EFFECT_LABELS) as EffectOp[]).map((op) => ({
        label: EFFECT_LABELS[op], onClick: () => update((l) => { l.push(defaultEffect(op, named.striking, named["second striking"])); }),
      }))} />
    </div>
  );
}

function EffectParams({ e, update }: { e: Effect; update: Update<Effect> }) {
  const set = (k: string, v: unknown, live = false) => update((x) => { (x as any)[k] = v; }, live);
  const colour = (k: string, label: string) => <ColourRow label={label} value={(e as any)[k]} onChange={(v) => set(k, v, true)} />;
  const slider = (k: string, label: string, min: number, max: number, step: number, fmt?: (v: number) => string) =>
    <Slider label={label} value={(e as any)[k]} min={min} max={max} step={step} format={fmt} onChange={(v) => set(k, v, true)} onCommit={commit} />;
  const pts = (v: number) => `${Math.round(v * 1024)} pt`;
  switch (e.op) {
    case "silhouette": return colour("color", "Colour");
    case "outline": return <>{colour("color", "Colour")}{slider("width", "Width", 0.002, 0.1, 0.001, pts)}</>;
    case "feather": return <>{slider("softness", "Softness", 0, 0.12, 0.001, pts)}
      {slider("offset", "Edge (in ↔ out)", -0.08, 0.08, 0.001, (v) => v === 0 ? "at the edge" : `${Math.abs(Math.round(v * 1024))} pt ${v < 0 ? "in" : "out"}`)}</>;
    case "halftone": return <>{colour("ink", "Ink")}{slider("cell", "Dot size", 0.005, 0.08, 0.001, pts)}{slider("angle", "Angle", 0, 90, 1, (v) => `${v}°`)}</>;
    case "tone": return <>
      <div className="kv wide"><span>Band</span><Seg value={String(e.level) as "0" | "1" | "2"} options={["0", "1", "2"] as const} labels={{ 0: "Dark", 1: "Mid", 2: "Light" }} onChange={(v) => set("level", +v)} /></div>
      {colour("color", "Colour")}
    </>;
    case "gradient-map": return <ColourStops kind="gradient-map" stops={[["Shadows", e.dark], ["Highlights", e.light]]}
      onChange={(i, v) => set(i ? "light" : "dark", v, true)}
      onMove={() => update((x) => { const g = x as Extract<Effect, { op: "gradient-map" }>; [g.dark, g.light] = [g.light, g.dark]; })} />;
    case "blur": return slider("radius", "Radius", 0, 0.05, 0.0005, pts);
    case "edges": return colour("color", "Colour");
    case "riso": return <>
      {colour("ink", "Ink")}
      <div className="kv wide"><span>Band</span><Seg value={e.band} options={["dark", "mid"] as const} onChange={(v) => set("band", v)} /></div>
      <PadRow label="Offset">
        <XYPad label="Ink offset" x={e.offset[0]} y={e.offset[1]} xRange={[-0.05, 0.05]} yRange={[-0.05, 0.05]} step={1 / 1024} size={72}
          onChange={(x, y, live) => { update((v) => { (v as any).offset = [x, y]; }, live); if (!live) commit(); }} />
      </PadRow>
    </>;
    case "posterize": return slider("colors", "Colours", 2, 16, 1, (v) => String(v));
    case "tint": return <>{colour("color", "Colour")}{slider("amount", "Amount", 0, 1, 0.01, (v) => `${Math.round(v * 100)}%`)}</>;
    case "key": return slider("tolerance", "Tolerance", 0, 0.5, 0.005, (v) => `${Math.round(v * 100)}%`);
    case "flatten": return colour("color", "Colour");
    case "autocontrast": case "scanlines": case "mask": return null;
  }
}

// ---------------------------------------------------------------- masks

const MASK_LABELS: Record<MaskKind, string> = { none: "None", ring: "Ring (disc)", "linear-fade": "Linear fade", shape: "Shape", image: "Another image's silhouette" };

export function MaskEditor({ mask, update, layerAsset, layerTransform, onChooseImage, asEffect, lock, onKindChange }: {
  mask: Mask | null | undefined; update: Update<Mask | null>; layerAsset?: string; layerTransform: Transform; onChooseImage(): void
  /** Inside a mask effect: no "None", and the effect has its own invert. */
  asEffect?: boolean; lock?: "canvas" | "image"; onKindChange?(k: MaskKind): void
}) {
  const media = useApp((s) => s.program?.media ?? NO_MEDIA);
  const withCutouts = media.filter((m) => m.cutout);
  const kind: MaskKind = mask?.kind ?? "none";
  const set = (k: string, v: unknown, live = false) => update((m) => { if (m) (m as any)[k] = v; }, live);
  const pts = (v: number) => `${Math.round(v * 1024)} pt`;
  return (
    <div className="col">
      <label className="kv wide"><span>Mask</span>
        <select className="text" value={kind} onChange={(e) => {
          const k = e.target.value as MaskKind;
          update(() => {
            const m = defaultMask(k, { transform: layerTransform, content: { kind: "image", asset: layerAsset ?? withCutouts[0]?.id ?? "", cutout: true, smoothing: "smooth", effects: [] } } as any, withCutouts[0]?.id);
            // Moving with the picture, a silhouette fills the picture's own box.
            if (m?.kind === "image" && asEffect) m.transform = { x: 0.5, y: 0.5, width: 1, rotation: 0 };
            return m;
          });
          onKindChange?.(k);
        }}>
          {(Object.keys(MASK_LABELS) as MaskKind[]).filter((k) => !(asEffect && k === "none")).map((k) => <option key={k} value={k} disabled={k === "image" && !withCutouts.length}>{MASK_LABELS[k]}</option>)}
        </select>
      </label>
      {mask?.kind === "ring" && <>
        <Slider label="Outer" value={mask.outer} min={0.05} max={0.71} step={0.002} format={pts} onChange={(v) => set("outer", v, true)} onCommit={commit} />
        <Slider label="Hole" value={mask.inner} min={0} max={0.5} step={0.002} format={pts} onChange={(v) => set("inner", v, true)} onCommit={commit} />
      </>}
      {mask?.kind === "linear-fade" && <>
        <Slider label="Angle" value={mask.angle} min={0} max={360} step={1} format={(v) => `${Math.round(v)}°`} onChange={(v) => set("angle", v, true)} onCommit={commit} />
        <Slider label="Fade from" value={mask.start} min={0} max={1} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set("start", v, true)} onCommit={commit} />
        <Slider label="Fade to" value={mask.end} min={0} max={1} step={0.01} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set("end", v, true)} onCommit={commit} />
      </>}
      {mask?.kind === "shape" && <>
        <ShapeEditor shape={mask.shape} kinds={["text", "circle", "rounded-rect", "solid", "window", "crt", "pattern"]} update={(fn, live) => update((m) => { if (m?.kind === "shape") { const r = fn(m.shape); if (r) m.shape = r; } }, live)} />
        {!asEffect && <Toggle label="Invert (cut the shape out)" checked={!!mask.invert} onChange={(v) => set("invert", v || undefined)} />}
        <TransformSliders t={mask.transform} update={(fn, live) => update((m) => { if (m && "transform" in m) fn(m.transform); }, live)} />
      </>}
      {mask?.kind === "image" && <>
        <CurrentPart asset={mask.asset} onChange={onChooseImage} />
        <TransformSliders t={mask.transform} update={(fn, live) => update((m) => { if (m && "transform" in m) fn(m.transform); }, live)} />
        {lock === "image"
          ? <MatchButton current={mask.transform} target={{ x: 0.5, y: 0.5, width: 1, rotation: 0 }} label="Fill the picture" already="It already fills the picture" onClick={() => set("transform", { x: 0.5, y: 0.5, width: 1, rotation: 0 })} />
          : <MatchButton current={mask.transform} target={layerTransform} label="Match the layer's placement" already="It already matches the layer's placement" onClick={() => set("transform", { ...layerTransform })} />}
      </>}
    </div>
  );
}

export function TransformSliders({ t, update }: { t: Transform; update: Update<Transform> }) {
  const s = (k: keyof Transform, label: string, min: number, max: number, step: number, fmt: (v: number) => string) =>
    <Slider label={label} value={t[k]} min={min} max={max} step={step} format={fmt} onChange={(v) => update((x) => { x[k] = v; }, true)} onCommit={commit} />;
  const pts = (v: number) => `${Math.round(v * 1024)}`;
  return <>
    <PadRow label="Centre">
      <XYPad label="Centre" x={t.x} y={t.y} xRange={[-0.25, 1.25]} yRange={[-0.25, 1.25]} centre={[0.5, 0.5]} frame={[0, 0, 1, 1]} step={1 / 1024}
        onChange={(x, y, live) => { update((v) => { v.x = x; v.y = y; }, live); if (!live) commit(); }} />
    </PadRow>
    {s("width", "Width", 0.02, 3, 0.001, pts)}{s("rotation", "Rotation", -180, 180, 0.5, (v) => `${Math.round(v)}°`)}</>;
}

export function MediaPicker({ value, media, onChange }: { value: string; media: Media[]; onChange(id: string): void }) {
  return (
    <div className="media-pick">
      {media.map((m) => (
        <button key={m.id} className={"checker" + (m.id === value ? " on" : "")} title={`${m.name} · ${m.kind}`} onClick={() => onChange(m.id)}>
          <img src={m.cutout ?? m.thumb} alt="" style={m.analysis.pixelArt ? { imageRendering: "pixelated" } : undefined} />
        </button>
      ))}
      {!media.length && <span className="faint" style={{ fontSize: 11.5 }}>No picked images.</span>}
    </div>
  );
}

/** A labelled row holding an XY pad. */
function PadRow({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="padrow"><span>{label}</span>{children}</div>;
}

type MaskEffect = Extract<Effect, { op: "mask" }>;

/** A mask effect: what shape the mask is, whether it stays put on the canvas or moves with the picture, invert. */
function MaskEffectParams({ e, ctx, index, update }: { e: MaskEffect; ctx: MaskCtx; index: number; update: Update<Effect> }) {
  return (
    <>
      <div className="kv wide" title="Stays put on the canvas while the layer moves, or moves, scales and turns with the image"><span>Place</span>
        <Seg value={e.lock} options={["canvas", "image"] as const} labels={{ canvas: "Stays put", image: "Moves with it" }}
          onChange={(v) => update((x) => { (x as MaskEffect).lock = v; })} />
      </div>
      <MaskEditor asEffect lock={e.lock} mask={e.mask} layerAsset={ctx.layerAsset} layerTransform={ctx.layerTransform} onChooseImage={() => ctx.onChooseImage(index)}
        onKindChange={(k) => update((x) => { (x as MaskEffect).lock = k === "image" ? "image" : "canvas"; })}
        update={(fn, live) => update((x) => { const r = fn((x as MaskEffect).mask); if (r) (x as MaskEffect).mask = r; }, live)} />
      <Toggle label="Invert (keep what's outside the mask)" checked={!!e.invert} onChange={(v) => update((x) => { (x as MaskEffect).invert = v || undefined; })} />
    </>
  );
}

const sameTransform = (a: Transform, b: Transform) =>
  Math.abs(a.x - b.x) < 0.002 && Math.abs(a.y - b.y) < 0.002 && Math.abs(a.width - b.width) < 0.002 && Math.abs(((a.rotation - b.rotation + 540) % 360) - 180) < 0.5;

/** A button that sets the mask's placement, greyed when it's already there. */
function MatchButton({ current, target, label, already, onClick }: { current: Transform; target: Transform; label: string; already: string; onClick(): void }) {
  const same = sameTransform(current, target);
  return <button className="btn small" style={{ justifySelf: "start" }} disabled={same} title={same ? already : undefined} onClick={onClick}>{label}</button>;
}
