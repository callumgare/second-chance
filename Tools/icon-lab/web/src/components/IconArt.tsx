// An icon drawn small: the sketch at once, upgraded to ictool's real render when `real` is set and the tile is
// on screen (renders are queued, tiles last). Redraws as layer pixels arrive.
import { useEffect, useRef, useState } from "react";
import type { Appearance, Doc } from "../api";
import { cachedIconRender, peekIconRender, requestIconRender } from "../render/iconRenders";
import { resources } from "../render/resources";
import { sketchCanvas } from "../render/sketch";
import { useApp } from "../state/app";

type Props = {
  doc: Doc
  size: number
  appearance?: Appearance
  /** Ask for the real render: "visible" waits until the tile is on screen. */
  real?: false | "visible" | "eager"
  priority?: number
  /** The real render's pixel size (default: the CSS size at the screen's density). */
  renderSize?: number
  /** While the real render is on its way, dim the sketch and show a spinner. */
  waiting?: boolean
  className?: string
  title?: string
}

export function IconArt({ doc, size, appearance = "light", real = false, priority = 2, renderSize, waiting, className, title }: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const box = useRef<HTMLSpanElement>(null);
  const media = useApp((s) => s.media);
  const [visible, setVisible] = useState(real === "eager");
  const renderPx = Math.min(1024, renderSize ?? Math.round(size * (window.devicePixelRatio || 1)));
  const [url, setUrl] = useState<string | null>(() => (real ? cachedIconRender(doc, appearance, renderPx) : null));

  // The sketch, redrawn when the doc changes or pixels arrive.
  useEffect(() => {
    const draw = () => { if (ref.current) sketchCanvas(doc, size, appearance, media, ref.current); };
    draw();
    return resources.subscribe(draw);
  }, [doc, size, appearance, media]);

  useEffect(() => {
    if (real !== "visible" || !box.current) return;
    const io = new IntersectionObserver((es) => setVisible(es.some((e) => e.isIntersecting)), { rootMargin: "100px" });
    io.observe(box.current);
    return () => io.disconnect();
  }, [real]);

  useEffect(() => {
    if (!real) { setUrl(null); return; }
    const have = cachedIconRender(doc, appearance, renderPx);
    setUrl(have);
    if (have) return;
    let live = true;
    // One the engine already has costs nothing to show, on screen or not; a new one waits until it's seen.
    void peekIconRender(doc, appearance, renderPx).then((u) => { if (live && u) setUrl(u); });
    if (!visible) return () => { live = false; };
    const t = window.setTimeout(() => {
      peekIconRender(doc, appearance, renderPx)
        .then((u) => u ?? requestIconRender(doc, appearance, renderPx, priority))
        .then((u) => { if (live) setUrl(u); }).catch(() => { /* keep the sketch */ });
    }, 120);
    return () => { live = false; window.clearTimeout(t); };
  }, [real, visible, doc, appearance, renderPx, priority]);

  return (
    <span ref={box} className={"icon-art " + (className ?? "")} style={{ width: size, height: size }} title={title}>
      <canvas ref={ref} style={{ visibility: url ? "hidden" : "visible", opacity: waiting && real && !url ? 0.55 : 1 }} />
      {url && <img src={url} alt="" draggable={false} />}
      {waiting && real && !url && <span className="art-wait"><span className="spin" /></span>}
    </span>
  );
}
