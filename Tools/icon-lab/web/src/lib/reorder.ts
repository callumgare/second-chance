// Reordering a list by dragging: an effect, a colour stop, a pin. A row (or just its handle) is dragged; the
// drop lands before or after the row under the pointer, shown by a line, and `onMove(from, to)` hears the move
// with `to` the row's new index. Drags carry their own type, so one list never takes another's rows, and a drag
// from outside (files, the Add section's tiles) passes through untouched.
import { useState, type DragEvent } from "react";

export type Reorder = {
  /** Spread on what starts the drag (the row, or its handle). */
  handle(i: number): { draggable: true; onDragStart(e: DragEvent): void; onDragEnd(): void }
  /** Spread on each row. */
  row(i: number): { onDragOver(e: DragEvent): void; onDrop(e: DragEvent): void; "data-drop"?: "before" | "after" }
  dragging: number | null
};

/** `kind` names the list ("effects", "pins"); `horizontal` for a list laid out in a row. */
export function useReorder(kind: string, onMove: (from: number, to: number) => void, horizontal = false): Reorder {
  const type = `application/x-iconlab-reorder-${kind}`;
  const [dragging, setDragging] = useState<number | null>(null);
  const [over, setOver] = useState<{ i: number; after: boolean } | null>(null);
  const end = () => { setDragging(null); setOver(null); };
  const mine = (e: DragEvent) => e.dataTransfer.types.includes(type);
  const side = (e: DragEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    return horizontal ? e.clientX > r.left + r.width / 2 : e.clientY > r.top + r.height / 2;
  };
  return {
    dragging,
    handle: (i) => ({
      draggable: true,
      onDragStart: (e) => {
        e.stopPropagation();
        e.dataTransfer.setData(type, String(i));
        e.dataTransfer.effectAllowed = "move";
        setDragging(i);
      },
      onDragEnd: end,
    }),
    row: (i) => ({
      onDragOver: (e) => {
        if (!mine(e)) return;
        e.preventDefault();
        e.stopPropagation();
        e.dataTransfer.dropEffect = "move";
        const after = side(e);
        if (over?.i !== i || over.after !== after) setOver({ i, after });
      },
      onDrop: (e) => {
        if (!mine(e)) return;
        e.preventDefault();
        e.stopPropagation();
        const from = Number(e.dataTransfer.getData(type));
        const at = i + (side(e) ? 1 : 0);          // the gap it was dropped in, before the move
        const to = at > from ? at - 1 : at;
        end();
        if (Number.isInteger(from) && to !== from) onMove(from, to);
      },
      ...(over?.i === i && dragging != null ? { "data-drop": over.after ? "after" as const : "before" as const } : {}),
    }),
  };
}

/** The list with one item moved (a copy). */
export function moved<T>(list: readonly T[], from: number, to: number): T[] {
  const out = [...list];
  const [x] = out.splice(from, 1);
  out.splice(to, 0, x);
  return out;
}
