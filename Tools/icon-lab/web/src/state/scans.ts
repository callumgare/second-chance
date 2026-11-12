// "Add from files" scans: icon-extract's lines (`scan` events) gathered into a tree per scan, to draw live.
import { create } from "zustand";
import type { ScanLine } from "../api";

export type ScanNode = {
  id: number; parent?: number; name: string; kind: string; size: number; display: string; installer?: string; macType?: string
  children: number[]
  images: number      // images decoded here (not below)
  newImages: number   // of those, new (not a duplicate of one found elsewhere)
  skips: { name: string; reason: string }[]
}

export type Scan = {
  id: string; program: string; path?: string
  nodes: Record<number, ScanNode>; roots: number[]
  progress: { nodes: number; images: number; queued: number; bytesExtracted: number } | null
  done: Extract<ScanLine, { event: "done" }> | null
  error: string | null
  lastNode: number | null
  started: number
  looseSkips: { name: string; reason: string }[]
}

type ScansState = {
  scans: Record<string, Scan>
  /** Scans whose tree is open in the activity panel (one just started opens itself). */
  open: Record<string, boolean>
  setOpen(id: string, open: boolean): void
  start(id: string, program: string, path: string): void
  fail(id: string, error: string): void
}

export const useScans = create<ScansState>((set) => ({
  scans: {},
  open: {},
  setOpen(id, open) { set((s) => ({ open: { ...s.open, [id]: open } })); },
  start(id, program, path) {
    set((s) => ({ scans: { ...s.scans, [id]: { ...(s.scans[id] ?? blank(id, program)), path } }, open: { ...s.open, [id]: true } }));
  },
  fail(id, error) {
    set((s) => (s.scans[id] ? { scans: { ...s.scans, [id]: { ...s.scans[id], error } } } : s));
  },
}));

function blank(id: string, program: string): Scan {
  return { id, program, nodes: {}, roots: [], progress: null, done: null, error: null, lastNode: null, started: Date.now(), looseSkips: [] };
}

// Lines arrive faster than is worth re-rendering for: apply them in batches, once a frame.
const pending: { program: string; scan: string; line: ScanLine }[] = [];
let scheduled = false;

export function applyScanLine(program: string, scan: string, line: ScanLine) {
  pending.push({ program, scan, line });
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(flush);
}

function flush() {
  scheduled = false;
  const batch = pending.splice(0);
  useScans.setState((s) => {
    const scans = { ...s.scans };
    for (const { program, scan, line } of batch) {
      const cur = scans[scan] ?? blank(scan, program);
      const sc: Scan = { ...cur, nodes: { ...cur.nodes } };
      switch (line.event) {
        case "node": {
          sc.nodes[line.id] = { id: line.id, parent: line.parent, name: line.name, kind: line.kind, size: line.size, display: line.display,
            installer: line.installer, macType: line.macType, children: sc.nodes[line.id]?.children ?? [], images: 0, newImages: 0, skips: [] };
          if (line.parent != null && sc.nodes[line.parent]) {
            const p = sc.nodes[line.parent];
            sc.nodes[line.parent] = { ...p, children: [...p.children, line.id] };
          } else sc.roots = [...sc.roots, line.id];
          sc.lastNode = line.id;
          break;
        }
        case "image": {
          const n = sc.nodes[line.node];
          if (n) sc.nodes[line.node] = { ...n, images: n.images + 1, newImages: n.newImages + (line.new ? 1 : 0) };
          break;
        }
        case "skip": {
          const n = line.node != null ? sc.nodes[line.node] : undefined;
          if (n) sc.nodes[line.node!] = { ...n, skips: [...n.skips, { name: line.name, reason: line.reason }] };
          else sc.looseSkips = [...sc.looseSkips, { name: line.name, reason: line.reason }];
          break;
        }
        case "progress": sc.progress = { nodes: line.nodes, images: line.images, queued: line.queued, bytesExtracted: line.bytesExtracted }; break;
        case "done": sc.done = line; sc.lastNode = null; break;
      }
      scans[scan] = sc;
    }
    return { scans };
  });
}

/** Images found at a node and everything under it. */
export function imagesBelow(sc: Scan, id: number): { all: number; fresh: number } {
  const n = sc.nodes[id];
  if (!n) return { all: 0, fresh: 0 };
  let all = n.images, fresh = n.newImages;
  for (const c of n.children) { const r = imagesBelow(sc, c); all += r.all; fresh += r.fresh; }
  return { all, fresh };
}
