// A horizontal divider that resizes the section below it: an always-visible little bar to grab. Drag up to make
// the section taller, down to make it shorter; double-click resets it; ↑ ↓ resize when it's focused.
import { useRef, useState } from "react";

export function ResizeHandle({ height, min, max, reset, onResize, onResizing, label, className = "" }: {
  height: number; min: number; max: number; reset: number
  onResize(h: number): void; onResizing?(v: boolean): void
  label: string; className?: string
}) {
  const start = useRef<{ y: number; h: number } | null>(null);
  const [dragging, setDragging] = useState(false);
  const clamp = (h: number) => Math.max(min, Math.min(max, h));
  const end = () => { start.current = null; setDragging(false); onResizing?.(false); };
  return (
    <div className={"resize-handle" + (dragging ? " dragging" : "") + (className ? " " + className : "")} role="separator" aria-orientation="horizontal"
      aria-label={label} aria-valuenow={Math.round(height)} aria-valuemin={min} aria-valuemax={max} tabIndex={0} title="Drag to resize, double-click to reset"
      onPointerDown={(e) => { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); start.current = { y: e.clientY, h: height }; setDragging(true); onResizing?.(true); }}
      onPointerMove={(e) => { if (start.current) onResize(clamp(start.current.h - (e.clientY - start.current.y))); }}
      onPointerUp={end} onPointerCancel={end}
      onDoubleClick={() => onResize(clamp(reset))}
      onKeyDown={(e) => {
        const by = e.shiftKey ? 60 : 20;
        if (e.key === "ArrowUp") { e.preventDefault(); e.stopPropagation(); onResize(clamp(height + by)); }
        else if (e.key === "ArrowDown") { e.preventDefault(); e.stopPropagation(); onResize(clamp(height - by)); }
      }}>
      <span />
    </div>
  );
}
