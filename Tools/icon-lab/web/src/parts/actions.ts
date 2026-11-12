// What the page does with parts: each call goes to the engine, and falls back to parts/shim.ts when the engine
// hasn't got the route yet (a 404 with no body) or this is the mock.
import { api, ApiError, currentTransport, type Candidate, type Edges, type Media, type MediaKind, type Part, type Prompt, type Rotation } from "../api";
import { useApp } from "../state/app";
import { changeOverlay, localCandidates, localPreview, localSavePart, withParts } from "./shim";

const app = () => useApp.getState();
const slugOf = () => app().program?.slug ?? "";
const local = () => currentTransport().kind === "mock";
const missing = (e: unknown) => e instanceof ApiError && (e.routeMissing || e.status === 405);

function refresh(id: string, fromEngine?: Media) {
  const slug = slugOf();
  const cur = fromEngine ?? app().media.get(id);
  if (cur) app().upsertMedia(slug, withParts(slug, cur));
}

/** Engine first; on a missing route, `fallback` changes the local overlay and the media is re-made from it. */
async function either(id: string, engine: () => Promise<Media>, fallback: () => void) {
  if (!local() && !app().media.get(id)?.partsLocal) {
    try { refresh(id, await engine()); return; } catch (e) { if (!missing(e)) throw e; }
  }
  fallback();
  refresh(id);
}

export async function pickPart(m: Media, part: Part, picked: boolean) {
  const slug = slugOf();
  const wasAny = m.parts?.some((p) => p.picked) ?? m.picked;
  await either(m.id, () => api.patchPart(slug, m.id, part.id, { picked }), () =>
    changeOverlay(slug, m.id, (o) => { o.parts = { ...(o.parts ?? {}), [part.id]: { ...(o.parts?.[part.id] ?? {}), picked } }; }));
  // Without the engine's parts, its "picked" (which starts the hi-res and deep analysis) follows "any part picked".
  const now = app().media.get(m.id);
  const isAny = now?.parts?.some((p) => p.picked) ?? picked;
  if (now?.partsLocal && isAny !== wasAny) {
    try { const r = await api.pick(slug, m.id, isAny); refresh(m.id, { ...r }); } catch (e) { app().say("Couldn't change the pick: " + (e as Error).message, "error"); }
  }
}

/** The grid's circle: every part, or none. */
export async function pickAll(m: Media, picked: boolean) {
  const slug = slugOf();
  if (m.partsLocal || local()) {
    changeOverlay(slug, m.id, (o) => { o.parts = { ...(o.parts ?? {}) }; for (const p of m.parts ?? []) o.parts[p.id] = { ...(o.parts[p.id] ?? {}), picked }; });
    refresh(m.id);
  }
  await app().setPicked(m.id, picked);
}

export async function setPartFields(m: Media, part: Part, patch: { kind?: MediaKind | "unknown"; rotation?: Rotation; name?: string }) {
  const slug = slugOf();
  await either(m.id, () => api.patchPart(slug, m.id, part.id, patch), () =>
    changeOverlay(slug, m.id, (o) => { o.parts = { ...(o.parts ?? {}), [part.id]: { ...(o.parts?.[part.id] ?? {}), ...patch, ...(patch.kind ? { kindSet: true } : {}) } }; }));
}

export async function rotateMedia(m: Media, rotation: Rotation) {
  const slug = slugOf();
  if (!local() && !m.partsLocal) {
    try { refresh(m.id, await api.patchMediaFields(slug, m.id, { rotation })); return; } catch (e) { if (!missing(e)) throw e; }
  }
  changeOverlay(slug, m.id, (o) => { o.rotation = rotation; });
  refresh(m.id);
}

export async function setMediaKind(m: Media, kind: MediaKind | "unknown") {
  const slug = slugOf();
  if (!local()) {
    try { refresh(m.id, await api.patchMediaFields(slug, m.id, { kind })); return; }
    catch (e) { if (!missing(e) && !(e instanceof ApiError && e.status === 400)) throw e; }
  }
  changeOverlay(slug, m.id, (o) => { o.kind = kind; });
  refresh(m.id);
}

export async function deletePart(m: Media, part: Part) {
  const slug = slugOf();
  await either(m.id, () => api.deletePart(slug, m.id, part.id), () =>
    changeOverlay(slug, m.id, (o) => {
      o.added = (o.added ?? []).filter((p) => p.id !== part.id);
      if (!part.id.startsWith("p-")) o.removed = [...new Set([...(o.removed ?? []), part.id])];
    }));
}

/** Candidates for a prompt: SAM (segment) when there are clicks, Vision (detect) for a region alone; the page's
 *  own when neither route answers. `engine` says which answered. */
export async function candidatesFor(m: Media, prompt: { region?: Prompt["region"]; points?: Prompt["points"] }): Promise<{ candidates: Candidate[]; engine: "sam" | "vision" | "page" }> {
  const slug = slugOf();
  if (!local()) {
    if (prompt.points?.length || !prompt.region) {
      try { return { candidates: (await api.segment(slug, m.id, prompt)).candidates, engine: "sam" }; } catch (e) { if (!missing(e)) throw e; }
    }
    if (prompt.region) {
      try {
        // SAM, when it answers, takes a region too; else Vision inside the region.
        try { return { candidates: (await api.segment(slug, m.id, prompt)).candidates, engine: "sam" }; } catch (e) { if (!missing(e)) throw e; }
        return { candidates: (await api.detect(slug, m.id, prompt.region)).candidates, engine: "vision" };
      } catch (e) { if (!missing(e)) throw e; }
    }
  }
  return { candidates: await localCandidates(m, prompt), engine: "page" };
}

/** The candidate with its edges done, and where it sits in the picture (the box changes as it grows). */
export async function previewCandidate(m: Media, cand: string, edges: Edges): Promise<{ url: string; box?: [number, number, number, number] }> {
  if (cand.startsWith("local-")) return localPreview(m, cand, edges);
  return api.previewCandidate(slugOf(), m.id, cand, edges);
}

export async function saveCandidate(m: Media, cand: string, opts: { partId?: string; name?: string; kind?: string; edges?: Edges; prompt?: Prompt }) {
  const slug = slugOf();
  if (cand.startsWith("local-") || m.partsLocal) {
    if (!cand.startsWith("local-")) throw new Error("This picture's parts are kept by the page until the engine has them: make the choice again.");
    await localSavePart(slug, m, cand, opts);
    refresh(m.id);
    return;
  }
  const r = opts.partId
    ? await api.updatePart(slug, m.id, opts.partId, { candidate: cand, edges: opts.edges, prompt: opts.prompt })
    : await api.addPart(slug, m.id, { candidate: cand, name: opts.name, kind: opts.kind, edges: opts.edges, prompt: opts.prompt });
  refresh(m.id, r);
}
