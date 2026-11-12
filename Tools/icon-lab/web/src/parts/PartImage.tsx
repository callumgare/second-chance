// A part's picture, cut and turned the way it will be used; and the grid's whole-picture thumbnail that zooms
// to a picture's parts (bright) over the rest of it (dimmed).
import { useEffect, useState } from "react";
import type { Media, Part } from "../api";
import { partUrl } from "./shim";

export function PartImg({ m, p, max = 256, className, style }: { m: Media; p: Part; max?: number; className?: string; style?: React.CSSProperties }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    partUrl(m, p, max).then((u) => { if (live) setUrl(u); }).catch(() => { if (live) setUrl(null); });
    return () => { live = false; };
  }, [m, p, max]);
  const tiny = Math.max(p.size[0], p.size[1]) <= 96;
  return url ? <img key={url} className={className} src={url} alt="" draggable={false} style={{ ...(tiny || m.analysis.pixelArt ? { imageRendering: "pixelated" } : {}), ...style }} /> : <span className={"part-ph " + (className ?? "")} />;
}

/** Union of the boxes of a picture's parts other than the whole: what the whole thumbnail zooms to. */
export function zoomBox(parts: Part[]): [number, number, number, number] | null {
  const ps = parts.filter((p) => p.id !== "whole");
  if (!ps.length) return null;
  let x0 = 1, y0 = 1, x1 = 0, y1 = 0;
  for (const p of ps) { x0 = Math.min(x0, p.box[0]); y0 = Math.min(y0, p.box[1]); x1 = Math.max(x1, p.box[0] + p.box[2]); y1 = Math.max(y1, p.box[1] + p.box[3]); }
  return [x0, y0, x1 - x0, y1 - y0];
}

/** The whole picture in a square tile, in full: turned by its rotation, fitted and centred (a long thin banner
 *  is never top-aligned). Parts don't change it; the Parts thumbnails show those. */
export function WholeThumb({ m, size }: { m: Media; size: number }) {
  const W = m.width, H = m.height, r = m.rotation ?? 0;
  const side = r === 90 || r === 270;
  const [rw, rh] = side ? [H, W] : [W, H];
  const scale = Math.min(size / rw, size / rh) * 0.92;
  const tiny = Math.max(W, H) <= 128;
  return (
    <span className="wthumb" style={{ width: size, height: size }}>
      <span className="wstage" style={{ transform: `translate(${size / 2}px, ${size / 2}px) rotate(${r}deg) scale(${scale}) translate(${-W / 2}px, ${-H / 2}px)` }}>
        <img src={m.thumb} alt="" draggable={false} style={{ width: W, height: H, ...(tiny ? { imageRendering: "pixelated" } : {}) }} />
      </span>
    </span>
  );
}
