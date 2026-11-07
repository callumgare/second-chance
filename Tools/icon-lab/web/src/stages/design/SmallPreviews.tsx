// 64, 32 and 16 px previews in the canvas's corner: ictool's renders of the current doc at those sizes (at the
// screen's pixel density), asked for once editing pauses. The sketch stands in until they arrive.
import { useEffect, useState } from "react";
import type { Appearance, Doc } from "../../api";
import { IconArt } from "../../components/IconArt";
import { useDesign } from "../../state/design";

export function SmallPreviews({ doc, appearance }: { doc: Doc; appearance: Appearance }) {
  const transient = useDesign((s) => s.transientBase != null);
  const final = useDesign((s) => s.glass);
  // Follow the doc only once it settles, so a drag doesn't queue a render per frame.
  const [settled, setSettled] = useState(doc);
  useEffect(() => {
    if (transient) return;
    const t = window.setTimeout(() => setSettled(doc), 600);
    return () => window.clearTimeout(t);
  }, [doc, transient]);
  return (
    <div className="sizes" title={final ? "Real renders at 64, 32 and 16 pt" : "Sketches at 64, 32 and 16 pt (Final shows the real renders)"}>
      {[64, 32, 16].map((s) => (
        <span key={s} className="col" style={{ justifyItems: "center", gap: 3 }}>
          <IconArt doc={final ? settled : doc} size={s} appearance={appearance} real={final ? "eager" : false} priority={1} waiting />
          <span>{s}</span>
        </span>
      ))}
    </div>
  );
}
