// A horizontal divider that resizes the section below it: an always-visible little bar to grab. Drag up to make
// the section taller, down to make it shorter; double-click resets it; ↑ ↓ resize when it's focused.
//
// Every handle looks the same: a line where the section starts, the grip a few pixels inside it. `edge` lays the
// handle over a section's own top edge (a docked panel) rather than taking a row of its own.
//
// With `collapsed` (the section's height when collapsed, its header alone), the section can be dragged all the way
// down to it: let go below `min` and it settles on whichever is nearer, collapsed or `min`.
import { useRef, useState } from "react";

export function ResizeHandle({ height, min, max, reset, onResize, onResizing, label, edge = false, collapsed }: {
  height: number; min: number; max: number; reset: number
  onResize(h: number): void; onResizing?(v: boolean): void
  label: string
  /** Over the top edge of the section it resizes, rather than in a row of its own. */
  edge?: boolean
  /** The section's collapsed height, which dragging and ↓ can reach. */
  collapsed?: number
}) {
  const start = useRef<{ y: number; h: number } | null>(null);
  const [dragging, setDragging] = useState(false);
  const floor = collapsed ?? min;
  const clamp = (h: number) => Math.max(floor, Math.min(max, h));
  // between collapsed and the smallest open height: the nearer of the two
  const settle = (h: number) => (collapsed != null && h < min ? (h - collapsed < (min - collapsed) / 2 ? collapsed : min) : h);
  const end = () => {
    if (!start.current) return;
    start.current = null; setDragging(false); onResizing?.(false);
    const to = settle(height);
    if (to !== height) onResize(to);
  };
  const step = (by: number) => {
    // ↓ from the smallest open height collapses, ↑ from collapsed opens to it
    if (collapsed != null && by < 0 && height <= min) return onResize(collapsed);
    if (collapsed != null && by > 0 && height < min) return onResize(min);
    onResize(clamp(height + by));
  };
  return (
    <div className={"resize-handle" + (edge ? " edge" : "") + (dragging ? " dragging" : "")} role="separator" aria-orientation="horizontal"
      aria-label={label} aria-valuenow={Math.round(height)} aria-valuemin={floor} aria-valuemax={max} tabIndex={0}
      title={collapsed != null ? "Drag to resize, or all the way down to collapse; double-click to reset" : "Drag to resize, double-click to reset"}
      onPointerDown={(e) => { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); start.current = { y: e.clientY, h: height }; setDragging(true); onResizing?.(true); }}
      onPointerMove={(e) => { if (start.current) onResize(clamp(start.current.h - (e.clientY - start.current.y))); }}
      onPointerUp={end} onPointerCancel={end}
      onDoubleClick={() => onResize(clamp(reset))}
      onKeyDown={(e) => {
        const by = e.shiftKey ? 60 : 20;
        if (e.key === "ArrowUp") { e.preventDefault(); e.stopPropagation(); step(by); }
        else if (e.key === "ArrowDown") { e.preventDefault(); e.stopPropagation(); step(-by); }
      }}>
      <span />
    </div>
  );
}
