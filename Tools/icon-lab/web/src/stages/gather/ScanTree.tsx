// A scan's unpacking, drawn as a tree in its job in the activity panel as icon-extract's lines arrive: each container opened, what it was
// found to be, the images in it, and what was skipped and why.
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useScans, type Scan, type ScanNode } from "../../state/scans";
import type { Job } from "../../api";

const MAX_CHILDREN = 120;
const KIND_WORDS: Record<string, string> = { volume: "volume", resource: "resource", fork: "resource fork", overlay: "appended data", carved: "found by signature", frame: "video frame", entry: "" };

/** A scan's tree, inside its job in the activity panel: what was opened, the images found in each, what was skipped,
 *  and how it ended. Follows the newest line while scrolled to the bottom. */
export function ScanTreeBody({ scanId, job }: { scanId: string; job?: Job }) {
  const sc = useScans((s) => s.scans[scanId]);
  const box = useRef<HTMLDivElement>(null);
  const [follow, setFollow] = useState(true);
  useEffect(() => { if (follow && box.current) box.current.scrollTop = box.current.scrollHeight; });
  const counts = useMemo(() => (sc ? countImages(sc) : new Map<number, { all: number; fresh: number }>()), [sc]);
  const failed = job?.state === "failed" || !!sc?.error;
  const p = sc?.progress;
  return (
    <div className="tree scan-tree" ref={box} onScroll={(e) => { const el = e.currentTarget; setFollow(el.scrollHeight - el.scrollTop - el.clientHeight < 30); }}>
      {!sc || !sc.roots.length ? <div className="faint">{failed ? "" : job && job.state !== "running" && job.state !== "queued" ? "This scan's details are from before the page opened." : "Starting…"}</div>
        : sc.roots.map((r, i) => <NodeLines key={r} sc={sc} id={r} prefix="" last={i === sc.roots.length - 1} root counts={counts} />)}
      {sc && sc.looseSkips.length > 0 && <Skipped skips={sc.looseSkips} prefix="" />}
      {(sc?.error || job?.state === "failed") && <div className="tl"><span className="warn">! {sc?.error ?? job?.detail ?? "The scan failed."}</span></div>}
      {sc?.done && <div className="tl summary">{sc.done.images} images in {sc.done.families} families found in {sc.done.nodes} items · {sc.done.skipped} skipped{job && job.state !== "done" && !failed ? " · adding them…" : job?.detail ? ` · ${job.detail}` : ""}</div>}
      {!sc?.done && p && <div className="tl summary">{p.images} images so far · {p.nodes} items opened · {p.queued} still to open</div>}
    </div>
  );
}

function countImages(sc: Scan) {
  const out = new Map<number, { all: number; fresh: number }>();
  const visit = (id: number): { all: number; fresh: number } => {
    const n = sc.nodes[id];
    if (!n) return { all: 0, fresh: 0 };
    let all = n.images, fresh = n.newImages;
    for (const c of n.children) { const r = visit(c); all += r.all; fresh += r.fresh; }
    const r = { all, fresh };
    out.set(id, r);
    return r;
  };
  sc.roots.forEach(visit);
  return out;
}

function NodeLines({ sc, id, prefix, last, root, counts }: { sc: Scan; id: number; prefix: string; last: boolean; root?: boolean; counts: Map<number, { all: number; fresh: number }> }) {
  const n = sc.nodes[id];
  if (!n) return null;
  const running = !sc.done && isActive(sc, id);
  const c = counts.get(id) ?? { all: 0, fresh: 0 };
  const branch = root ? "" : last ? "└─ " : "├─ ";
  const childPrefix = root ? "" : prefix + (last ? "   " : "│  ");
  const kids = n.children.slice(0, MAX_CHILDREN);
  const more = n.children.length - kids.length;
  const items: ReactNode[] = [];
  const total = kids.length + (more > 0 ? 1 : 0) + (n.skips.length ? 1 : 0);
  let k = 0;
  const isLast = () => ++k === total;
  for (const child of kids) items.push(<NodeLines key={child} sc={sc} id={child} prefix={childPrefix} last={isLast()} counts={counts} />);
  if (more > 0) items.push(<div key="more" className="tl"><span className="pre">{childPrefix}{isLast() ? "└─ " : "├─ "}</span><span className="skip">… {more} more</span></div>);
  if (n.skips.length) items.push(<Skipped key="skips" skips={n.skips} prefix={childPrefix + (isLast() ? "└─ " : "├─ ")} />);
  return (
    <>
      <div className="tl">
        <span className="pre">{prefix}{branch}</span>
        {running ? <span className="run">◐</span> : <span className="ok">✓</span>}{" "}
        <span className={root || n.children.length ? "b" : ""} title={n.display}>{n.name}</span>{" "}
        <span className="k">{[KIND_WORDS[n.kind] ?? (n.kind === "unknown" || n.kind === "directory" || n.kind === "file" ? "" : n.kind), displayOf(n), n.installer && !n.display.includes(n.installer) ? n.installer : "", n.macType && `‘${n.macType}’`].filter(Boolean).join(" · ")}</span>
        {c.all > 0 && <span className="imgs"> {c.all} image{c.all === 1 ? "" : "s"}{c.fresh !== c.all ? ` (${c.fresh} new)` : ""}</span>}
      </div>
      {items}
    </>
  );
}

/** The node being worked on now, and its ancestors. */
function isActive(sc: Scan, id: number): boolean {
  let cur: number | undefined = sc.lastNode ?? undefined;
  while (cur != null) { if (cur === id) return true; cur = sc.nodes[cur]?.parent; }
  return false;
}

export type { ScanNode };

/** What a node was found to be, without its own name repeated. */
function displayOf(n: ScanNode) {
  let d = n.display.trim();
  // icon-extract's display is the node's whole chain ("disc.iso › SETUP.EXE › …"): that's the tooltip.
  if (d.includes("›")) return "";
  if (d === n.name) return "";
  if (d.startsWith(n.name)) d = d.slice(n.name.length).replace(/^\s*[·:›-]\s*/, "");
  return d;
}

const short = (chain: string) => chain.split("›").pop()!.trim();

/** What was skipped at a node, as one line by reason ("text ×6, Wine's own ×8"), opening to the list. */
function Skipped({ skips, prefix }: { skips: { name: string; reason: string }[]; prefix: string }) {
  const [open, setOpen] = useState(false);
  const by = new Map<string, number>();
  for (const s of skips) by.set(s.reason, (by.get(s.reason) ?? 0) + 1);
  const summary = [...by.entries()].sort((a, b) => b[1] - a[1]).map(([r, n]) => (n > 1 ? `${r} ×${n}` : r)).join(", ");
  return (
    <>
      <div className="tl clickable" onClick={() => setOpen(!open)} title={open ? "Hide the list" : "Show what was skipped"}>
        <span className="pre">{prefix}</span><span className="skip">{open ? "▾" : "▸"} {skips.length} skipped: {summary}</span>
      </div>
      {open && skips.map((s, i) => <div key={i} className="tl"><span className="pre">{prefix.replace(/[├└]─ $/, "   ").replace(/├/g, "│")}   </span><span className="skip">· {short(s.name)} ({s.reason})</span></div>)}
    </>
  );
}
