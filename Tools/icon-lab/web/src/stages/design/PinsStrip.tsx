// Pinned designs, then "Current" when the doc being edited looks like none of them. A pin is a frozen
// snapshot: clicking one opens it, the first edit continues on a copy (parent = the pin), and Update pin saves
// the copy back to it. Pins are dragged into the order Review shows and saving follows.
import { IconArt } from "../../components/IconArt";
import { pinnedMatch, updatablePin, useDesign } from "../../state/design";
import { Menu, usePopup } from "../../components/Popup";
import { useReorder } from "../../lib/reorder";
import { useState } from "react";

export function PinsStrip() {
  const doc = useDesign((s) => s.doc);
  const docs = useDesign((s) => s.docs);
  const pins = useDesign((s) => s.pins);
  const appearance = useDesign((s) => s.appearance);
  const match = useDesign((s) => pinnedMatch(s));
  const updatable = useDesign((s) => updatablePin(s));
  const menu = usePopup();
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const r = useReorder("pins", (from, to) => void useDesign.getState().movePin(from, to), true);
  if (!doc) return null;
  const open = (id: string) => useDesign.getState().openPin(id);
  return (
    <div className="pinsbar">
      <span className="sec" style={{ margin: 0 }}>Pinned</span>
      <div className="pins">
        {pins.map((id, i) => docs[id] && (
          <div key={id} role="button" tabIndex={0} {...r.handle(i)} {...r.row(i)}
            className={"tile" + (match === id ? " on cur" : "") + (updatable === id ? " edited" : "") + (r.dragging === i ? " dragging" : "")}
            onClick={() => open(id)} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(id); } }}
            onContextMenu={(e) => { e.preventDefault(); setMenuFor(id); menu.open(e.currentTarget); }}
            title={`${docs[id].name} · click to open, drag to reorder, right-click for more${updatable === id ? "\nYou're editing a copy of this pin: Update pin saves your changes to it" : ""}`}>
            <IconArt doc={docs[id]} size={52} appearance={appearance} real="visible" />
            <span className="lbl"><span className="star">★</span> {docs[id].name}</span>
            <span className="unpin" role="button" aria-label="Unpin" title="Unpin" onClick={(e) => { e.stopPropagation(); void useDesign.getState().unpin(id); }}>✕</span>
          </div>
        ))}
        {!match && (
          <div className="tile on cur" title={updatable ? `The design you're editing: a changed copy of “${docs[updatable]?.name}”` : "The design you're editing (not pinned)"}>
            <IconArt doc={doc} size={52} appearance={appearance} />
            <span className="lbl">Current</span>
          </div>
        )}
        {!pins.length && <span className="faint" style={{ fontSize: 11.5 }}>Pin designs worth keeping, then review them side by side.</span>}
      </div>
      {updatable && (
        <button className="btn" onClick={() => void useDesign.getState().updatePin()} title={`Save your changes to the pin “${docs[updatable]?.name}”`}>
          ↻ Update pin
        </button>
      )}
      <button className="btn" disabled={!!match} onClick={() => void useDesign.getState().pinCurrent()} title="Pin a snapshot of the current design as a new pin (P)">
        {match ? "★ Pinned" : updatable ? "☆ Pin as new" : "☆ Pin current"}
      </button>
      <Menu anchor={menu.anchor} onClose={menu.close} items={menuFor ? [
        { label: "Open", onClick: () => open(menuFor) },
        ...(updatable === menuFor ? [{ label: "Update with your changes", onClick: () => void useDesign.getState().updatePin() }] : []),
        { label: "Unpin", onClick: () => void useDesign.getState().unpin(menuFor) },
      ] : []} />
    </div>
  );
}
