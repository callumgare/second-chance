// The canvas: the sketch of the current doc (or ictool's real render with Glass on), the selected layer's
// handles (move, proportional scale, rotate), snapping to the canvas's centre and edges, and dropping media.
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import Konva from "konva";
import { Group, Image as KImage, Layer as KLayer, Line, Rect, Shape, Stage, Transformer } from "react-konva";
import type { Doc } from "../../api";
import { findLayer } from "../../lib/doc";
import { RENDER_INSET, requestIconRender, cachedIconRender, iconKey } from "../../render/iconRenders";
import { loadImage, resources } from "../../render/resources";
import { drawInBox, drawSketch, layerBox, pickLayer } from "../../render/sketch";
import { useApp } from "../../state/app";
import { selectedLayerIds, useDesign } from "../../state/design";
import { clickLayer, insertLayers } from "./actions";
import { designDrag, layersFromDrop } from "../../lib/drop";
import { SmallPreviews } from "./SmallPreviews";
import { panBy, useZoom, zoomBy, zoomFit, zoomForProgram, zoomStep } from "../../state/zoom";

const SNAP = 6; // px
Konva.dragDistance = 2;

type Guide = { x?: number; y?: number };
type Box = { x: number; y: number; width: number; height: number; rotation: number };

export function EditorCanvas() {
  const doc = useDesign((s) => s.doc);
  const sel = useDesign((s) => s.sel);
  const appearance = useDesign((s) => s.appearance);
  const glass = useDesign((s) => s.glass);
  const grid = useDesign((s) => s.grid);
  const backdrop = useDesign((s) => s.backdrop);
  const transient = useDesign((s) => s.transientBase != null);
  const media = useApp((s) => s.media);

  const wrap = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ w: 600, h: 500 });
  useLayoutEffect(() => {
    const el = wrap.current; if (!el) return;
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    setBox({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);
  // Zoom scales the canvas's size itself (so everything drawn stays sharp and snapping stays in screen pixels);
  // the pan moves its centre.
  const program = doc?.program ?? null;
  useEffect(() => zoomForProgram(program), [program]);
  const zoom = useZoom((z) => z.zoom), pan = useZoom((z) => z.pan);
  const fitS = Math.max(64, Math.floor(Math.min(box.w, box.h) * 0.82));
  const S = Math.round(fitS * zoom);
  // Keep at least a quarter of the frame on the icon when panned.
  const lim = (p: number, room: number) => Math.max(-(S / 2 + room / 4), Math.min(S / 2 + room / 4, p));
  const ox = Math.round((box.w - S) / 2 + lim(pan.x, box.w)), oy = Math.round((box.h - S) / 2 + lim(pan.y, box.h));

  // Pinch or ⌘-scroll zooms about the pointer; a plain scroll pans once zoomed in. ⌘+ / ⌘− / ⌘0 while hovered.
  // Space-drag pans.
  const hovered = useRef(false);
  const space = useRef(false);
  const panning = useRef<{ x: number; y: number } | null>(null);
  useEffect(() => {
    const el = wrap.current; if (!el) return;
    const wheel = (e: WheelEvent) => {
      const r = el.getBoundingClientRect();
      const at = { x: e.clientX - r.left - r.width / 2, y: e.clientY - r.top - r.height / 2 };
      if (e.ctrlKey || e.metaKey) { e.preventDefault(); zoomBy(Math.exp(-e.deltaY * (e.ctrlKey && !e.metaKey ? 0.01 : 0.002)), at); }
      else if (useZoom.getState().zoom > 1) { e.preventDefault(); panBy(-e.deltaX, -e.deltaY); }
    };
    const enter = () => { hovered.current = true; }, leave = () => { hovered.current = false; };
    el.addEventListener("wheel", wheel, { passive: false });
    el.addEventListener("pointerenter", enter); el.addEventListener("pointerleave", leave);
    const typing = (e: KeyboardEvent) => e.target instanceof HTMLElement && (e.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName));
    const key = (e: KeyboardEvent) => {
      if (typing(e)) return;
      if (e.code === "Space") {
        if (hovered.current || panning.current) { e.preventDefault(); space.current = e.type === "keydown"; el.style.cursor = space.current ? "grab" : ""; }
        return;
      }
      if (e.type !== "keydown" || !(e.metaKey || e.ctrlKey) || !(hovered.current || el.contains(document.activeElement))) return;
      if (e.key === "=" || e.key === "+") { e.preventDefault(); e.stopImmediatePropagation(); zoomStep(1); }
      else if (e.key === "-" || e.key === "_") { e.preventDefault(); e.stopImmediatePropagation(); zoomStep(-1); }
      else if (e.key === "0") { e.preventDefault(); e.stopImmediatePropagation(); zoomFit(); }
    };
    // Space-drag: caught before Konva sees the press.
    const down = (e: PointerEvent | MouseEvent) => {
      if (!space.current) return;
      e.stopPropagation(); e.preventDefault();
      if (e.type === "pointerdown") { panning.current = { x: e.clientX, y: e.clientY }; el.style.cursor = "grabbing"; }
    };
    const move = (e: PointerEvent) => { const p = panning.current; if (!p) return; panBy(e.clientX - p.x, e.clientY - p.y); panning.current = { x: e.clientX, y: e.clientY }; };
    const up = () => { if (panning.current) { panning.current = null; el.style.cursor = space.current ? "grab" : ""; } };
    window.addEventListener("keydown", key, true); window.addEventListener("keyup", key, true);
    el.addEventListener("pointerdown", down, true); el.addEventListener("mousedown", down, true);
    window.addEventListener("pointermove", move); window.addEventListener("pointerup", up);
    return () => {
      el.removeEventListener("wheel", wheel); el.removeEventListener("pointerenter", enter); el.removeEventListener("pointerleave", leave);
      window.removeEventListener("keydown", key, true); window.removeEventListener("keyup", key, true);
      el.removeEventListener("pointerdown", down, true); el.removeEventListener("mousedown", down, true);
      window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up);
    };
  }, [doc == null]);

  // Redraw when pixels arrive.
  const layerRef = useRef<Konva.Layer>(null);
  useEffect(() => resources.subscribe(() => layerRef.current?.batchDraw()), []);

  // ---------------------------------------------------------------- the real render (Glass)
  const real = useRealRender(glass ? doc : null, appearance, S, transient);

  // ---------------------------------------------------------------- selection and handles
  const selLayer = doc && sel?.kind === "layer" ? findLayer(doc, sel.id)?.layer ?? null : null;
  const proxy = useRef<Konva.Rect>(null);
  // Several layers, or a group's: one box around their turned bounds, moved and scaled together.
  const multiIds = doc && (sel?.kind === "layers" || sel?.kind === "group")
    ? selectedLayerIds(doc, sel).filter((id) => { const h = findLayer(doc, id); return h && !h.layer.hidden && !h.group.hidden; }) : [];
  const union = (() => {
    if (!doc || !multiIds.length) return null;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const id of multiIds) {
      const l = findLayer(doc, id)?.layer; if (!l) continue;
      const b = layerBox(doc.program, l, S, media);
      const c = Math.abs(Math.cos(b.rot)), si = Math.abs(Math.sin(b.rot));
      const hw = (b.w * c + b.h * si) / 2, hh = (b.w * si + b.h * c) / 2;
      x0 = Math.min(x0, b.cx - hw); x1 = Math.max(x1, b.cx + hw); y0 = Math.min(y0, b.cy - hh); y1 = Math.max(y1, b.cy + hh);
    }
    return x0 < x1 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
  })();
  const mproxy = useRef<Konva.Rect>(null);
  const mstart = useRef<{ x: number; y: number; w: number; h: number; layers: Map<string, { x: number; y: number; width: number }> } | null>(null);
  const tr = useRef<Konva.Transformer>(null);
  const pendingDrag = useRef(false);
  // A press on a layer not yet selected starts its drag only once its box is drawn, a frame or a render later. A
  // trackpad's tap-to-click lets go before then, and a drag started after the release never sees one, so the layer
  // would follow the pointer until the next click: a release first cancels it.
  useEffect(() => {
    const up = () => { pendingDrag.current = false; };
    window.addEventListener("pointerup", up, true); window.addEventListener("mouseup", up, true); window.addEventListener("pointercancel", up, true);
    return () => { window.removeEventListener("pointerup", up, true); window.removeEventListener("mouseup", up, true); window.removeEventListener("pointercancel", up, true); };
  }, []);
  const [guides, setGuides] = useState<Guide>({});
  // ⌥ or ⌘ held turns snapping off, for a resize as for a drag (the resize's bound function sees no event).
  const noSnap = useRef(false);
  useEffect(() => {
    const k = (e: KeyboardEvent | PointerEvent) => { noSnap.current = e.altKey || e.metaKey; };
    window.addEventListener("keydown", k, true); window.addEventListener("keyup", k, true); window.addEventListener("pointermove", k, true);
    return () => { window.removeEventListener("keydown", k, true); window.removeEventListener("keyup", k, true); window.removeEventListener("pointermove", k, true); };
  }, []);

  /** A resize snaps as a drag does: the box's bounds (its bounding box, turned or not) to the canvas's edges and
   * centre lines. The handle scales the box about the opposite corner, keeping its ratio, so the nearest moving
   * edge within reach decides the scale and the rest follows. */
  const snapResize = (o: Box, n: Box): Box => {
    if (n.width < 6 || n.height < 6) return o;
    const anchor = tr.current?.getActiveAnchor() ?? "";
    if (noSnap.current || !anchor || anchor === "rotater") { setGuides({}); return n; }
    const c = Math.cos(n.rotation), si = Math.sin(n.rotation);
    const TL = { x: n.x, y: n.y }, TR = { x: n.x + n.width * c, y: n.y + n.width * si };
    const BL = { x: n.x - n.height * si, y: n.y + n.height * c }, BR = { x: TR.x + BL.x - TL.x, y: TR.y + BL.y - TL.y };
    const P = ({ "top-left": BR, "top-right": BL, "bottom-left": TR, "bottom-right": TL } as Record<string, { x: number; y: number }>)[anchor];
    if (!P) return n;
    const pts = [TL, TR, BL, BR];
    const xs = pts.map((q) => q.x), ys = pts.map((q) => q.y);
    let best: { k: number; d: number; g: Guide } | null = null;
    const tryEdge = (edge: number, fixed: number, axis: "x" | "y") => {
      if (Math.abs(edge - fixed) < 2) return; // that side stays put
      for (const t of [0, S / 2, S]) {
        const target = t + (axis === "x" ? ox : oy);
        const d = Math.abs(target - edge);
        const k = (target - fixed) / (edge - fixed);
        if (d < SNAP && k > 0 && (!best || d < best.d)) best = { k, d, g: { [axis]: t } };
      }
    };
    tryEdge(Math.min(...xs), P.x, "x"); tryEdge(Math.max(...xs), P.x, "x");
    tryEdge(Math.min(...ys), P.y, "y"); tryEdge(Math.max(...ys), P.y, "y");
    const b = best as { k: number; d: number; g: Guide } | null;
    if (!b || n.width * b.k < 6) { setGuides({}); return n; }
    setGuides(b.g);
    return { ...n, x: P.x + (n.x - P.x) * b.k, y: P.y + (n.y - P.y) * b.k, width: n.width * b.k, height: n.height * b.k };
  };

  useLayoutEffect(() => {
    if (!tr.current) return;
    tr.current.nodes(proxy.current && selLayer && !selLayer.hidden ? [proxy.current] : mproxy.current && union ? [mproxy.current] : []);
    tr.current.getLayer()?.batchDraw();
    if (pendingDrag.current && proxy.current) { pendingDrag.current = false; proxy.current.startDrag(); }
  });

  const onDown = useCallback((e: Konva.KonvaEventObject<MouseEvent>) => {
    const target = e.target;
    if (target.getParent() instanceof Konva.Transformer) return;
    const st = useDesign.getState();
    if (!st.doc) return;
    const p = e.target.getStage()!.getPointerPosition()!;
    const u = (p.x - ox) / S, v = (p.y - oy) / S;
    const hit = pickLayer(st.doc, u, v, useApp.getState().media);
    // ⇧ or ⌘: add or remove the layer under the pointer.
    if (hit && (e.evt.shiftKey || e.evt.metaKey || e.evt.ctrlKey)) {
      proxy.current?.stopDrag(); mproxy.current?.stopDrag();
      clickLayer(hit.id, e.evt, "canvas");
      return;
    }
    if (target === proxy.current) {
      // On the selected layer's box: drag it, unless another layer's pixels are in front there.
      if (!hit || (st.sel?.kind === "layer" && hit.id === st.sel.id)) return;
      proxy.current.stopDrag();
    }
    if (target === mproxy.current) {
      // In the box of several: drag them all, unless the pointer is on another layer's pixels.
      if (!hit || selectedLayerIds(st.doc, st.sel).includes(hit.id)) return;
      mproxy.current.stopDrag();
    }
    if (hit) {
      if (!(st.sel?.kind === "layer" && st.sel.id === hit.id)) st.select({ kind: "layer", id: hit.id });
      pendingDrag.current = true;
      // The proxy may already be this layer's: start at once.
      requestAnimationFrame(() => { if (pendingDrag.current && proxy.current) { pendingDrag.current = false; proxy.current.startDrag(); } });
    } else {
      st.select({ kind: "icon" });
    }
  }, [ox, oy, S]);

  const setTransform = (node: Konva.Rect, snapping: boolean, keepGuides = false) => {
    const st = useDesign.getState();
    if (!st.doc || st.sel?.kind !== "layer") return;
    const id = st.sel.id;
    let x = node.x(), y = node.y();
    const g: Guide = {};
    if (snapping) {
      const r = node.getClientRect({ relativeTo: node.getParent() ?? undefined });
      const hw = r.width / 2, hh = r.height / 2;
      const cxOff = r.x + hw - x, cyOff = r.y + hh - y; // the box's centre vs the node's position
      const cx = x + cxOff, cy = y + cyOff;
      const xs: [number, number][] = [[S / 2, S / 2 - cx], [0, hw - cx], [S, S - hw - cx]];
      const ys: [number, number][] = [[S / 2, S / 2 - cy], [0, hh - cy], [S, S - hh - cy]];
      const bx = xs.filter(([, d]) => Math.abs(d) < SNAP).sort((a, b) => Math.abs(a[1]) - Math.abs(b[1]))[0];
      const by = ys.filter(([, d]) => Math.abs(d) < SNAP).sort((a, b) => Math.abs(a[1]) - Math.abs(b[1]))[0];
      if (bx) { x += bx[1]; g.x = bx[0]; }
      if (by) { y += by[1]; g.y = by[0]; }
      node.position({ x, y });
    }
    if (!keepGuides) setGuides(g);
    const width = (node.width() * node.scaleX()) / S;
    st.edit((d) => {
      const h = findLayer(d, id); if (!h) return;
      h.layer.transform = { x: x / S, y: y / S, width, rotation: Math.round(node.rotation() * 100) / 100 };
    }, { transient: true });
  };

  const startMulti = (node: Konva.Rect) => {
    const st = useDesign.getState(); if (!st.doc) return;
    const layers = new Map<string, { x: number; y: number; width: number }>();
    for (const id of multiIds) { const l = findLayer(st.doc, id)?.layer; if (l) layers.set(id, { x: l.transform.x, y: l.transform.y, width: l.transform.width }); }
    mstart.current = { x: node.x(), y: node.y(), w: node.width() * node.scaleX(), h: node.height() * node.scaleY(), layers };
  };
  /** Moves (k = 1) or scales every selected layer so the start box lands on the node's box. */
  const applyMulti = (node: Konva.Rect, k: number) => {
    const m = mstart.current; if (!m) return;
    const nx = node.x() / S, ny = node.y() / S, sx = m.x / S, sy = m.y / S;
    useDesign.getState().edit((d) => {
      for (const [id, t] of m.layers) {
        const h = findLayer(d, id); if (!h) continue;
        h.layer.transform = { ...h.layer.transform, x: nx + (t.x - sx) * k, y: ny + (t.y - sy) * k, width: t.width * k };
      }
    }, { transient: true });
  };
  const dragMulti = (node: Konva.Rect, snapping: boolean) => {
    const m = mstart.current; if (!m) return;
    let x = node.x(), y = node.y();
    const g: Guide = {};
    if (snapping) {
      const pick = (lo: number, size: number) => ([[0, 0 - lo], [S / 2, S / 2 - (lo + size / 2)], [S, S - (lo + size)]] as [number, number][])
        .filter(([, d]) => Math.abs(d) < SNAP).sort((a, b) => Math.abs(a[1]) - Math.abs(b[1]))[0];
      const bx = pick(x, m.w), by = pick(y, m.h);
      if (bx) { x += bx[1]; g.x = bx[0]; }
      if (by) { y += by[1]; g.y = by[0]; }
      node.position({ x, y });
    }
    setGuides(g);
    applyMulti(node, 1);
  };

  // A tile from the Add section, or pictures from the computer (added to Gather first): placed where dropped.
  const onDrop = (e: React.DragEvent) => {
    if (!designDrag(e.dataTransfer) || !doc) return;
    e.preventDefault();
    const r = wrap.current!.getBoundingClientRect();
    const at = { x: (e.clientX - r.left - ox) / S, y: (e.clientY - r.top - oy) / S };
    void layersFromDrop(doc.program, e.dataTransfer, at).then((layers) => insertLayers(layers));
  };

  if (!doc) return <div ref={wrap} className={"stage backdrop-" + backdrop}><div className="empty" style={{ color: "#fff" }}><span className="spin" /> Loading the design…</div></div>;
  const lb = selLayer ? layerBox(doc.program, selLayer, S, media) : null;
  const showReal = glass && real.img && !transient;

  return (
    <div ref={wrap} className={"stage backdrop-" + backdrop} onDragOver={(e) => { if (designDrag(e.dataTransfer)) { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; } }} onDrop={onDrop}>
      <Stage width={box.w} height={box.h} onMouseDown={onDown}>
        <KLayer ref={layerRef}>
          <Group x={ox} y={oy}>
            {selLayer && !selLayer.hidden && <Shape listening={false} sceneFunc={(ctx) => drawGhost(ctx._context, doc, selLayer.id, S, media)} />}
            <Shape listening={false} visible={!showReal} sceneFunc={(ctx) => {
              const c = ctx._context;
              c.save(); c.shadowColor = "rgba(0,0,0,.28)"; c.shadowBlur = 22 * (window.devicePixelRatio || 1); c.shadowOffsetY = 10 * (window.devicePixelRatio || 1);
              c.fillStyle = "rgba(0,0,0,.35)"; c.beginPath(); c.roundRect(2, 2, S - 4, S - 4, S * 0.2237); c.fill(); c.restore();
              drawSketch(c, doc, S, { appearance, pixelRatio: window.devicePixelRatio || 1, media });
            }} />
            {showReal && <KImage image={real.img!} listening={false} x={-S * RENDER_INSET / (1 - 2 * RENDER_INSET)} y={-S * RENDER_INSET / (1 - 2 * RENDER_INSET)} width={S / (1 - 2 * RENDER_INSET)} height={S / (1 - 2 * RENDER_INSET)} />}
            {grid && <Shape listening={false} sceneFunc={(ctx) => drawGrid(ctx._context, S)} />}
            {guides.x != null && <Line points={[guides.x, -20, guides.x, S + 20]} stroke="#ff3b8d" strokeWidth={1} listening={false} />}
            {guides.y != null && <Line points={[-20, guides.y, S + 20, guides.y]} stroke="#ff3b8d" strokeWidth={1} listening={false} />}
            {lb && selLayer && !selLayer.hidden && (
              <Rect ref={proxy} x={lb.cx} y={lb.cy} width={lb.w} height={lb.h} offsetX={lb.w / 2} offsetY={lb.h / 2} rotation={selLayer.transform.rotation}
                draggable fill="rgba(0,0,0,0)" stroke="rgba(36,99,217,.9)" strokeWidth={1} strokeScaleEnabled={false}
                onDragMove={(e) => setTransform(e.target as Konva.Rect, !e.evt.altKey && !e.evt.metaKey)}
                onDragEnd={() => { setGuides({}); useDesign.getState().commit(); }}
                onTransform={(e) => {
                  const n = e.target as Konva.Rect;
                  const sx = n.scaleX();
                  n.width(Math.max(4, n.width() * sx)); n.height(Math.max(4, n.height() * sx));
                  n.offsetX(n.width() / 2); n.offsetY(n.height() / 2); n.scale({ x: 1, y: 1 });
                  setTransform(n, false, true); // the resize's snapping set the guides
                }}
                onTransformEnd={() => { setGuides({}); useDesign.getState().commit(); }}
                onMouseEnter={(e) => { e.target.getStage()!.container().style.cursor = "move"; }}
                onMouseLeave={(e) => { e.target.getStage()!.container().style.cursor = ""; }} />
            )}
            {union && !selLayer && (
              <Rect ref={mproxy} x={union.x} y={union.y} width={union.w} height={union.h}
                draggable fill="rgba(0,0,0,0)" stroke="rgba(36,99,217,.9)" strokeWidth={1} strokeScaleEnabled={false} dash={[4, 3]}
                onDragStart={(e) => startMulti(e.target as Konva.Rect)}
                onDragMove={(e) => dragMulti(e.target as Konva.Rect, !e.evt.altKey && !e.evt.metaKey)}
                onDragEnd={() => { setGuides({}); mstart.current = null; useDesign.getState().commit(); }}
                onTransformStart={(e) => startMulti(e.target as Konva.Rect)}
                onTransform={(e) => {
                  const n = e.target as Konva.Rect; const m = mstart.current; if (!m) return;
                  const k = (n.width() * n.scaleX()) / m.w;
                  n.width(m.w * k); n.height(m.h * k); n.scale({ x: 1, y: 1 });
                  applyMulti(n, k);
                }}
                onTransformEnd={() => { setGuides({}); mstart.current = null; useDesign.getState().commit(); }}
                onMouseEnter={(e) => { e.target.getStage()!.container().style.cursor = "move"; }}
                onMouseLeave={(e) => { e.target.getStage()!.container().style.cursor = ""; }} />
            )}
            <Transformer ref={tr} keepRatio rotateEnabled={!union || !!selLayer} flipEnabled={false} centeredScaling={false}
              enabledAnchors={["top-left", "top-right", "bottom-left", "bottom-right"]}
              rotationSnaps={[0, 45, 90, 135, 180, 225, 270, 315]} rotationSnapTolerance={4}
              anchorSize={9} anchorCornerRadius={2} anchorStroke="#2463d9" borderStroke="#2463d9" anchorFill="#fff" rotateAnchorOffset={22}
              boundBoxFunc={snapResize} ignoreStroke />
          </Group>
        </KLayer>
      </Stage>
      {glass && real.pending && <div className="render-wait"><span className="render-note"><span className="spin" /> Rendering the final icon…</span></div>}
      {glass && real.error && !real.pending && <div className="render-note bad">The real render failed: {real.error}</div>}
      <SmallPreviews doc={doc} appearance={appearance} />
    </div>
  );
}

/** The selected layer drawn faintly in full, so a part outside the icon (or masked away) can still be seen. */
function drawGhost(ctx: CanvasRenderingContext2D, doc: Doc, id: string, S: number, media: Map<string, any>) {
  const hit = findLayer(doc, id); if (!hit) return;
  const l = hit.layer;
  const b = layerBox(doc.program, l, S, media);
  const got = l.content.kind === "image" ? resources.content(doc.program, l.content, Math.max(b.w, b.h), l.transform.width) : resources.shape(doc.program, l.content.shape, Math.max(b.w, b.h));
  if (!got) return;
  ctx.save();
  ctx.globalAlpha = 0.28;
  ctx.translate(b.cx, b.cy); ctx.rotate(b.rot);
  drawInBox(ctx, got.img, "box" in got ? got.box : [0, 0, 1, 1], b.w, b.h);
  ctx.restore();
}

/** An Icon Composer-style grid: centre lines, diagonals, circles and the keyline square. */
function drawGrid(ctx: CanvasRenderingContext2D, S: number) {
  ctx.save();
  ctx.lineWidth = 1;
  const stroke = (f: () => void) => {
    ctx.strokeStyle = "rgba(0,0,0,.35)"; ctx.setLineDash([]); ctx.beginPath(); f(); ctx.stroke();
    ctx.strokeStyle = "rgba(255,255,255,.75)"; ctx.setLineDash([3, 3]); ctx.beginPath(); f(); ctx.stroke();
  };
  stroke(() => { ctx.moveTo(S / 2, 0); ctx.lineTo(S / 2, S); ctx.moveTo(0, S / 2); ctx.lineTo(S, S / 2); });
  stroke(() => { ctx.moveTo(0, 0); ctx.lineTo(S, S); ctx.moveTo(S, 0); ctx.lineTo(0, S); });
  for (const r of [0.4, 0.3, 0.16]) stroke(() => ctx.arc(S / 2, S / 2, S * r, 0, Math.PI * 2));
  stroke(() => ctx.rect(S * 0.1, S * 0.1, S * 0.8, S * 0.8));
  stroke(() => ctx.rect(S * 0.2, S * 0.2, S * 0.6, S * 0.6));
  ctx.restore();
}

/** ictool's render of `doc`, asked for a moment after it stops changing; the last one stays up meanwhile. */
function useRealRender(doc: Doc | null, appearance: string, S: number, paused: boolean) {
  const [state, setState] = useState<{ img: HTMLImageElement | null; key: string | null; pending: boolean; error: string | null }>({ img: null, key: null, pending: false, error: null });
  const size = Math.min(1024, [256, 512, 1024].find((b) => b >= S * (window.devicePixelRatio || 1)) ?? 1024);
  const key = doc ? iconKey(doc, appearance as any, size) : null;
  useEffect(() => {
    if (!doc || paused || !key) return;
    let live = true;
    const have = cachedIconRender(doc, appearance as any, size);
    if (have) { void loadImage(have).then((img) => { if (live) setState({ img, key, pending: false, error: null }); }); return () => { live = false; }; }
    setState((s) => ({ ...s, pending: true, error: null }));
    requestIconRender(doc, appearance as any, size, 0)
      .then((u) => loadImage(u))
      .then((img) => { if (live) setState({ img, key, pending: false, error: null }); })
      .catch((e) => { if (live && e?.name !== "AbortError") setState((s) => ({ ...s, pending: false, error: String(e?.message ?? e) })); });
    return () => { live = false; };
  }, [doc, appearance, size, paused, key]);
  // Only a render of this very doc counts: an older one is never shown as "Final".
  return { ...state, img: state.key === key ? state.img : null, pending: state.pending || (!!key && state.key !== key && !state.error) };
}
