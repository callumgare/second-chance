// Popovers and menus anchored to the element that opened them, closed by Escape or a click elsewhere.
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

export function usePopup() {
  const [anchor, setAnchor] = useState<DOMRect | null>(null);
  return {
    anchor,
    open: (el: Element) => setAnchor(el.getBoundingClientRect()),
    toggle: (el: Element) => setAnchor((a) => (a ? null : el.getBoundingClientRect())),
    close: () => setAnchor(null),
  };
}

export function Popup({ anchor, onClose, children, className = "popover", align = "left" }: {
  anchor: DOMRect | null; onClose(): void; children: ReactNode; className?: string; align?: "left" | "right"
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  useLayoutEffect(() => {
    if (!anchor || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    let left = align === "right" ? anchor.right - r.width : anchor.left;
    let top = anchor.bottom + 4;
    if (top + r.height > innerHeight - 8) top = Math.max(8, anchor.top - r.height - 4);
    left = Math.max(8, Math.min(left, innerWidth - r.width - 8));
    setPos({ left, top });
  }, [anchor, align]);

  useEffect(() => {
    if (!anchor) return;
    const down = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) onClose(); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    const t = window.setTimeout(() => document.addEventListener("mousedown", down), 0);
    document.addEventListener("keydown", key, true);
    return () => { window.clearTimeout(t); document.removeEventListener("mousedown", down); document.removeEventListener("keydown", key, true); };
  }, [anchor, onClose]);

  if (!anchor) return null;
  return createPortal(
    <div ref={ref} className={className} style={{ left: pos?.left ?? -9999, top: pos?.top ?? -9999 }} onKeyDown={(e) => e.stopPropagation()}>
      {children}
    </div>,
    document.body,
  );
}

export type MenuItem = { label: string; onClick(): void; disabled?: boolean; hint?: string } | "-" | { header: string };

export function Menu({ anchor, onClose, items }: { anchor: DOMRect | null; onClose(): void; items: MenuItem[] }) {
  return (
    <Popup anchor={anchor} onClose={onClose} className="menu">
      {items.map((it, i) =>
        it === "-" ? <hr key={i} /> :
        "header" in it ? <div key={i} className="mh">{it.header}</div> :
        <button key={i} disabled={it.disabled} onClick={() => { onClose(); it.onClick(); }}>
          <span>{it.label}</span>{it.hint && <span className="faint">{it.hint}</span>}
        </button>)}
    </Popup>
  );
}
