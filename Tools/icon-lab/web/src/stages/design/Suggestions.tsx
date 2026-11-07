// Suggestions: generated documents, drawn as sketches and upgraded to real renders while on screen. The row
// under the workbench expands into the gallery (layout B): every suggestion, grouped by the media it uses,
// with "adjust all" at the side. Clicking one opens a copy of it in the editor.
import { useMemo } from "react";
import type { Media, Part, Suggestion } from "../../api";
import { IconArt } from "../../components/IconArt";
import { useApp } from "../../state/app";
import { useDesign } from "../../state/design";
import { AdjustAll } from "./AdjustAll";

function SuggestionTile({ s, size, current }: { s: Suggestion; size: number; current: boolean }) {
  const appearance = useDesign((x) => x.appearance);
  const final = useDesign((x) => x.finalSuggestions);
  return (
    <button className={"tile" + (current ? " on" : "")} title={`${s.title}: ${s.about}\nClick to edit a copy`}
      onClick={() => { void useDesign.getState().openSuggestion(s); useDesign.getState().set({ galleryOpen: false }); }}>
      <IconArt doc={s.doc} size={size} appearance={appearance} real={final ? "visible" : false} waiting />
      <span className="lbl">{s.title}</span>
    </button>
  );
}

function useCurrentOrigin() {
  const doc = useDesign((s) => s.doc);
  const docs = useDesign((s) => s.docs);
  // The suggestion the current doc came from, if it's still the same suggestion (same treatment & params).
  return useMemo(() => {
    let d = doc;
    for (let i = 0; d && i < 20; i++) { if (d.origin) return d.origin.treatment; d = d.parent ? docs[d.parent] : null; }
    return null;
  }, [doc, docs]);
}

export function SuggestionsRow() {
  const list = useDesign((s) => s.suggestions);
  const loading = useDesign((s) => s.suggLoading);
  const origin = useCurrentOrigin();
  return (
    <div className="sugg">
      <div className="strip">
        {list.map((s) => <SuggestionTile key={s.treatment} s={s} size={96} current={origin === s.treatment} />)}
        {!list.length && !loading && <div className="empty">No suggestions: pick a subject image with a cut-out in Gather.</div>}
      </div>
    </div>
  );
}

export function Gallery() {
  const list = useDesign((s) => s.suggestions);
  const loading = useDesign((s) => s.suggLoading);
  const media = useApp((s) => s.media);
  const appearance = useDesign((s) => s.appearance);
  const origin = useCurrentOrigin();
  const groups = useMemo(() => {
    const by = new Map<string, Suggestion[]>();
    for (const s of list) { const k = usesOf(s).join("+"); by.set(k, [...(by.get(k) ?? []), s]); }
    return [...by.entries()].sort((a, b) => b[1].length - a[1].length);
  }, [list]);
  // A use is a media id, or "<media>/<part>" for a part of it.
  const resolve = (id: string) => { const [mid, pid] = id.replace(/@(x4|px4)$/, "").split("/"); const m = media.get(mid); return m ? { m, p: m.parts?.find((x) => x.id === (pid ?? "whole")) } : null; };
  const label = (ids: string[]) => ids.map(resolve).filter(Boolean).map((r) => describe(r!.m, r!.p)).join(" + ") || "Shapes only";
  return (
    <div className="gal">
      <aside className="side scroll">
        <AdjustAll full />
      </aside>
      <div className="body">
        <div className="galgrid scroll">
          {groups.map(([k, items]) => (
            <section key={k}>
              <div className="groupt">
                <span className="uses">{usesOf(items[0]).map(resolve).filter(Boolean).map((r, i) => <img key={i} src={r!.p?.thumb || r!.m.thumb} alt="" />)}</span>
                From {label(usesOf(items[0]))} <small>{items.length}</small>
              </div>
              <div className="gg">
                {items.map((s) => <SuggestionTile key={s.treatment} s={s} size={132} current={origin === s.treatment} />)}
              </div>
            </section>
          ))}
          {!list.length && !loading && <div className="empty">No suggestions for these settings.</div>}
          <span className="sr">{appearance}</span>
        </div>
      </div>
    </div>
  );
}

function describe(m: Media, p?: Part) {
  const pic = m.kind !== "unknown" ? `the ${m.kind.replace(/-/g, " ")}` : `“${m.name.replace(/\.[^.]+$/, "").slice(0, 30)}”`;
  if (!p || p.id === "whole") return pic;
  return `${pic}'s ${p.name.charAt(0).toLowerCase() + p.name.slice(1)}`;
}

export function AppearanceSeg() {
  const appearance = useDesign((s) => s.appearance);
  return <span className="seg">{(["light", "dark", "tinted", "clear"] as const).map((a) => (
    <button key={a} className={a === appearance ? "on" : ""} onClick={() => useDesign.getState().set({ appearance: a })}>{a[0].toUpperCase() + a.slice(1)}</button>
  ))}</span>;
}

/** Preview (the browser's sketches, instant) or Final (Icon Composer's real renders) for the suggestions or the
 *  canvas. Adjusting (or editing) goes back to Preview, so that stays quick. */
export function RenderModeSeg({ which }: { which: "suggestions" | "canvas" }) {
  const final = useDesign((s) => (which === "suggestions" ? s.finalSuggestions : s.glass));
  const set = (v: boolean) => useDesign.getState().set(which === "suggestions" ? { finalSuggestions: v } : { glass: v });
  return (
    <span className="seg" role="radiogroup" aria-label={which === "suggestions" ? "Suggestions shown as" : "Canvas shown as"}>
      <button role="radio" aria-checked={!final} className={!final ? "on" : ""} onClick={() => set(false)} title="The browser's quick sketch">Preview</button>
      <button role="radio" aria-checked={final} className={final ? "on" : ""} onClick={() => set(true)} title="Icon Composer's real Liquid Glass render (L)">Final</button>
    </span>
  );
}

/** The pictures (and parts) a suggestion is made from, read from its doc's image layers. (The engine's `uses`
 *  names roles, "subject" and "fill", rather than pictures.) */
function usesOf(s: Suggestion): string[] {
  const out: string[] = [];
  for (const g of s.doc.groups) for (const l of g.layers) {
    if (l.content.kind === "image") out.push(l.content.asset.replace(/@(x4|px4)$/, ""));
    if (l.mask?.kind === "image") out.push(l.mask.asset);
  }
  return [...new Set(out)].sort();
}

/** The bar over the whole bottom section: what the suggestions are, how they're drawn, and the chevron that
 *  expands the section (suggestions and "adjust all" together) into the gallery, or collapses it. */
export function SuggestionsBar({ expanded }: { expanded: boolean }) {
  const list = useDesign((s) => s.suggestions);
  const loading = useDesign((s) => s.suggLoading);
  const picked = useApp((s) => s.program?.media.filter((m) => m.picked).length ?? 0);
  const toggle = () => useDesign.getState().set({ galleryOpen: !expanded });
  return (
    <div className="sbar">
      <b>Suggestions</b>
      <span className="muted ellipsis">{list.length} from your {picked} picks · {expanded ? "grouped by the media they use" : "click one to edit a copy"}</span>
      {loading && <span className="spin" />}
      <span className="grow" />
      {expanded && <AppearanceSeg />}
      <RenderModeSeg which="suggestions" />
      <button className="btn small sbar-toggle" onClick={toggle} aria-expanded={expanded}
        title={expanded ? "Back to the workbench (G or Esc)" : "Show every suggestion, with “adjust all”, filling the window (G)"}>
        <span className={"chev" + (expanded ? " down" : "")} aria-hidden>⌃</span>{expanded ? "Collapse" : "Expand"}
      </button>
    </div>
  );
}
