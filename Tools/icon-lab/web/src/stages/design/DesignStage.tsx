// Stage 3, layout A ("Workbench"): media drawer, canvas, layers, inspector; pins under the canvas; the
// suggestions row and "adjust all" along the bottom. The row expands into the gallery (layout B).
import { allLayersAndMasks } from "../../lib/doc";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ResizeHandle } from "../../components/ResizeHandle";
import { api } from "../../api";
import { go } from "../../lib/router";
import { pinnedMatch, useDesign } from "../../state/design";
import { useApp } from "../../state/app";
import { StatusSlot, TitleActions } from "../../shell/slots";
import { Seg } from "../../components/controls";
import { EditorCanvas } from "./EditorCanvas";
import { setZoom, useZoom, zoomFit, zoomStep, ZOOM_MAX, ZOOM_MIN } from "../../state/zoom";
import { LayersPanel } from "./LayersPanel";
import { Inspector } from "./inspector/Inspector";
import { PinsStrip } from "./PinsStrip";
import { AppearanceSeg, Gallery, RenderModeSeg, SuggestionsBar, SuggestionsRow } from "./Suggestions";
import { AdjustAll } from "./AdjustAll";
import { deleteSelected, duplicateSelected, nudge, toggleHiddenSelected } from "./actions";
import { installClipboard } from "./clipboard";
import "./design.css";

const DOCK_H = 248, DOCK_MIN = 150, CANVAS_MIN = 300;


export function DesignStage({ slug }: { slug: string }) {
  const loading = useDesign((s) => s.loading || s.slug !== slug);
  const gallery = useDesign((s) => s.galleryOpen);
  const pins = useDesign((s) => s.pins.length);
  // The bottom section grows into the gallery (and back) by animating its height; its content switches to the
  // gallery at once when expanding, and back to the row once collapsed.
  const wb = useRef<HTMLDivElement>(null);
  const [wbH, setWbH] = useState(800);
  useLayoutEffect(() => {
    const el = wb.current; if (!el) return;
    const ro = new ResizeObserver(() => setWbH(el.clientHeight));
    ro.observe(el); setWbH(el.clientHeight);
    return () => ro.disconnect();
  }, []);
  const [showGallery, setShowGallery] = useState(gallery);
  // The bottom section's height, dragged by its top edge; the canvas row takes the rest.
  const [dockH, setDockHState] = useState(() => { try { return Number(localStorage.getItem("iconlab-dockh")) || DOCK_H; } catch { return DOCK_H; } });
  const setDockH = (h: number) => { setDockHState(h); try { localStorage.setItem("iconlab-dockh", String(Math.round(h))); } catch { /* fine */ } };
  const [resizing, setResizing] = useState(false);
  const maxDock = Math.max(DOCK_MIN, wbH - CANVAS_MIN);
  useEffect(() => {
    if (gallery) { setShowGallery(true); return; }
    const t = window.setTimeout(() => setShowGallery(false), matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 260);
    return () => window.clearTimeout(t);
  }, [gallery]);
  useAutosave();
  useShortcuts();
  useEffect(() => installClipboard(), []);

  return (
    <>
      <div className="wb" ref={wb}>
        <div className={"wb-top" + (gallery ? " folded" : "")} aria-hidden={gallery}>
          <section className="canvasarea">
            <CanvasToolbar />
            <EditorCanvas />
            <PinsStrip />
          </section>
          <LayersPanel />
          <Inspector />
        </div>
        <div className={"wb-dock" + (resizing ? " resizing" : "")} style={{ height: gallery ? wbH : Math.min(dockH, maxDock) }}>
          {!gallery && <ResizeHandle edge label="Resize the suggestions" height={Math.min(dockH, maxDock)} min={DOCK_MIN} max={maxDock} reset={DOCK_H} onResize={setDockH} onResizing={setResizing} />}
          <SuggestionsBar expanded={gallery} />
          {showGallery ? <Gallery /> : (
            <div className="wb-bottom">
              <SuggestionsRow />
              <div className="tweak scroll"><AdjustAll /></div>
            </div>
          )}
        </div>
      </div>
      {loading && <div className="loading-cover"><span className="spin" /> Opening the design…</div>}
      <TitleActions.Fill>
        <button className="btn primary" disabled={!pins} onClick={() => go(slug, "review")} title={pins ? "Compare the pinned designs and save the ones to keep" : "Pin a design first"}>
          Review {pins || ""} pinned →
        </button>
      </TitleActions.Fill>
      <StatusSlot.Fill><DesignStatus /></StatusSlot.Fill>
    </>
  );
}

function CanvasToolbar() {
  const s = useDesign();
  return (
    <div className="bar2">
      <div className="row">
        <AppearanceSeg />
        <RenderModeSeg which="canvas" />
      </div>
      <div className="row">
        <Seg value={s.backdrop} options={["desktop", "grey", "dark"] as const} onChange={(v) => s.set({ backdrop: v })} />
        <button className={"btn small" + (s.grid ? " on" : "")} onClick={() => s.set({ grid: !s.grid })} title="Icon grid (#)">⊞ Grid</button>
        <ZoomControl />
        <button className="btn small" disabled={!s.past.length} onClick={s.undo} title="Undo (⌘Z)">Undo</button>
        <button className="btn small" disabled={!s.future.length} onClick={s.redo} title="Redo (⇧⌘Z)">Redo</button>
      </div>
    </div>
  );
}

/** The canvas's zoom: −, a logarithmic slider (25 %–800 %, 100 % the fit), +, the percentage and Fit. */
function ZoomControl() {
  const zoom = useZoom((z) => z.zoom);
  const lo = Math.log2(ZOOM_MIN), hi = Math.log2(ZOOM_MAX);
  return (
    <span className="zoomctl">
      <button className="icon-b" title="Zoom out (⌘−)" aria-label="Zoom out" disabled={zoom <= ZOOM_MIN + 1e-3} onClick={() => zoomStep(-1)}>−</button>
      <input type="range" min={lo} max={hi} step={0.01} value={Math.log2(zoom)} aria-label="Zoom" title="Zoom (pinch or ⌘-scroll on the canvas)"
        onChange={(e) => { const v = +e.target.value; setZoom(Math.abs(v) < 0.04 ? 1 : 2 ** v); }} />
      <button className="icon-b" title="Zoom in (⌘+)" aria-label="Zoom in" disabled={zoom >= ZOOM_MAX - 1e-3} onClick={() => zoomStep(1)}>+</button>
      <span className="zoom-pct">{Math.round(zoom * 100)}%</span>
      <button className="btn small" disabled={zoom === 1 && useZoom.getState().pan.x === 0} title="Fit the frame (⌘0)" onClick={zoomFit}>Fit</button>
    </span>
  );
}

function DesignStatus() {
  const doc = useDesign((s) => s.doc);
  const saving = useDesign((s) => s.saving);
  const pins = useDesign((s) => s.pins.length);
  const match = useDesign((s) => pinnedMatch(s));
  const media = useApp((s) => s.program?.media.filter((m) => m.picked).length ?? 0);
  if (!doc) return <span>Loading…</span>;
  return <>
    <span className="ellipsis" style={{ maxWidth: 320 }}><b style={{ color: "var(--fg)", fontWeight: 600 }}>{doc.name}</b>{match ? " · pinned" : ""}</span>
    <span className="sep" />
    <span>{saving === "saving" || saving === "pending" ? "Saving…" : saving === "error" ? <span style={{ color: "var(--bad)" }}>Not saved</span> : saving === "saved" ? "Saved" : ""}</span>
    <span className="sep" />
    <span>{media} media · {pins} pinned</span>
    <span className="faint">⌘Z undo · arrows nudge (⇧ ×10) · ⌫ delete · ⌘D duplicate · P pin · G gallery</span>
  </>;
}

/** The current doc saves itself (PUT …/docs/:id, PUT …/current) a moment after each change. A pin is never
 *  rewritten: an unchanged pinned doc only becomes current. */
function useAutosave() {
  const doc = useDesign((s) => s.doc);
  const saving = useDesign((s) => s.saving);
  const transient = useDesign((s) => s.transientBase != null);
  useEffect(() => {
    if (!doc || transient || saving !== "pending") return;
    const t = window.setTimeout(async () => {
      const st = useDesign.getState();
      if (!st.slug || !st.doc) return;
      const d = st.doc;
      st.set({ saving: "saving" });
      try {
        if (!st.pins.includes(d.id)) await api.putDoc(st.slug, d);
        await api.setCurrent(st.slug, d.id);
        useDesign.setState((s) => ({ docs: { ...s.docs, [d.id]: d }, saving: s.doc === d ? "saved" : s.saving }));
      } catch (e) {
        useDesign.getState().set({ saving: "error" });
        useApp.getState().say("Couldn't save: " + (e as Error).message, "error");
      }
    }, 700);
    return () => window.clearTimeout(t);
  }, [doc, saving, transient]);
}

function useShortcuts() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t.closest("input, textarea, select, [contenteditable]")) return;
      const st = useDesign.getState();
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === "z") { e.preventDefault(); if (e.shiftKey) st.redo(); else st.undo(); return; }
      if (mod && e.key.toLowerCase() === "y") { e.preventDefault(); st.redo(); return; }
      const layerId = st.sel?.kind === "layer" ? st.sel.id : null;
      // Duplicate, delete, nudge and hide act on every selected layer (several, or a group's).
      const many = st.sel?.kind === "layer" || st.sel?.kind === "layers" || st.sel?.kind === "group";
      if (mod && e.key.toLowerCase() === "d" && many) { e.preventDefault(); duplicateSelected(); return; }
      if (mod) return;
      if ((e.key === "Backspace" || e.key === "Delete") && (layerId || st.sel?.kind === "layers")) { e.preventDefault(); deleteSelected(); return; }
      if (e.key.startsWith("Arrow") && many) {
        e.preventDefault();
        const step = (e.shiftKey ? 10 : 1) / 1024;
        nudge(e.key === "ArrowLeft" ? -step : e.key === "ArrowRight" ? step : 0, e.key === "ArrowUp" ? -step : e.key === "ArrowDown" ? step : 0);
        return;
      }
      if (e.key === "Escape") { if (st.galleryOpen) st.set({ galleryOpen: false }); else st.select({ kind: "icon" }); return; }
      if (e.key === "g") { st.set({ galleryOpen: !st.galleryOpen }); return; }
      if (e.key === "l") { st.set({ glass: !st.glass }); return; }
      if (e.key === "#") { st.set({ grid: !st.grid }); return; }
      if (e.key === "p" && !pinnedMatch(st)) { void st.pinCurrent(); return; }
      if (e.key === "h" && many) { toggleHiddenSelected(); return; }
      if (e.key === "Tab" && st.doc) {
        // Cycle the selection through the layers, front to back.
        const all = allLayersAndMasks(st.doc);
        if (!all.length) return;
        e.preventDefault();
        const i = layerId ? all.findIndex((l) => l.id === layerId) : -1;
        const next = all[(i + (e.shiftKey ? -1 : 1) + all.length) % all.length];
        st.select({ kind: "layer", id: next.id });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}
