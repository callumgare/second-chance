// A picture as large as fits the window, on a dark scrim (a checkerboard where it's transparent), with its name,
// size and source below. × / Esc / a click on the scrim closes; ← → step through the items; P toggles the pick of
// the item shown when it can be picked.
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";

export type LightboxItem = { key: string; url: string; name: string; detail?: string; pixelated?: boolean; picked?: boolean; onTogglePick?(): void; action?: { label: string; onClick(): void; busy?: boolean; disabled?: boolean; title?: string } };

export function Lightbox({ items, index, onIndex, onClose }: { items: LightboxItem[]; index: number; onIndex(i: number): void; onClose(): void }) {
  const it = items[index];
  const [loaded, setLoaded] = useState(false);
  const [aspect, setAspect] = useState(1);
  useEffect(() => setLoaded(false), [it?.url]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); onClose(); }
      else if (e.key === "ArrowRight" && items.length > 1) { e.preventDefault(); e.stopImmediatePropagation(); onIndex((index + 1) % items.length); }
      else if (e.key === "ArrowLeft" && items.length > 1) { e.preventDefault(); e.stopImmediatePropagation(); onIndex((index - 1 + items.length) % items.length); }
      else if ((e.key === "p" || e.key === "P") && it?.onTogglePick) { e.preventDefault(); e.stopImmediatePropagation(); it.onTogglePick(); }
    };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  }, [index, items, it, onClose, onIndex]);
  if (!it) return null;
  return createPortal(
    <div className="lightbox" role="dialog" aria-label={it.name} onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <button className="lb-close" aria-label="Close (Esc)" title="Close (Esc)" onClick={onClose}>×</button>
      {items.length > 1 && <>
        <button className="lb-nav prev" aria-label="Previous (←)" onClick={() => onIndex((index - 1 + items.length) % items.length)}>‹</button>
        <button className="lb-nav next" aria-label="Next (→)" onClick={() => onIndex((index + 1) % items.length)}>›</button>
      </>}
      <figure className="lb-fig" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
        <span className="lb-img checker">
          <img key={it.url} src={it.url} alt={it.name}
            onLoad={(e) => { const i = e.currentTarget; setAspect(i.naturalWidth / Math.max(1, i.naturalHeight)); setLoaded(true); }}
            // As large as fits, small pictures enlarged too.
            style={{ imageRendering: it.pixelated ? "pixelated" : "auto", opacity: loaded ? 1 : 0, width: `min(calc(100vw - 140px), calc((100vh - 120px) * ${aspect}))`, height: "auto" }} />
          {!loaded && <span className="spin lb-spin" />}
        </span>
        <figcaption>
          <b>{it.name}</b>{it.detail && <span> · {it.detail}</span>}
          {items.length > 1 && <span className="lb-count"> · {index + 1} of {items.length}</span>}
          {it.onTogglePick && <button className={"btn small" + (it.picked ? " on" : "")} onClick={it.onTogglePick} title="Toggle the pick (P)">{it.picked ? "✓ Picked" : "Pick"}</button>}
          {it.action && <button className="btn small" disabled={it.action.busy || it.action.disabled} title={it.action.title} onClick={it.action.onClick}>{it.action.busy && <span className="spin small" />} {it.action.label}</button>}
        </figcaption>
      </figure>
    </div>,
    document.body,
  );
}
