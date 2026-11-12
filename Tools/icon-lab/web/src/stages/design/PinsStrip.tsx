// Pinned designs, then "Current" when the doc being edited looks like none of them. A pin is a frozen
// snapshot: clicking one opens it, and the first edit continues on a copy (parent = the pin).
import { IconArt } from "../../components/IconArt";
import { pinnedMatch, useDesign } from "../../state/design";
import { Menu, usePopup } from "../../components/Popup";
import { useState } from "react";

export function PinsStrip() {
  const doc = useDesign((s) => s.doc);
  const docs = useDesign((s) => s.docs);
  const pins = useDesign((s) => s.pins);
  const appearance = useDesign((s) => s.appearance);
  const match = useDesign((s) => pinnedMatch(s));
  const menu = usePopup();
  const [menuFor, setMenuFor] = useState<string | null>(null);
  if (!doc) return null;
  return (
    <div className="pinsbar">
      <span className="sec" style={{ margin: 0 }}>Pinned</span>
      <div className="pins">
        {pins.map((id) => docs[id] && (
          <button key={id} className={"tile" + (match === id ? " on cur" : "")} onClick={() => useDesign.getState().openPin(id)}
            onContextMenu={(e) => { e.preventDefault(); setMenuFor(id); menu.open(e.currentTarget); }} title={`${docs[id].name} · click to open, right-click for more`}>
            <IconArt doc={docs[id]} size={52} appearance={appearance} real="visible" />
            <span className="lbl"><span className="star">★</span> {docs[id].name}</span>
            <span className="unpin" role="button" aria-label="Unpin" title="Unpin" onClick={(e) => { e.stopPropagation(); void useDesign.getState().unpin(id); }}>✕</span>
          </button>
        ))}
        {!match && (
          <div className="tile on cur" title="The design you're editing (not pinned)">
            <IconArt doc={doc} size={52} appearance={appearance} />
            <span className="lbl">Current</span>
          </div>
        )}
        {!pins.length && <span className="faint" style={{ fontSize: 11.5 }}>Pin designs worth keeping, then review them side by side.</span>}
      </div>
      <button className="btn" disabled={!!match} onClick={() => void useDesign.getState().pinCurrent()} title="Pin a snapshot of the current design (P)">
        {match ? "★ Pinned" : "☆ Pin current"}
      </button>
      <Menu anchor={menu.anchor} onClose={menu.close} items={menuFor ? [
        { label: "Open", onClick: () => useDesign.getState().openPin(menuFor) },
        { label: "Unpin", onClick: () => void useDesign.getState().unpin(menuFor) },
      ] : []} />
    </div>
  );
}
