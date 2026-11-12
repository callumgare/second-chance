// Places in the frame a stage fills from inside (the title bar's actions, the status bar's text).
import { useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";

function createSlot(style?: React.CSSProperties) {
  let el: HTMLElement | null = null;
  const subs = new Set<() => void>();
  const set = (e: HTMLElement | null) => { if (e !== el) { el = e; subs.forEach((f) => f()); } };
  const useEl = () => useSyncExternalStore((f) => { subs.add(f); return () => subs.delete(f); }, () => el);
  return {
    Slot: () => <div ref={set} style={{ display: "contents", ...style }} />,
    Fill: ({ children }: { children: ReactNode }) => {
      const target = useEl();
      return target ? createPortal(children, target) : null;
    },
  };
}

export const TitleActions = createSlot();
export const StatusSlot = createSlot();
