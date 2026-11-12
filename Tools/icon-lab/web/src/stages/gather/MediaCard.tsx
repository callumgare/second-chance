// A media card in the grid: the picture (whole, zoomed to its parts, or its parts alone), its kind when we're
// sure of it, its size, source and suitability; the pick circle (empty, half or full from its parts) and badges
// for the parts picked, the hi-res state, a stack of duplicates folded under it, and an image derived from another.
import { memo } from "react";
import type { Media } from "../../api";
import { PartImg, WholeThumb } from "../../parts/PartImage";
import { isPicked, shownParts } from "../../parts/frames";

export const KIND_LABELS: Record<string, string> = {
  "box-front": "Box front", "box-back": "Box back", "box-spine": "Box spine", disc: "Disc", logo: "Logo", icon: "Icon",
  "title-screen": "Title screen", screenshot: "Screenshot", banner: "Banner", manual: "Manual", cutout: "Cut-out", art: "Art", other: "Other",
  unknown: "No kind",
};
/** A kind's name, for kinds this page knows and ones the engine adds later ("floppy-disk" → "Floppy disk"). */
export const kindLabel = (k: string) => KIND_LABELS[k] ?? (k.charAt(0).toUpperCase() + k.slice(1).replace(/-/g, " "));

export const Suit = ({ n }: { n: number }) => (
  <span className="suit" title={`Suitability ${Math.round(n * 10) / 10} of 5`}>{[1, 2, 3, 4, 5].map((i) => <i key={i} className={i <= Math.round(n) ? "f" : ""} />)}</span>
);

/** "hi-res" only when a larger copy really replaced the picture; a small badge while one is being looked for. */
export const HiresBadge = ({ m }: { m: Media }) => {
  const state = m.hires;
  if (state === "queued" || state === "running") return <span className={"hires " + state} title="Looking for a larger copy, then analysing it more deeply"><span className="spin tiny" />finding a larger copy…</span>;
  if (m.upgraded) return <span className="hires done" title={`A larger copy replaced the picture: now ${m.width}×${m.height}`}>✓ hi-res</span>;
  return null;
};

export type Thumbs = "whole" | "parts";
export type PickState = "none" | "some" | "all";

export function pickState(m: Media): PickState {
  const parts = shownParts(m);
  const n = parts.filter((p) => isPicked(m, p)).length;
  if (!parts.length) return m.picked ? "all" : "none";
  return n === 0 ? "none" : n === parts.length ? "all" : "some";
}

type Props = { m: Media; selected: boolean; stack: number; thumbs: Thumbs; onSelect(m: Media, e: React.MouseEvent): void; onPick(m: Media): void; onHide(m: Media, hidden: boolean): void }

const ART = 154;

export const MediaCard = memo(function MediaCard({ m, selected, stack, thumbs, onSelect, onPick, onHide }: Props) {
  const parts = shownParts(m);
  const cut = parts.filter((p) => p.id !== "whole");
  const ps = pickState(m);
  const nPicked = parts.filter((p) => isPicked(m, p)).length;
  const video = (m.deep?.frames ?? 0) > 1;
  return (
    <div className={"card" + (ps !== "none" ? " picked" : "") + (selected ? " sel" : "") + (stack > 1 ? " stacked" : "") + (m.hidden ? " hidden-card" : "")} role="gridcell" aria-selected={selected}
      onClick={(e) => onSelect(m, e)} onDoubleClick={() => onPick(m)} data-id={m.id}>
      <span className="art checker">
        {thumbs === "parts" && cut.length ? (
          <span className="pgrid" style={{ gridTemplateColumns: `repeat(${cut.length === 1 ? 1 : 2}, 1fr)` }}>
            {cut.slice(0, 4).map((p) => <span key={p.id} className={"pcell checker" + (isPicked(m, p) ? " on" : "")} title={p.name}><PartImg m={m} p={p} max={256} /></span>)}
          </span>
        ) : <WholeThumb m={m} size={ART} />}
      </span>
      {m.hidden
        ? <button className="hide-btn unhide" onClick={(e) => { e.stopPropagation(); onHide(m, false); }} title="Unhide (H)">Unhide</button>
        : <button className="hide-btn" onClick={(e) => { e.stopPropagation(); onHide(m, true); }} aria-label="Hide this picture" title="Hide this picture (H): it won't be used in suggestions">
            <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden><path d="M2 8s2.3-4 6-4 6 4 6 4-2.3 4-6 4-6-4-6-4z" fill="none" stroke="currentColor" strokeWidth="1.5" /><circle cx="8" cy="8" r="1.8" fill="currentColor" /><path d="M3 13 13 3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" /></svg>
          </button>}
      {video && <span className="video-badge" title={`A video: ${m.deep!.frames} frames, each one a part`}>▶ {m.deep!.frames}</span>}
      <span className={"badges-tl" + (video ? " below" : "")}>
        <HiresBadge m={m} />

        {m.derivedFrom && <span className="mark" title="Made from another image by the analysis (straightened, trimmed or its title)">derived</span>}
      </span>
      {parts.length > 1 && <span className="parts-badge" title={parts.map((p) => `${isPicked(m, p) ? "✓" : "·"} ${p.name}`).join("\n")}>{nPicked ? `${nPicked} of ` : ""}{parts.length} parts</span>}
      {stack > 1 && <span className="stack" title={`The same art from ${stack} places: this is the best copy`}>{stack} copies</span>}
      <button className={"pick " + ps} onClick={(e) => { e.stopPropagation(); onPick(m); }} aria-label={ps === "all" ? "Unpick every part" : "Pick every part"}
        aria-pressed={ps === "all" ? true : ps === "some" ? "mixed" : false} title={ps === "some" ? `${nPicked} of ${parts.length} parts picked: click to pick all (P)` : ps === "all" ? "Unpick every part (X)" : "Pick (P)"}>{ps === "all" ? "✓" : ""}</button>
      <span className="info">
        <span className="l1">{m.kind !== "unknown" ? <span className="kind">{kindLabel(m.kind)}</span> : <span />}<span className="dim">{m.width}×{m.height}</span></span>
        <span className="l2"><span className="ellipsis">{m.source}</span><Suit n={m.suitability} /></span>
      </span>
    </div>
  );
});

/** Pixel art, and pictures so small they'd be a speck (a 32×32 icon), are shown big with hard pixels. */
export function smallStyle(m: Media): React.CSSProperties | undefined {
  const tiny = Math.max(m.width, m.height) <= 96;
  if (tiny) return { imageRendering: "pixelated", width: `${Math.min(92, (m.width / Math.max(m.width, m.height)) * 64)}%`, height: "auto" };
  return m.analysis.pixelArt ? { imageRendering: "pixelated" } : undefined;
}
