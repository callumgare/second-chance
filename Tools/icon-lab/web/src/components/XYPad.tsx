// A 2-D position: a small square with crosshair lines and a dot at (x, y). Drag anywhere in it (the dot jumps
// there and follows); an axis lock (free, ↔ only, ↕ only), and Shift while dragging locks to the axis moved first;
// double-click or ↺ recentres; arrow keys nudge when it's focused (Shift ×10); the values sit beside it as small
// number fields. `onChange(x, y, live)` fires while dragging (live) and once when let go.
import { useEffect, useRef, useState } from "react";
import { NumberField } from "./controls";

type Range = [number, number];
type Lock = "free" | "x" | "y";

export function XYPad({ x, y, xRange: xBase, yRange: yBase, centre = [0, 0], step = 0.005, onChange, format = (v) => String(Math.round(v * 1024)), toField, fromField, frame, label, size = 84 }: {
  x: number; y: number; xRange: Range; yRange: Range; centre?: [number, number]; step?: number
  onChange(x: number, y: number, live: boolean): void
  /** How the values read (default: points of the 1024 canvas). */
  format?: (v: number) => string
  /** The number fields' units: to them from a value, and back. Default: points of the 1024 canvas. */
  toField?: (v: number) => number; fromField?: (v: number) => number
  /** A rectangle (in values) to outline inside the pad, e.g. the canvas. */
  frame?: [number, number, number, number]
  label?: string; size?: number
}) {
  const pad = useRef<HTMLDivElement>(null);
  const [lock, setLock] = useState<Lock>("free");
  // The range grows (×2) when the knob is let go more than halfway out, and shrinks (÷2, never below the
  // default) when it's let go under a quarter of the way out. The value never moves; the scale does.
  const [zoom, setZoom] = useState(1);
  const [dragging, setDragging] = useState(false);
  const span = (r: Range, c: number, k: number): Range => [c - (c - r[0]) * k, c + (r[1] - c) * k];
  const xRange = span(xBase, centre[0], zoom), yRange = span(yBase, centre[1], zoom);
  /** How far out a point is, 0 at the centre and 1 at the nearer edge in its direction, at zoom `k`. */
  const reach = (px: number, py: number, k: number) => {
    const xr = span(xBase, centre[0], k), yr = span(yBase, centre[1], k);
    const rx = px >= centre[0] ? (px - centre[0]) / (xr[1] - centre[0] || 1) : (centre[0] - px) / (centre[0] - xr[0] || 1);
    const ry = py >= centre[1] ? (py - centre[1]) / (yr[1] - centre[1] || 1) : (centre[1] - py) / (centre[1] - yr[0] || 1);
    return Math.max(rx, ry);
  };
  /** The zoom that suits a value: grow until it's at most halfway out; shrink one step if it's well inside. */
  const fit = (px: number, py: number, k: number, settle: boolean) => {
    let z = k;
    if (reach(px, py, z) > 0.5) { while (reach(px, py, z) > 0.5 && z < 256) z *= 2; }
    else if (settle && z > 1 && reach(px, py, z) < 0.25) z = Math.max(1, z / 2);
    return z;
  };
  // A value set from outside (an undo, a drag on the canvas) beyond the range widens it too.
  useEffect(() => { if (!dragging) setZoom((z) => (reach(x, y, z) > 1 ? fit(x, y, z, false) : z)); }, [x, y]); // eslint-disable-line react-hooks/exhaustive-deps
  const set = (nx: number, ny: number, live: boolean) => {
    // A typed or nudged value beyond the range widens it to fit.
    if (!live) setZoom((z) => fit(nx, ny, z, false));
    onChange(nx, ny, live);
  };
  const drag = useRef<{ x0: number; y0: number; axis: Lock | null; moved: boolean } | null>(null);
  const tf = toField ?? ((v: number) => Math.round(v * 1024 * 10) / 10);
  const ff = fromField ?? ((v: number) => v / 1024);
  const clampX = (v: number) => Math.max(xRange[0], Math.min(xRange[1], v));
  const clampY = (v: number) => Math.max(yRange[0], Math.min(yRange[1], v));
  const fx = (v: number) => (v - xRange[0]) / (xRange[1] - xRange[0]);
  const fy = (v: number) => (v - yRange[0]) / (yRange[1] - yRange[0]);

  const at = (e: React.PointerEvent) => {
    const r = pad.current!.getBoundingClientRect();
    return {
      x: clampX(xRange[0] + ((e.clientX - r.left) / r.width) * (xRange[1] - xRange[0])),
      y: clampY(yRange[0] + ((e.clientY - r.top) / r.height) * (yRange[1] - yRange[0])),
    };
  };
  const apply = (nx: number, ny: number, shift: boolean, live: boolean) => {
    const d = drag.current;
    let axis: Lock = lock;
    if (axis === "free" && shift && d) {
      if (!d.axis) {
        const dx = Math.abs(fx(nx) - fx(d.x0)), dy = Math.abs(fy(ny) - fy(d.y0));
        if (dx + dy > 0.03) d.axis = dx >= dy ? "x" : "y";
      }
      axis = d.axis ?? "free";
    }
    onChange(axis === "y" ? (d?.x0 ?? x) : nx, axis === "x" ? (d?.y0 ?? y) : ny, live);
  };

  const cx = fx(centre[0]) * 100, cy = fy(centre[1]) * 100;
  return (
    <div className="xy">
      <div ref={pad} className={"xy-pad" + (dragging ? "" : " anim")} tabIndex={0} role="slider" aria-label={label ?? "Position"} aria-valuetext={`${format(x)}, ${format(y)}`}
        style={{ width: size, height: size }}
        onPointerDown={(e) => {
          e.preventDefault();
          setDragging(true);
          (e.currentTarget as HTMLElement).focus();
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          drag.current = { x0: x, y0: y, axis: null, moved: false };
          const p = at(e); apply(p.x, p.y, e.shiftKey, true);
        }}
        onPointerMove={(e) => { if (!drag.current) return; drag.current.moved = true; const p = at(e); apply(p.x, p.y, e.shiftKey, true); }}
        onPointerUp={(e) => {
          if (!drag.current) return;
          const p = at(e); apply(p.x, p.y, e.shiftKey, false); drag.current = null;
          setDragging(false);
          setZoom((z) => fit(p.x, p.y, z, true));
        }}
        onPointerCancel={() => { drag.current = null; setDragging(false); onChange(x, y, false); }}
        onDoubleClick={() => { setZoom(1); onChange(centre[0], centre[1], false); }}
        onKeyDown={(e) => {
          const k = e.shiftKey ? 10 : 1;
          const by: Record<string, [number, number]> = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
          const d = by[e.key];
          if (!d) return;
          e.preventDefault(); e.stopPropagation();
          set(lock === "y" ? x : x + d[0] * step * k * zoom, lock === "x" ? y : y + d[1] * step * k * zoom, false);
        }}>
        <span className="xy-half" style={{ left: `${fx(span(xBase, centre[0], zoom / 2)[0]) * 100}%`, top: `${fy(span(yBase, centre[1], zoom / 2)[0]) * 100}%`, right: `${(1 - fx(span(xBase, centre[0], zoom / 2)[1])) * 100}%`, bottom: `${(1 - fy(span(yBase, centre[1], zoom / 2)[1])) * 100}%` }} />
        <span className="xy-scale" title="The pad's range: let go past halfway to widen it, near the middle to narrow it">±{format((xRange[1] - xRange[0]) / 2)}</span>
        {frame && <span className="xy-frame" style={{ left: `${fx(frame[0]) * 100}%`, top: `${fy(frame[1]) * 100}%`, width: `${(fx(frame[0] + frame[2]) - fx(frame[0])) * 100}%`, height: `${(fy(frame[1] + frame[3]) - fy(frame[1])) * 100}%` }} />}
        <span className="xy-h" style={{ top: `${cy}%` }} />
        <span className="xy-v" style={{ left: `${cx}%` }} />
        <span className="xy-dot" style={{ left: `${fx(clampX(x)) * 100}%`, top: `${fy(clampY(y)) * 100}%` }} />
      </div>
      <div className="xy-side">
        <label className="xy-f"><span>x</span><NumberField className="text num" value={tf(x)} step={1} onChange={(v) => set(ff(v), y, false)} /></label>
        <label className="xy-f"><span>y</span><NumberField className="text num" value={tf(y)} step={1} onChange={(v) => set(x, ff(v), false)} /></label>
        <div className="row" style={{ gap: 3 }}>
          <span className="seg xy-lock" role="radiogroup" aria-label="Axis lock">
            {([["free", "✥", "Move freely (Shift locks to the first axis moved)"], ["x", "↔", "Across only"], ["y", "↕", "Up and down only"]] as const).map(([v, t, title]) => (
              <button key={v} role="radio" aria-checked={lock === v} className={lock === v ? "on" : ""} title={title} onClick={() => setLock(v)}>{t}</button>
            ))}
          </span>
          <button className="icon-btn" title="Recentre (double-click the pad)" aria-label="Recentre" onClick={() => { setZoom(1); onChange(centre[0], centre[1], false); }}>↺</button>
        </div>
      </div>
    </div>
  );
}
