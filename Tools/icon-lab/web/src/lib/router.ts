// Hash routing: #/ (pick a program), #/p/<slug>/<stage>.
import { useSyncExternalStore } from "react";

export type Stage = "find" | "gather" | "design" | "review";
export type Route = { slug: string | null; stage: Stage };

const STAGES: Stage[] = ["find", "gather", "design", "review"];

export function parseHash(hash: string): Route {
  const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  if (parts[0] === "p" && parts[1]) {
    const stage = (STAGES as string[]).includes(parts[2]) ? (parts[2] as Stage) : "design";
    return { slug: decodeURIComponent(parts[1]), stage };
  }
  return { slug: null, stage: "find" };
}

export function href(slug: string | null, stage: Stage): string {
  return slug ? `#/p/${encodeURIComponent(slug)}/${stage}` : "#/";
}

export function go(slug: string | null, stage: Stage) {
  const h = href(slug, stage);
  if (location.hash !== h) location.hash = h;
}

let current = parseHash(location.hash);
const subs = new Set<() => void>();
window.addEventListener("hashchange", () => { current = parseHash(location.hash); subs.forEach((f) => f()); });

export function useRoute(): Route {
  return useSyncExternalStore((f) => { subs.add(f); return () => subs.delete(f); }, () => current);
}
