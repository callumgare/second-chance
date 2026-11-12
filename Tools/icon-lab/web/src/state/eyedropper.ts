// The eyedropper: a colour control asks for a colour from the design canvas, and the canvas, while it's asked,
// samples where it's clicked instead of selecting. The colour is the design's own (layers with their effects, the
// fill), not what Icon Composer adds over it (sketch.ts's `flat`).
import { create } from "zustand";

type State = {
  /** Called with the colour picked; set while picking. */
  picking: ((hex: string) => void) | null
  /** How many design canvases are on screen: none, and there's nothing to pick from. */
  canvases: number
};

export const useEyedropper = create<State>(() => ({ picking: null, canvases: 0 }));

export function startPicking(onPick: (hex: string) => void) { useEyedropper.setState({ picking: onPick }); }
export function stopPicking() { useEyedropper.setState({ picking: null }); }

/** A canvas mounting (for as long as it's there). */
export function canvasMounted() {
  useEyedropper.setState((s) => ({ canvases: s.canvases + 1 }));
  return () => useEyedropper.setState((s) => ({ canvases: s.canvases - 1, picking: s.canvases > 1 ? s.picking : null }));
}
