// Videos found in your files: one media item whose frames are "frame" parts ("frame-<n>"); `deep.bestFrame` names
// the best, which the "whole" part repeats (and the first cut-outs come from). Cut-outs found in other frames are
// parts with `frame` set ("f<n>-subject", …). For a video the page hides "whole": the best frame stands for it.
import type { Media, Part } from "../api";

export const isVideo = (m: Media) => !!m.deep?.bestFrame || (m.deep?.frames ?? 0) > 1 || (m.parts ?? []).some((p) => p.source === "frame");

const numOf = (id: string | undefined) => { const n = Number((id ?? "").replace(/^frame-/, "")); return Number.isFinite(n) && id ? n : null; };

/** A frame part's number; null when the part isn't a frame. */
export function frameNo(_m: Media, p: Part): number | null {
  return p.source === "frame" ? numOf(p.id) : null;
}

/** The best frame's part id ("frame-2"), from `deep.bestFrame`, else the whole's name ("Frame 2 (best)"). */
export function bestFrameId(m: Media): string | null {
  if (!isVideo(m)) return null;
  if (m.deep?.bestFrame) return m.deep.bestFrame;
  const whole = m.parts?.find((p) => p.id === "whole");
  const k = whole?.name.match(/Frame\s+(\d+)/i);
  return k ? `frame-${k[1]}` : null;
}

/** The parts the page shows: for a video, everything but "whole". */
export function shownParts(m: Media): Part[] {
  const parts = m.parts ?? [];
  return isVideo(m) ? parts.filter((p) => p.id !== "whole") : parts;
}

/** Is a part picked, counting an old pick of a video's whole as its best frame's. */
export function isPicked(m: Media, p: Part): boolean {
  if (p.picked) return true;
  return p.id === bestFrameId(m) && !!m.parts?.find((x) => x.id === "whole")?.picked;
}

/** A video's frames in time order. */
export function framesOf(m: Media): Part[] {
  return (m.parts ?? []).filter((p) => p.source === "frame").sort((a, b) => (numOf(a.id) ?? 0) - (numOf(b.id) ?? 0));
}

/** Cut and cropped parts (not frames): the best frame's first, then other frames' in frame order. */
export function cutPartsOf(m: Media): Part[] {
  const cut = shownParts(m).filter((p) => p.source !== "frame");
  const own = cut.filter((p) => !p.frame), fromFrames = cut.filter((p) => p.frame);
  return [...own, ...fromFrames.sort((a, b) => (numOf(a.frame) ?? 0) - (numOf(b.frame) ?? 0))];
}

/** The shown parts in time order: a video's frames, then its cut-outs; anything else as it is. */
export function timeOrder(m: Media): Part[] {
  return isVideo(m) ? [...framesOf(m), ...cutPartsOf(m)] : (m.parts ?? []);
}
