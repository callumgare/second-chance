// Real Liquid Glass renders (ictool through /api/render/icon), queued so a screenful of tiles doesn't start
// forty at once, with what the editor needs first. Cached by what the doc looks like.
import { api, type Appearance, type Doc } from "../api";
import { visualKey } from "../lib/doc";

/** Where the icon's shape sits in a render: v1's ictool renders were full bleed (the shape fills the image).
 *  If the engine's macOS renders keep the grid's margin, this becomes 100 / 1024. */
export const RENDER_INSET = 0;

type Task = { key: string; doc: Doc; appearance: Appearance; size: number; priority: number; resolve: (u: string) => void; reject: (e: unknown) => void };

const done = new Map<string, string>();
const inflight = new Map<string, Promise<string>>();
const queue: Task[] = [];
let running = 0;
const MAX = 2;

export function iconKey(doc: Doc, appearance: Appearance, size: number) {
  return visualKey(doc) + "|" + appearance + "|" + size;
}

export function cachedIconRender(doc: Doc, appearance: Appearance, size: number): string | null {
  return done.get(iconKey(doc, appearance, size)) ?? null;
}

/** priority: 0 = the editor, 1 = previews, 2 = tiles. */
export function requestIconRender(doc: Doc, appearance: Appearance, size: number, priority = 2): Promise<string> {
  const s = Math.max(16, Math.min(1024, Math.round(size)));
  const key = iconKey(doc, appearance, s);
  const have = done.get(key);
  if (have) return Promise.resolve(have);
  const p = inflight.get(key);
  if (p) {
    const t = queue.find((q) => q.key === key);
    if (t && priority < t.priority) { t.priority = priority; queue.sort((a, b) => a.priority - b.priority); }
    return p;
  }
  const promise = new Promise<string>((resolve, reject) => {
    queue.push({ key, doc: structuredClone(doc), appearance, size: s, priority, resolve, reject });
    queue.sort((a, b) => a.priority - b.priority);
  });
  inflight.set(key, promise);
  pump();
  return promise;
}

/** Drops queued (not started) requests at a priority, e.g. tiles scrolled away or a stale editor render. */
export function cancelQueued(match: (key: string, priority: number) => boolean) {
  for (let i = queue.length - 1; i >= 0; i--) {
    const t = queue[i];
    if (match(t.key, t.priority)) { queue.splice(i, 1); inflight.delete(t.key); t.reject(new DOMException("cancelled", "AbortError")); }
  }
}

function pump() {
  while (running < MAX && queue.length) {
    const t = queue.shift()!;
    running++;
    api.renderIcon(t.doc, t.appearance, t.size)
      .then((r) => { done.set(t.key, r.url); t.resolve(r.url); })
      .catch((e) => t.reject(e))
      .finally(() => { inflight.delete(t.key); running--; pump(); });
  }
}

const peeked = new Map<string, Promise<string | null>>();
/** An existing render, without making one (cachedOnly): null when there's none yet. */
export function peekIconRender(doc: Doc, appearance: Appearance, size: number): Promise<string | null> {
  const s = Math.max(16, Math.min(1024, Math.round(size)));
  const key = iconKey(doc, appearance, s);
  const have = done.get(key);
  if (have) return Promise.resolve(have);
  let p = peeked.get(key);
  if (!p) {
    p = api.renderIcon(doc, appearance, s, true).then((r) => { done.set(key, r.url); return r.url; }).catch(() => null);
    peeked.set(key, p);
  }
  return p;
}
