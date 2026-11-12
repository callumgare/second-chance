// The gather stage's sources: every place images come from (your files first), with what each is doing now
// (a spinner while its gather job runs), how many images it gave, or why it gave none (needs a key, link only,
// nothing found, failed). Clicking one filters the grid to it; "Gather again" re-runs POST …/gather; each source's
// ↻ clears it and gathers again, and its × clears it alone.
import { allLayersAndMasks } from "../../lib/doc";
import { useEffect, useMemo } from "react";
import { api, type Job, type Media, type SourceInfo } from "../../api";
import { useApp } from "../../state/app";
import { useJobs } from "../../state/jobs";
import { useSearch } from "../../state/search";
import { useDesign } from "../../state/design";

const YOUR_FILES = "Your files";

type Row = {
  key: string; name: string; filter: string                // the Source filter's value (media.source)
  state: "running" | "queued" | "done" | "failed" | "needsKey" | "linkOnly" | "disabled" | "idle"
  count: number; note?: string; local?: boolean; homepage?: string
}

/** The source a gather job is for: "Gather · LaunchBox" → "LaunchBox". */
const jobSource = (j: Job) => j.source ?? j.title.replace(/^Gather\s*·\s*/, "").trim();

export function SourcesPanel({ slug, media, selected, onSelect, collapsed, onToggle }: {
  slug: string; media: Media[]; selected: string; onSelect(source: string): void; collapsed: boolean; onToggle(): void
}) {
  const sources = useSearch((s) => s.sources);
  const jobs = useJobs((s) => s.jobs);
  useEffect(() => { if (!sources) void useSearch.getState().loadSources(); }, [sources]);

  const rows = useMemo(() => build(slug, sources ?? [], [...jobs.values()], media), [slug, sources, jobs, media]);
  const running = rows.filter((r) => r.state === "running" || r.state === "queued").length;
  const gatherAgain = () => api.gather(slug)
    .then(() => useApp.getState().say("Gathering again: new pictures will appear as they're found"))
    .catch((e) => useApp.getState().say("Couldn't start gathering: " + (e as Error).message, "error"));

  if (collapsed) {
    return (
      <aside className="srcpanel collapsed">
        <button className="rail" onClick={onToggle} title="Show sources" aria-expanded={false}>
          {running ? <span className="spin" /> : <span>▸</span>}
          <span className="rail-label">Sources{running ? ` · ${running}` : ""}</span>
        </button>
      </aside>
    );
  }
  const main = rows.filter((r) => r.state !== "needsKey" && r.state !== "linkOnly" && r.state !== "disabled");
  const unusable = rows.filter((r) => !main.includes(r));
  return (
    <aside className="srcpanel">
      <div className="ph">
        <span>Sources</span>
        <span className="row" style={{ gap: 2 }}>
          <button className="btn small ghost" onClick={() => void gatherAgain()} disabled={running > 0} title="Look in every source again; only new pictures are added">
            {running ? <><span className="spin" /> {running} gathering</> : "↻ Gather again"}
          </button>
          <button className="icon-btn" onClick={onToggle} title="Hide sources" aria-label="Hide sources" aria-expanded>◂</button>
        </span>
      </div>
      <div className="scroll">
        <div className="srclist">
          <SourceRow r={{ key: "all", name: "All sources", filter: "all", state: "done", count: media.length }} on={selected === "all"} onSelect={onSelect} />
          {main.map((r) => <SourceRow key={r.key} r={r} on={selected === r.filter} onSelect={onSelect}
            onRegather={r.key.startsWith("x-") ? undefined : () => regather(slug, r, media)}
            onClear={r.key.startsWith("x-") || r.count === 0 ? undefined : () => clear(slug, r, media)} />)}
          {unusable.length > 0 && <div className="srcsec">Not searched</div>}
          {unusable.map((r) => <SourceRow key={r.key} r={r} on={false} onSelect={() => {}} />)}
        </div>
      </div>
    </aside>
  );
}

function SourceRow({ r, on, onSelect, onRegather, onClear }: { r: Row; on: boolean; onSelect(s: string): void; onRegather?(): void; onClear?(): void }) {
  const clickable = r.count > 0 || r.key === "all";
  const status = r.state === "running" ? "" : r.state === "queued" ? "waiting" : r.state === "failed" ? "failed"
    : r.state === "needsKey" ? "needs a key" : r.state === "linkOnly" ? "link only" : r.state === "disabled" ? "off"
    : r.count === 0 ? (r.state === "done" ? "nothing found" : "") : "";
  return (
    <div className="srcwrap">
    <button className={"src" + (on ? " on" : "") + (r.count === 0 && r.key !== "all" ? " zero" : "")} disabled={!clickable}
      onClick={() => onSelect(on ? "all" : r.filter)} title={[r.note, clickable ? "Click to show only its pictures" : ""].filter(Boolean).join("\n")}>
      {r.state === "running" ? <span className="spin" /> : <span className={"dot " + (r.state === "failed" ? "bad" : r.state === "needsKey" ? "warn" : r.count > 0 || r.key === "all" ? "" : "off")} />}
      <span className="src-name wraps">
        <span>{r.name}</span>
        {r.local && <span className="tag">local</span>}
        {status && <span className={"st" + (r.state === "failed" ? " bad" : r.state === "needsKey" ? "" : " quiet")}>{status}</span>}
        {r.note && r.state === "failed" && <small className="faint">{r.note}</small>}
      </span>
      <span className="n">{r.state === "needsKey" || r.state === "linkOnly" || r.state === "disabled" ? "–" : r.count}</span>
    </button>
    {r.state !== "running" && r.state !== "queued" && (onRegather || onClear) && (
      <span className="src-acts">
        {onClear && <button className="src-regather" onClick={onClear} aria-label={`Clear the pictures from ${r.name}`} title="Clear its pictures">×</button>}
        {onRegather && <button className="src-regather" onClick={onRegather} aria-label={`Clear and gather again from ${r.name}`} title="Clear and gather again">↻</button>}
      </span>
    )}
    </div>
  );
}

/** What clearing a source would lose: its pictures, the picks among them, and those the open design uses. */
function losses(slug: string, r: Row, media: Media[]) {
  const files = r.key === "yours";
  const mine = files ? media.filter((m) => m.source === YOUR_FILES) : media.filter((m) => m.remote?.source === r.key || m.source === r.name);
  const picks = mine.filter((m) => m.picked || m.parts?.some((p) => p.picked)).length;
  const design = useDesign.getState();
  const used = new Set<string>();
  if (design.slug === slug && design.doc) {
    for (const l of allLayersAndMasks(design.doc)) {
      if (l.content.kind === "image") {
        used.add(l.content.asset.split("/")[0].replace(/@(x4|px4)$/, ""));
        for (const e of l.content.effects) if (e.op === "mask" && e.mask.kind === "image") used.add(e.mask.asset.split("/")[0]);
      }
      if (l.mask?.kind === "image") used.add(l.mask.asset.split("/")[0]);
    }
  }
  const inDesign = mine.filter((m) => used.has(m.id)).length;
  return { files, mine, picks, inDesign };
}

/** Clears a source's pictures without gathering again, asking first when that would lose picks or pictures the open
 *  design uses. */
async function clear(slug: string, r: Row, media: Media[]) {
  const { files, mine, picks, inDesign } = losses(slug, r, media);
  if (picks || inDesign) {
    const lines = [`Clear the ${mine.length} pictures from ${r.name}?`];
    if (picks) lines.push(`Your picks from it (${picks}) will be lost.`);
    if (inDesign) lines.push(`The design you're working on uses ${inDesign === 1 ? "one of them" : `${inDesign} of them`}.`);
    if (files) lines.push("They come back only by adding them again.");
    if (!window.confirm(lines.join(" "))) return;
  }
  try {
    const { removed } = await api.clearSources(slug, [files ? "files" : r.key]);
    useApp.getState().say(`Cleared ${removed} ${removed === 1 ? "picture" : "pictures"} from ${r.name}`);
  } catch (e) { useApp.getState().say(`Couldn't clear ${r.name}: ${(e as Error).message}`, "error"); }
}

/** Clears a source's pictures and gathers from it again, asking first when that would lose picks or pictures the
 *  open design uses. */
async function regather(slug: string, r: Row, media: Media[]) {
  const { files, mine, picks, inDesign } = losses(slug, r, media);
  // Your files are scanned again from the paths scanned before; pictures added before those were remembered don't come back.
  let scans: { path: string }[] = [];
  if (files) {
    try { scans = await api.scans(slug); } catch (e) { useApp.getState().say("Couldn't read the scans: " + (e as Error).message, "error"); return; }
  }
  const names = [...new Set(scans.map((s) => s.path.replace(/\/+$/, "").split("/").pop() || s.path))];
  const nameList = names.length <= 3 ? names.join(", ") : `${names.slice(0, 3).join(", ")} and ${names.length - 3} more`;
  if (files && !scans.length) {
    const lines = [`Clear the ${mine.length} pictures from your files? Icon Lab doesn't know where they were added from, so they won't come back by themselves — add them again with Add from files.`];
    if (picks) lines.push(`Your picks from them (${picks}) will be lost.`);
    if (inDesign) lines.push(`The design you're working on uses ${inDesign === 1 ? "one of them" : `${inDesign} of them`}.`);
    if (!window.confirm(lines.join(" "))) return;
  } else if (files || picks || inDesign) {
    const lines = [files ? `Clear the ${mine.length} pictures from your files and scan ${nameList} again?` : `Clear the ${mine.length} pictures from ${r.name} and gather again?`];
    const dropped = files ? mine.filter((m) => m.deep?.byHand === true).length : 0;
    if (dropped) lines.push(`The ${dropped === 1 ? "picture" : `${dropped} pictures`} you dropped in won't come back by themselves.`);
    if (picks) lines.push(`Your picks from it (${picks}) will be lost.`);
    if (inDesign) lines.push(`The design you're working on uses ${inDesign === 1 ? "one of them" : `${inDesign} of them`}.`);
    if (!window.confirm(lines.join(" "))) return;
  }
  try {
    await api.gather(slug, { sources: [files ? "files" : r.key], clear: true });
    useApp.getState().say(files ? (scans.length ? `Scanning ${nameList} again` : "Cleared your files") : `Gathering again from ${r.name}`);
  } catch (e) { useApp.getState().say(`Couldn't gather from ${r.name}: ${(e as Error).message}`, "error"); }
}

function build(slug: string, sources: SourceInfo[], jobs: Job[], media: Media[]): Row[] {
  const mine = jobs.filter((j) => j.program === slug);
  const gatherJobs = mine.filter((j) => j.group === "gather");
  const scanJobs = mine.filter((j) => j.group === "scan");
  // The latest gather job per source name.
  const latest = new Map<string, Job>();
  for (const j of gatherJobs) latest.set(jobSource(j).toLowerCase(), j);
  const countBy = (s: SourceInfo) => media.filter((m) => m.remote?.source === s.id || m.source === s.name).length;

  const rows: Row[] = [];
  const scanJob = scanJobs[scanJobs.length - 1];
  rows.push({
    key: "yours", name: YOUR_FILES, filter: YOUR_FILES, count: media.filter((m) => m.source === YOUR_FILES).length,
    state: scanJob ? (scanJob.state === "done" ? "done" : scanJob.state) : "idle",
    note: scanJob?.state === "failed" ? scanJob.detail : "Scans of a game's app, disc image, installer or folder",
  });
  for (const s of sources) {
    const j = latest.get(s.id.toLowerCase()) ?? latest.get(s.name.toLowerCase());
    const count = countBy(s);
    // Only sources that give pictures: those that gathered for this program, or gave it pictures, or would if
    // they could (a key, link only). Program-only sources (Wikidata…) never have either.
    if (s.media === false || (s.media === undefined && !j && count === 0 && s.state === "ready")) continue;
    const state: Row["state"] = s.state === "needsKey" || s.state === "linkOnly" || s.state === "disabled" ? s.state : j ? j.state : "done";
    const filter = media.find((m) => m.remote?.source === s.id)?.source ?? s.name;
    rows.push({ key: s.id, name: s.name, filter, count, state, local: s.local, homepage: s.homepage, note: j?.state === "failed" ? j.detail ?? "The search failed" : s.note });
  }
  // Media from sources the list doesn't name (older data): still countable and filterable.
  const named = new Set(rows.map((r) => r.filter));
  for (const name of new Set(media.map((m) => m.source))) {
    if (!named.has(name)) rows.push({ key: "x-" + name, name, filter: name, count: media.filter((m) => m.source === name).length, state: "done" });
  }
  const order = (r: Row) => (r.key === "yours" ? 0 : r.state === "running" ? 1 : r.state === "queued" ? 2 : r.count > 0 ? 3 : r.state === "failed" ? 4 : 5);
  return rows.sort((a, b) => order(a) - order(b) || b.count - a.count);
}
