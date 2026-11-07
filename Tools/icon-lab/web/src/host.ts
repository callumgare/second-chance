// The page's host: what it reaches outside itself goes through here, so the same page runs in two hosts.
//
// - The dev host (Tools/icon-lab/server, `sc icon-lab serve`): the API over HTTP, events on the /api/events
//   WebSocket, links in a new browser tab, the browser's clipboard.
// - Second Chance's Icon Lab window: a WKWebView whose URL scheme handler answers /api itself. It has no WebSocket:
//   the app calls `window.iconLabHost.event(json)` with each event. Links and clipboard writes are posted to the
//   `iconLab` script message handler, so links open in the person's browser.
//
// The contract is in Packages/IconLab/README.md ("The page's host").

/** A message the page posts to the app (`window.webkit.messageHandlers.iconLab.postMessage`). */
export type HostMessage =
  | { type: "open"; url: string }
  | { type: "copy"; text: string };

type AppBridge = { postMessage(m: HostMessage): void };
declare global {
  interface Window {
    webkit?: { messageHandlers?: { iconLab?: AppBridge } };
    /** What the app calls: `event` with each engine event (a JSON string or the object itself). */
    iconLabHost?: { event(e: string | object): void };
  }
}

const bridge = (): AppBridge | null => window.webkit?.messageHandlers?.iconLab ?? null;

/** Inside Second Chance's window: the message handler is there, or the app added `?host=app`. */
export const inApp = (): boolean => !!bridge() || new URLSearchParams(location.search).get("host") === "app";

/** Where the API is: the same origin in both hosts. */
export const API_BASE = "/api";

export type EventStatus = "connecting" | "open" | "closed";

/** Listens to the engine's events until the returned function is called. */
export function listenToEvents(onEvent: (e: unknown) => void, onStatus: (s: EventStatus) => void): () => void {
  if (inApp()) {
    // The app pushes; there's nothing to connect to. Events that arrive before the page listens are the app's to
    // hold back (it starts sending once the page has loaded).
    const listeners = appListeners;
    const l = (e: unknown) => onEvent(e);
    listeners.add(l);
    onStatus("open");
    return () => { listeners.delete(l); };
  }
  let ws: WebSocket | null = null;
  let stopped = false;
  let delay = 500;
  let timer: number | undefined;
  const connect = () => {
    if (stopped) return;
    onStatus("connecting");
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(`${proto}//${location.host}${API_BASE}/events`);
    ws.onopen = () => { delay = 500; onStatus("open"); };
    ws.onmessage = (m) => { try { onEvent(JSON.parse(m.data)); } catch { /* not ours */ } };
    ws.onclose = () => {
      onStatus("closed");
      if (!stopped) { timer = window.setTimeout(connect, delay); delay = Math.min(delay * 2, 8000); }
    };
  };
  connect();
  return () => { stopped = true; window.clearTimeout(timer); ws?.close(); };
}

const appListeners = new Set<(e: unknown) => void>();
window.iconLabHost = {
  event(e) {
    let v: unknown = e;
    if (typeof e === "string") { try { v = JSON.parse(e); } catch { return; } }
    appListeners.forEach((l) => l(v));
  },
};

/** Opens a link outside the page: the person's browser in the app, a new tab in dev. */
export function openLink(url: string) {
  const b = bridge();
  if (b) { b.postMessage({ type: "open", url }); return; }
  window.open(url, "_blank", "noopener,noreferrer");
}

/** Puts text on the system clipboard; false when neither the browser nor the app could. */
export async function copyText(text: string): Promise<boolean> {
  try { if (navigator.clipboard) { await navigator.clipboard.writeText(text); return true; } } catch { /* restricted: ask the app */ }
  const b = bridge();
  if (b) { b.postMessage({ type: "copy", text }); return true; }
  return false;
}

/** Reads text from the system clipboard, when the host lets the page. */
export async function readText(): Promise<string | null> {
  try { return navigator.clipboard ? await navigator.clipboard.readText() : null; } catch { return null; }
}

// Links that open a new tab (`target="_blank"`) go through `openLink`, so in the app they reach the browser rather
// than a web view that has nowhere to put them.
document.addEventListener("click", (e) => {
  if (e.defaultPrevented || e.button !== 0) return;
  const a = (e.target as Element | null)?.closest?.("a[target=_blank]") as HTMLAnchorElement | null;
  if (!a?.href || !inApp()) return;
  e.preventDefault();
  openLink(a.href);
});
