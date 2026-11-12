// The design canvas's zoom and pan. 1 is the automatic fit; the pan moves the icon's centre off the frame's, in
// screen pixels. Remembered per program for the session.
import { create } from "zustand";
import { useApp } from "./app";

export const ZOOM_MIN = 0.25, ZOOM_MAX = 8;
type View = { zoom: number; pan: { x: number; y: number } };
const FIT: View = { zoom: 1, pan: { x: 0, y: 0 } };
const byProgram = new Map<string, View>();

export const useZoom = create<View & { program: string | null }>(() => ({ ...FIT, program: null }));

const clampZoom = (z: number) => Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z));

function put(v: View) {
  const program = useApp.getState().program?.slug ?? null;
  // Unzoomed, the icon sits centred: no pan.
  const view = v.zoom <= 1 ? { zoom: v.zoom, pan: { x: 0, y: 0 } } : v;
  if (program) byProgram.set(program, view);
  useZoom.setState({ ...view, program });
}

/** Switch to a program's remembered view (fit when there's none). */
export function zoomForProgram(slug: string | null) {
  if (useZoom.getState().program === slug) return;
  useZoom.setState({ ...(slug ? byProgram.get(slug) ?? FIT : FIT), program: slug });
}

/** Zoom to `z`, keeping the point `at` (screen px from the frame's centre) where it is; the frame's centre when absent. */
export function setZoom(z: number, at?: { x: number; y: number }) {
  const { zoom, pan } = useZoom.getState();
  const nz = clampZoom(z);
  const p = at ?? { x: 0, y: 0 };
  const k = nz / zoom;
  put({ zoom: nz, pan: { x: p.x - (p.x - pan.x) * k, y: p.y - (p.y - pan.y) * k } });
}
export const zoomBy = (factor: number, at?: { x: number; y: number }) => setZoom(useZoom.getState().zoom * factor, at);
export const zoomFit = () => put(FIT);
export function panBy(dx: number, dy: number) {
  const { zoom, pan } = useZoom.getState();
  if (zoom <= 1) return;
  put({ zoom, pan: { x: pan.x + dx, y: pan.y + dy } });
}
/** Steps for − / + and ⌘− / ⌘+. */
const STEPS = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8];
export const zoomStep = (dir: 1 | -1) => {
  const z = useZoom.getState().zoom;
  const next = dir > 0 ? STEPS.find((s) => s > z + 0.001) : [...STEPS].reverse().find((s) => s < z - 0.001);
  setZoom(next ?? z);
};
