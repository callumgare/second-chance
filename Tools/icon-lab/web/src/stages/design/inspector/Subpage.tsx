// A page that replaces the inspector's contents for one choice ("‹ Back to inspector", or Esc, returns), and
// the part chooser shown on it: every usable part, grouped by picture, the current one highlighted. Choosing
// applies at once and stays on the page, so several can be compared.
import { useEffect, useMemo, type ReactNode } from "react";
import type { Media, Part } from "../../../api";
import { useApp } from "../../../state/app";
import { PartImg } from "../../../parts/PartImage";
import { timeOrder } from "../../../parts/frames";
import { kindLabel } from "../../gather/MediaCard";

export function InspectorSubpage({ title, onBack, children }: { title: string; onBack(): void; children: ReactNode }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || (e.target as HTMLElement).closest("input, select, textarea")) return;
      e.preventDefault(); e.stopImmediatePropagation(); onBack();
    };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  }, [onBack]);
  return (
    <div className="subpage">
      <div className="subpage-h">
        <button className="btn small ghost" onClick={onBack} autoFocus>‹ Back to inspector</button>
      </div>
      <div className="subpage-title">{title}</div>
      <div className="subpage-body scroll">{children}</div>
    </div>
  );
}

/** "<media>" (the whole picture) or "<media>/<part>". */
export const assetOf = (m: Media, p: Part) => (p.id === "whole" ? m.id : `${m.id}/${p.id}`);
export function partOfAsset(media: Map<string, Media>, asset: string): { m: Media; p: Part | undefined } | null {
  const [mid, pid] = asset.replace(/@(x4|px4)$/, "").split("/");
  const m = media.get(mid);
  return m ? { m, p: m.parts?.find((x) => x.id === (pid ?? "whole")) } : null;
}
export const partName = (m: Media, p?: Part) => (!p || p.id === "whole" ? (m.kind !== "unknown" ? kindLabel(m.kind) : m.name) : p.name);

/** The current choice, small, with a Change… button. */
export function CurrentPart({ asset, onChange, empty = "None chosen" }: { asset: string; onChange(): void; empty?: string }) {
  const media = useApp((s) => s.media);
  const got = asset ? partOfAsset(media, asset) : null;
  return (
    <div className="curpart">
      <span className="th checker">{got?.p ? <PartImg m={got.m} p={got.p} max={128} /> : null}</span>
      <span className="col" style={{ gap: 1, minWidth: 0 }}>
        <b className="ellipsis">{got ? partName(got.m, got.p) : empty}</b>
        {got && <span className="faint ellipsis" style={{ fontSize: 11 }}>{got.p && got.p.id !== "whole" ? `${partName(got.m)} · ` : ""}{got.m.source}</span>}
      </span>
      <button className="btn small" onClick={onChange}>Change…</button>
    </div>
  );
}

export function PartChooser({ value, filter, onChoose, note, showCurrent }: { value: string; filter(m: Media, p: Part): boolean; onChoose(asset: string): void; note?: string
  /** Show the current choice at the top when the filter leaves it out. */
  showCurrent?: boolean }) {
  const all = useApp((s) => s.program?.media);
  const groups = useMemo(() => (all ?? [])
    .filter((m) => !m.hidden && !m.duplicateOf)
    .map((m) => ({ m, parts: timeOrder(m).filter((p) => filter(m, p)) }))
    .filter((g) => g.parts.length)
    .sort((a, b) => Number(b.parts.some((p) => p.picked)) - Number(a.parts.some((p) => p.picked)) || b.m.suitability - a.m.suitability),
  [all, filter]);
  const current = value.replace(/@(x4|px4)$/, "");
  const media = useApp((s) => s.media);
  const cur = showCurrent ? partOfAsset(media, current) : null;
  const curListed = groups.some((g) => g.parts.some((p) => assetOf(g.m, p) === current));
  return (
    <>
      {note && <p className="faint" style={{ fontSize: 11.5, margin: "0 0 8px" }}>{note}</p>}
      {cur?.p && !curListed && (
        <div className="addgroup">
          <div className="addgh">Current <span className="faint">· not picked</span></div>
          <div className="addgrid">
            <button className="addtile checker chosen" aria-pressed title={partName(cur.m, cur.p)} onClick={() => onChoose(current)}>
              <PartImg m={cur.m} p={cur.p} max={256} /><span className="k">{partName(cur.m, cur.p)}</span>
            </button>
          </div>
        </div>
      )}
      {groups.map(({ m, parts }) => (
        <div key={m.id} className="addgroup">
          <div className="addgh wraps">{partName(m)} <span className="faint">· {m.source}</span></div>
          <div className="addgrid">
            {parts.map((p) => {
              const a = assetOf(m, p);
              return (
                <button key={p.id} className={"addtile checker" + (a === current ? " chosen" : "")} aria-pressed={a === current} title={`${partName(m, p)}${p.picked ? " · picked" : ""}`} onClick={() => onChoose(a)}>
                  <PartImg m={m} p={p} max={256} />
                  <span className="k">{partName(m, p)}</span>
                </button>
              );
            })}
          </div>
        </div>
      ))}
      {!groups.length && <div className="empty">Nothing usable yet.</div>}
    </>
  );
}
