// What we know about the selected picture, and where each fact came from: the source's own labels, or our
// analysis. A preview with its parts outlined; the picture's turn; its parts, each picked, kind, turn and edit
// of its own; then the facts.
import { useEffect, useState, type ReactNode } from "react";
import { api, type Media, type MediaKind, type Part, type Rotation } from "../../api";
import { useApp } from "../../state/app";
import { deletePart, pickPart, pickAll, rotateMedia, setMediaKind, setPartFields } from "../../parts/actions";
import { PartImg } from "../../parts/PartImage";
import { Lightbox } from "../../components/Lightbox";
import { bestFrameId, cutPartsOf, frameNo, framesOf, isPicked, isVideo, shownParts, timeOrder } from "../../parts/frames";
import { findFrameCutouts, frameCutoutsBusy, useFrameCutouts } from "../../parts/frameCutouts";
import { HiresBadge, KIND_LABELS, kindLabel, pickState, Suit } from "./MediaCard";

export const PART_COLOURS = ["var(--e1)", "var(--e2)", "var(--e3)", "var(--e4)"];
const SOURCE_WORDS: Record<string, string> = {
  whole: "The picture as it is", subject: "Vision's subject cut-out", instance: "One of the subjects Vision found", text: "Text matching the title",
  rectangle: "A rectangle, straightened", disc: "The disc's circle",
  frame: "A frame of the video", region: "A region you drew", sam: "Your clicks (SAM)",
};
const KINDS = Object.keys(KIND_LABELS).filter((k) => k !== "unknown") as MediaKind[];
const turn = (r: number, by: number) => (((r + by) % 360) + 360) % 360 as Rotation;

export type EditRequest = { m: Media; part: Part | null; tool: "region" | "add" }

export function MediaInspector({ m, all, onSelect, onEdit }: { m: Media | null; all: Media[]; onSelect(id: string): void; onEdit(r: EditRequest): void }) {
  const [lb, setLb] = useState<number | null>(null);
  useEffect(() => setLb(null), [m?.id]);
  const [outlines, setOutlines] = useState(() => { try { return localStorage.getItem("iconlab-outlines") !== "0"; } catch { return true; } });
  const running = useFrameCutouts((s) => s.running);
  if (!m) return <aside className="insp2"><div className="empty">Select a picture to see its parts and what's known about it.<br /><span className="faint">Arrows move, P picks, X unpicks.</span></div></aside>;
  const a = m.analysis, d = m.deep;
  // A video hides "whole" (its best frame stands for it); its frames are listed apart, in time order, and the
  // lightbox steps through the frames, then the cut-outs.
  const parts = shownParts(m);
  const video = isVideo(m);
  const best = bestFrameId(m);
  const frames = video ? framesOf(m) : [];
  const cutParts = video ? cutPartsOf(m) : parts.filter((p) => p.source !== "frame");
  const lbParts = video ? timeOrder(m) : parts;
  const ps = pickState(m);
  const nPicked = parts.filter((p) => isPicked(m, p)).length;
  const dupes = all.filter((x) => x.id !== m.id && (x.duplicateOf === m.id || (m.duplicateOf && (x.id === m.duplicateOf || x.duplicateOf === m.duplicateOf))));
  const derived = all.filter((x) => x.derivedFrom === m.id);
  const parent = m.derivedFrom ? all.find((x) => x.id === m.derivedFrom) : null;
  const r = m.remote;
  const busy = a.busyness;
  const slug = useApp.getState().program?.slug ?? "";
  const rot = m.rotation ?? 0;
  const fail = (e: unknown) => useApp.getState().say((e as Error).message, "error");

  return (
    <aside className="insp2">
      {lb != null && lbParts[lb] && <Lightbox index={lb} onIndex={setLb} onClose={() => setLb(null)}
        items={lbParts.map((p) => ({
          key: p.id, url: (m.partsLocal && p.id === "whole") || !p.image ? m.url : p.image,
          name: video && frameNo(m, p) != null ? `${p.name} · ${m.deep?.frames ?? frames.length} frames`
            : p.id === "whole" ? `${m.kind !== "unknown" ? kindLabel(m.kind) : m.name} · whole picture` : p.name,
          detail: `${p.size[0]}×${p.size[1]} px · ${m.source}`,
          pixelated: Math.max(p.size[0], p.size[1]) <= 256 || !!m.analysis.pixelArt,
          picked: isPicked(m, p), onTogglePick: () => void pickShown(m, p, !isPicked(m, p)).catch(fail),
          action: video && p.source === "frame" && p.id !== best ? frameAction(m, p, running) : undefined,
        }))} />}
      <div className="ph"><span className="wraps">{m.kind !== "unknown" ? kindLabel(m.kind) : m.name} <small>{m.source} · {m.width}×{m.height}</small></span>
        <span className="row" style={{ gap: 4 }}>
          <HiresBadge m={m} />
          <button className={"btn small" + (ps !== "none" ? " on" : "")} onClick={() => void pickAll(m, ps !== "all").catch(fail)}
            title={ps === "all" ? "Unpick every part" : "Pick every part"}>{ps === "all" ? "✓ All picked" : ps === "some" ? `◐ ${nPicked} of ${parts.length} picked` : "Pick"}</button>
        </span>
      </div>
      <div className="scroll">
        {m.hidden && <div className="insp-hidden"><span className="grow">Hidden: it's left out of the grid and never used in suggestions.</span><button className="btn small" onClick={() => void useApp.getState().setHidden(m.id, false)}>Unhide</button></div>}
        <Preview m={m} outlines={outlines} onOpen={() => setLb(Math.max(0, lbParts.findIndex((p) => p.id === (video ? best : "whole"))))} />
        <div className="rot">
          <span className="fl">Turn picture</span>
          <button className="icon-b" title="Turn left" aria-label="Turn left" onClick={() => void rotateMedia(m, turn(rot, -90)).catch(fail)}>⟲</button>
          <button className="icon-b" title="Turn right" aria-label="Turn right" onClick={() => void rotateMedia(m, turn(rot, 90)).catch(fail)}>⟳</button>
          <button className="btn small" onClick={() => void rotateMedia(m, turn(rot, 180)).catch(fail)}>Turn 180°</button>
          <button className="btn small" disabled={!rot} onClick={() => void rotateMedia(m, 0).catch(fail)}>Reset</button>
          {cutParts.filter((p) => p.id !== "whole" && !p.frame).length > 0 && <label className={"chip" + (outlines ? " on" : "")} style={{ marginLeft: "auto" }}><input type="checkbox" checked={outlines} onChange={(e) => { setOutlines(e.target.checked); try { localStorage.setItem("iconlab-outlines", e.target.checked ? "1" : "0"); } catch { /* fine */ } }} /> Show outlines of parts</label>}
        </div>
        {m.rotationWhy && <div className="autonote"><b>{m.rotationAuto ? `Picture: turned ${rot}° automatically.` : "Picture: left as it is."}</b> {m.rotationWhy}</div>}
        {parts.filter((p) => p.rotationWhy).map((p) => <div key={p.id} className="autonote"><b>{p.name}: {p.rotationAuto ? `turned ${p.rotation}° automatically.` : "not turned."}</b> {p.rotationWhy}</div>)}

        <div className="sec2">Parts
          <span className="row" style={{ gap: 4 }}>
            <button className="btn small" disabled={ps === "all"} onClick={() => void pickAll(m, true).catch(fail)}>Pick all</button>
            <button className="btn small" disabled={ps === "none"} onClick={() => void pickAll(m, false).catch(fail)}>None</button>
          </span>
        </div>
        <div className="els">
          {cutParts.map((p, i) => <PartRow key={p.id} onZoom={() => setLb(lbParts.indexOf(p))} m={m} p={p} colour={video ? (p.frame ? null : PART_COLOURS[i % 4]) : i === 0 ? null : PART_COLOURS[(i - 1) % 4]} onEdit={() => onEdit({ m, part: p, tool: p.prompt?.points?.length ? "add" : "region" })} fail={fail} />)}
          {frames.length > 0 && <div className="sec2 frames-h">Frames <span className="faint" style={{ textTransform: "none", letterSpacing: 0, fontWeight: 400 }}>{m.deep?.frames ?? frames.length} in the video</span></div>}
          {frames.map((p) => <PartRow key={p.id} onZoom={() => setLb(lbParts.indexOf(p))} m={m} p={p} colour={null} onEdit={() => {}} fail={fail} best={p.id === best} />)}
        </div>
        <div className="addrow">
          <button className="btn small" onClick={() => onEdit({ m, part: null, tool: "region" })}>＋ Draw a region</button>
          <button className="btn small" onClick={() => onEdit({ m, part: null, tool: "add" })}>＋ Click to select <span className="faint">(SAM)</span></button>
        </div>
        {m.partsLocal && <p className="faint local-note">Parts are kept by this page until the engine has them.</p>}

        <div className="sec2">About the picture</div>
        <dl className="facts2">
          <KindFact m={m} />
          <Fact label="Size" from={m.upgraded ? "A larger copy found online replaced it" : m.hires === "done" ? "No larger copy found" : m.hires === "failed" ? "Looking for a larger copy failed" : r?.width ? `The source lists ${r.width}×${r.height}${m.hires ? ` · hi-res copy ${m.hires}` : " · pick it to fetch the largest copy"}` : undefined}>
            {m.width}×{m.height} px{a.pixelArt && <span className="tag" style={{ marginLeft: 6 }}>pixel art</span>}
          </Fact>
          <Fact label="From" from={r?.license ? `Licence: ${r.license}` : undefined}>
            {m.provenance ? <Provenance chain={m.provenance} /> : <>{m.source}{r?.region && ` · ${r.region}`}</>}
            <SourceLink m={m} />
            {r?.title && <div className="faint">“{r.title}”</div>}
          </Fact>
          {m.relevance != null && (
            <Fact label="Relevance" from="A general search found it: half its words, half how it looks">
              <b>{m.relevance >= 0.65 ? "Likely" : m.relevance >= 0.4 ? "Maybe" : "Unlikely"}</b> <span className="muted">of this program · {Math.round(m.relevance * 100)}%</span>
              {m.relevanceWhy?.length ? <ul className="why">{m.relevanceWhy.map((w, i) => <li key={i}>{w}</li>)}</ul> : null}
            </Fact>
          )}
          {d?.roles?.length ? <Fact label="Found as" from="icon-extract: what the image is in the program">{d.roles.join(", ")}</Fact> : null}
          <Fact label="Suitability" from={"How likely it is to help make an icon: these added up, kept within 0 to 5"
            + (m.suitabilityFactors?.some((f) => f.details?.length) ? ". Half is from how it looks, half from how likely it's the program's own icon, so the rest count half." : "")}>
            <Suit n={m.suitability} /> <span className="muted">{m.suitability.toFixed(1)} of 5</span>
            {m.suitabilityFactors?.length ? (
              <ul className="factors">
                {m.suitabilityFactors.map((f, i) => (
                  <li key={i}>
                    {f.details?.length
                      ? <details><summary><Points n={f.points} />{f.label}</summary>{f.details.map((r, j) => <div key={j}>{r}</div>)}</details>
                      : <><Points n={f.points} />{f.label}</>}
                  </li>
                ))}
              </ul>
            ) : null}
          </Fact>
          {d?.foundIn && d.foundIn.length > 1 && <Fact label="Also in" from="The same picture, found in other places">{d.foundIn.slice(1, 6).map((p, i) => <div key={i}><Provenance chain={p} /></div>)}{d.foundIn.length > 6 && <div className="faint">and {d.foundIn.length - 6} more</div>}</Fact>}
          {parent && <Fact label="Made from" from="Our deep analysis"><a href="#" onClick={(e) => { e.preventDefault(); onSelect(parent.id); }}>{kindLabel(parent.kind)} · {parent.width}×{parent.height}</a></Fact>}
          <Fact label="Text" from={a.text.length ? `On-device text recognition · covers ${Math.round(a.textFraction * 100)}%` : undefined}>
            {a.text.length ? <span className="clamp">{a.text.slice(0, 8).map((t) => `“${t}”`).join(", ")}{a.text.length > 8 && ` and ${a.text.length - 8} more`}</span> : <span className="faint">None found</span>}
          </Fact>
          <Fact label="Subject" from="Vision's subject mask">{a.subject ? <>Found{a.subjectBox && `, ${Math.round(a.subjectBox[2] * a.subjectBox[3] * 100)}% of the picture`}{m.cutout && " · cut-out ready"}</> : <span className="faint">No clear subject</span>}</Fact>
          <Fact label="Flat sides" from="Our analysis: an edge the picture's subject is cut straight along">{a.flatSides.length ? a.flatSides.join(", ") : <span className="faint">None</span>}</Fact>
          <Fact label="Busyness"><span className="bar inline"><i style={{ width: `${busy * 100}%` }} /></span> <span className="muted">{busy > 0.6 ? "busy" : busy > 0.35 ? "moderate" : "simple"}</span></Fact>
          {(a.palette.length > 0 || d?.paletteRoles) && (
            <Fact label="Colours" from={d?.accentContrast ? `Accent on background: contrast ${d.accentContrast.toFixed(1)}:1` : undefined}>
              <span className="pal">{(a.palette.length ? a.palette : Object.values(d?.paletteRoles ?? {})).slice(0, 8).map((c, i) => <i key={i} style={{ background: c }} title={c} />)}</span>
              {d?.paletteRoles && <div className="roles">{Object.entries(d.paletteRoles).map(([k, c]) => <span key={k}><i style={{ background: c }} />{k}</span>)}</div>}
            </Fact>
          )}
          {d?.aesthetics != null && <Fact label="Aesthetics" from="Vision's aesthetics score (deep tier)">{d.aesthetics.toFixed(2)} <span className="muted">· {d.utility ? "a utility picture (a scan or screenshot)" : "not a utility picture"}</span></Fact>}
          {d?.legibility != null && <Fact label="Small sizes" from="How well the cut-out reads at 32 and 16 px">{Math.round(d.legibility * 100)}% <span className="muted">legible</span></Fact>}
          {d?.faces != null && d.faces > 0 && <Fact label="Faces">{d.faces}</Fact>}
          {d?.trim && <Fact label="Border" from="A plain border the deep tier can trim">{d.trim[2]}×{d.trim[3]} inside</Fact>}
          {dupes.length > 0 && (
            <Fact label="Same art" from="Matched by perceptual hash and feature print">
              {dupes.map((x) => <div key={x.id}><a href="#" onClick={(e) => { e.preventDefault(); onSelect(x.id); }}>{x.source} · {x.width}×{x.height}</a>{x.id === m.duplicateOf && " (best copy)"}</div>)}
            </Fact>
          )}
          {derived.length > 0 && <Fact label="Derived" from="Made from this by the deep analysis">{derived.map((x) => <div key={x.id}><a href="#" onClick={(e) => { e.preventDefault(); onSelect(x.id); }}>{kindLabel(x.kind)} · {x.width}×{x.height}</a></div>)}</Fact>}
        </dl>
        <div className="row insp-actions">
          {m.picked && <button className="btn small" onClick={() => void api.deepen(slug, m.id).catch(fail)}>Analyse again</button>}
          <a className="btn small" href={m.url} target="_blank" rel="noreferrer">Open image ↗</a>
        </div>
      </div>
    </aside>
  );
}

/** The picture, turned, with its parts' boxes outlined in their colours. */
function Preview({ m, outlines, onOpen }: { m: Media; outlines: boolean; onOpen(): void }) {
  const rot = m.rotation ?? 0;
  const side = rot === 90 || rot === 270;
  const W = m.width, H = m.height;
  const maxW = 300, maxH = 270;
  const k = Math.min(maxW / (side ? H : W), maxH / (side ? W : H), Math.max(W, H) <= 128 ? 8 : 4);
  const w = W * k, h = H * k;
  // Only the cut-outs from the picture shown: a video's other frames' cut-outs are boxes in another picture.
  const parts = (m.parts ?? []).filter((p) => p.id !== "whole" && p.source !== "frame" && !p.frame);
  return (
    <div className="pv2 checker" onClick={onOpen} title="Click to see it large" style={{ cursor: "zoom-in" }}>
      <div className="pvin" style={{ width: w, height: h, transform: `rotate(${rot}deg)` }}>
        <img key={m.id} src={m.url} alt="" draggable={false} style={{ width: w, height: h, ...(Math.max(W, H) <= 256 || m.analysis.pixelArt ? { imageRendering: "pixelated" } : {}) }}
          onError={(e) => { const img = e.target as HTMLImageElement; if (!img.src.endsWith(m.thumb)) img.src = m.thumb; }} />
        {outlines && parts.map((p, i) => (
          <div key={p.id} className="ebox" style={{ left: p.box[0] * w, top: p.box[1] * h, width: p.box[2] * w, height: p.box[3] * h, borderColor: PART_COLOURS[i % 4] }}>
            <span style={{ background: PART_COLOURS[i % 4], transform: `rotate(${-rot}deg)`, transformOrigin: "0 100%" }}>{p.name}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Pick a shown part. A video's best frame stands for its whole: picking it picks the frame, and unpicking it
 * unpicks an old pick of the whole too. */
async function pickShown(m: Media, p: Part, v: boolean) {
  await pickPart(m, p, v);
  const whole = m.parts?.find((x) => x.id === "whole");
  if (!v && p.id === bestFrameId(m) && whole?.picked) await pickPart(useApp.getState().media.get(m.id) ?? m, whole, false);
}

/** "Find cut-outs" / "Find again" on a frame other than the best. */
function frameAction(m: Media, p: Part, running: Record<string, unknown>) {
  const busy = frameCutoutsBusy({ running } as never, m.id, p.id);
  const again = (m.parts ?? []).some((x) => x.frame === p.id);
  return { label: busy ? "Finding cut-outs…" : again ? "Find again" : "Find cut-outs", busy, onClick: () => void findFrameCutouts(m, p.id),
    title: again ? "Find this frame's subject and things again; your picks of them are kept" : "Find the subject and things in this frame, as cut-outs" };
}

function PartRow({ m, p, colour, onEdit, onZoom, fail, best }: { m: Media; p: Part; colour: string | null; onEdit(): void; onZoom(): void; fail(e: unknown): void; best?: boolean }) {
  const whole = p.id === "whole";
  const picked = isPicked(m, p);
  const running = useFrameCutouts((s) => s.running);
  const fn = p.frame ? Number(p.frame.replace(/^frame-/, "")) : null;
  const kindValue = whole ? m.kind : p.kind;
  const setKind = (k: string) => (whole ? setMediaKind(m, k as MediaKind) : setPartFields(m, p, { kind: k as MediaKind })).catch(fail);
  return (
    <div className={"el" + (picked ? " on" : "")}>
      <input type="checkbox" checked={picked} onChange={(e) => void pickShown(m, p, e.target.checked).catch(fail)} aria-label={`Pick ${p.name}`} />
      <span className="sw" style={colour ? { background: colour } : undefined} />
      <button className="th checker zoomable" onClick={onZoom} aria-label={`See ${p.name} large`} title="See it large">
        <PartImg m={m} p={p} max={160} />
        <span className="zoom" aria-hidden><svg viewBox="0 0 16 16" width="18" height="18"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.8" /><path d="M10.5 10.5 14 14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" /></svg></span>
      </button>
      <span className="el-body">
        <span className="nm wraps" title={p.name}>{p.name}{fn != null && <span className="tag">frame {fn}</span>}</span>
        {best && <span className="psrc faint">Cut-outs come from this frame</span>}
        <span className="psrc">{SOURCE_WORDS[p.source] ?? p.source} · {p.size[0]}×{p.size[1]}{p.rotation ? <> · <b>turned {p.rotation}°</b>{p.rotationAuto ? " automatically" : ""}</> : null}</span>
        <select className="text" value={kindValue} onChange={(e) => void setKind(e.target.value)} aria-label={`Kind of ${p.name}`}>
          <option value="unknown">{whole ? "No kind" : "None"}</option>
          {KINDS.map((k) => <option key={k} value={k}>{kindLabel(k)}</option>)}
          {!KINDS.includes(kindValue as MediaKind) && kindValue !== "unknown" && <option value={kindValue}>{kindLabel(kindValue)}</option>}
        </select>
      </span>
      <span className="acts">
        {!whole && <button className="icon-b" title="Turn left" aria-label="Turn part left" onClick={() => void setPartFields(m, p, { rotation: turn(p.rotation, -90) }).catch(fail)}>⟲</button>}
        {!whole && <button className="icon-b" title="Turn right" aria-label="Turn part right" onClick={() => void setPartFields(m, p, { rotation: turn(p.rotation, 90) }).catch(fail)}>⟳</button>}
        {p.source === "frame" && !best && (() => { const a = frameAction(m, p, running); return <button className="btn small" disabled={a.busy} title={a.title} onClick={a.onClick}>{a.busy && <span className="spin" />} {a.busy ? "Finding…" : a.label}</button>; })()}
        {!whole && p.source !== "frame" && (p.frame
          ? <button className="btn small" disabled title="Cut-outs from other frames can't be edited yet">Edit</button>
          : <button className="btn small" onClick={onEdit}>Edit</button>)}
        {!whole && <button className="icon-b" title="Remove this part" aria-label="Remove part" onClick={() => void deletePart(m, p).catch(fail)}>✕</button>}
      </span>
    </div>
  );
}

/** Where the picture came from: its page, a search at its source, or the source's home page. Your files have none. */
function SourceLink({ m }: { m: Media }) {
  const l = m.link ?? ((m.remote?.pageUrl || m.sourceUrl) ? { url: (m.remote?.pageUrl || m.sourceUrl)!, kind: "page" as const, label: m.source } : null);
  if (!l) return null;
  const text = l.kind === "page" ? `View on ${l.label} ↗` : l.kind === "search" ? `Search ${l.label} ↗` : `${l.label} ↗`;
  return <div className="src-link"><a href={l.url} target="_blank" rel="noreferrer" title={l.url}>{text}</a></div>;
}

/** The kind, or "none yet" with MobileCLIP's best guesses and what the source called it. */
function KindFact({ m }: { m: Media }) {
  const fail = (e: unknown) => useApp.getState().say((e as Error).message, "error");
  const label = m.sourceLabel ?? m.remote?.sourceLabel;
  const guesses = m.kindGuesses ?? [];
  if (m.kind !== "unknown") {
    const from = m.kindSource === "you" ? "You chose it" : m.kindSource === "source" ? `${m.source} calls it “${label ?? kindLabel(m.kind)}”` : `MobileCLIP · ${Math.round(m.kindConfidence * 100)}% sure${label ? `; ${m.source} calls it “${label}”` : ""}`;
    return <Fact label="Kind" from={from}>{kindLabel(m.kind)}{m.kindSource !== "you" && m.kindConfidence ? <span className="muted"> · {Math.round(m.kindConfidence * 100)}% sure</span> : null}</Fact>;
  }
  return (
    <Fact label="Kind" from={label ? `${m.source} calls it “${label}”${guesses.length ? "; MobileCLIP isn't sure enough" : ""}` : guesses.length ? "MobileCLIP isn't sure enough to choose" : undefined}>
      <span className="muted">None yet</span>{" "}
      <select className="text" value="" onChange={(e) => e.target.value && void setMediaKind(m, e.target.value as MediaKind).catch(fail)}>
        <option value="">Choose…</option>
        {KINDS.map((k) => <option key={k} value={k}>{kindLabel(k)}</option>)}
      </select>
      {guesses.length > 0 && <div className="guesses">{guesses.slice(0, 3).map((g) => (
        <div key={g.kind} className="guess"><span>{kindLabel(g.kind)}</span><span className="gbar"><i style={{ width: `${Math.round(g.p * 100)}%` }} /></span><span className="muted">{Math.round(g.p * 100)}%</span></div>
      ))}</div>}
    </Fact>
  );
}

/** A factor's points, signed: "+1.2", "−0.4", "0". */
function Points({ n }: { n: number }) {
  const r = Math.round(n * 100) / 100;
  return <span className={"pts" + (r > 0 ? " up" : r < 0 ? " down" : "")}>{r > 0 ? "+" : r < 0 ? "−" : ""}{Math.abs(r)}</span>;
}

function Fact({ label, from, children }: { label: string; from?: string; children: ReactNode }) {
  return <div className="fact"><dt>{label}</dt><dd>{children}{from && <div className="from">{from}</div>}</dd></div>;
}

function Provenance({ chain }: { chain: string }) {
  const parts = chain.split("›").map((s) => s.trim());
  return <span className="prov">{parts.map((p, i) => <span key={i}>{i > 0 && <span className="faint"> › </span>}<span className="mono">{p}</span></span>)}</span>;
}
