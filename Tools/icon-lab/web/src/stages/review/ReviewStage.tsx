// Review (layout D): every pinned design side by side, in each appearance and the places an icon is seen,
// all from ictool's real renders. Keep the good ones and save them (.icon and a 1024 PNG each).
import { useState, type ReactNode } from "react";
import { api, type Doc, type SavedToBundle } from "../../api";
import { IconArt } from "../../components/IconArt";
import { go } from "../../lib/router";
import { useApp } from "../../state/app";
import { useDesign } from "../../state/design";
import { StatusSlot, TitleActions } from "../../shell/slots";
import "./review.css";
import { copyText } from "../../host";
import { TryOnWrapp, useHost } from "./HostActions";
import { useReorder } from "../../lib/reorder";

type Row = { label: string; hint?: string; cell(d: Doc): ReactNode };

export function ReviewStage({ slug }: { slug: string }) {
  const docs = useDesign((s) => s.docs);
  const pins = useDesign((s) => s.pins);
  const keep = useDesign((s) => s.keep);
  const title = useApp((s) => s.program?.title ?? slug);
  const [wall, setWall] = useState<"light" | "dark">("light");
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState<{ id: string; icon: string; png: string }[] | null>(null);
  const host = useHost();
  const bundle = useApp((s) => s.program?.bundleId);
  const [trying, setTrying] = useState<Doc | null>(null);
  // A build that can write bundles (a Debug build from a checkout) saves to the program's bundle too.
  const [toBundle, setToBundle] = useState<{ saved?: SavedToBundle; lines?: { lines: string[]; change: string }; error?: string } | null>(null);
  const pinned = pins.map((id) => docs[id]).filter(Boolean);
  const kept = pinned.filter((d) => keep[d.id] !== false);
  const firstKept = kept[0]?.id;
  // Columns are in the pins' order, which Design's strip shows too and saving follows (the first is the app's icon).
  const r = useReorder("pins", (from, to) => void useDesign.getState().movePin(pins.indexOf(pinned[from].id), pins.indexOf(pinned[to].id)), true);

  const rows: Row[] = [
    { label: "1024 · light", hint: "the full-size render", cell: (d) => <IconArt doc={d} size={150} renderSize={1024} appearance="light" real="eager" priority={1} /> },
    { label: "Dark", cell: (d) => <IconArt doc={d} size={150} appearance="dark" real="eager" priority={1} /> },
    { label: "Tinted", cell: (d) => <IconArt doc={d} size={150} appearance="tinted" real="eager" priority={1} /> },
    { label: "Clear", cell: (d) => <IconArt doc={d} size={150} appearance="clear" real="eager" priority={1} /> },
    { label: "In the Dock", hint: "64 pt", cell: (d) => (
      <span className={"ctx dock " + wall}>
        <span className="other a" /><IconArt doc={d} size={56} real="eager" priority={1} /><span className="other b" />
      </span>) },
    { label: "Finder list", hint: "16 pt", cell: (d) => (
      <span className={"ctx list " + wall}><IconArt doc={d} size={16} real="eager" priority={1} /><span className="ellipsis">{title}</span></span>) },
    { label: "32 pt", cell: (d) => <span className={"ctx plain " + wall}><IconArt doc={d} size={32} real="eager" priority={1} /></span> },
  ];

  const save = async () => {
    setSaving(true);
    try {
      const r = await api.save(slug, kept.map((d) => d.id));
      useDesign.getState().set({ savedIds: [...new Set([...useDesign.getState().savedIds, ...r.saved.map((x) => x.id)])] });
      if (host?.saveToBundle && bundle) {
        const b: NonNullable<typeof toBundle> = {};
        try {
          b.saved = await api.saveToBundle(slug, kept.map((d) => d.id));
          if (b.saved.canAddLines || !b.saved.wrappfileLines) b.lines = await api.addIconLines(slug);
        } catch (e) { b.error = (e as Error).message; }
        setToBundle(b);
      } else setToBundle(null);
      setSaved(r.saved);
    } catch (e) {
      useApp.getState().say("Couldn't save: " + (e as Error).message, "error");
    } finally { setSaving(false); }
  };

  return (
    <div className="cmp scroll">
      <div className="cmp-head">
        <div><b style={{ fontSize: 15 }}>Compare pinned icons</b> <span className="muted">· keep the ones worth saving, and drag them into order: the first is the app's icon</span></div>
        <span className="seg"><button className={wall === "light" ? "on" : ""} onClick={() => setWall("light")}>Light desktop</button><button className={wall === "dark" ? "on" : ""} onClick={() => setWall("dark")}>Dark desktop</button></span>
      </div>
      {!pinned.length ? <div className="empty">Nothing pinned yet. Pin designs in the editor, then come back to compare them.<br /><button className="btn" style={{ marginTop: 8 }} onClick={() => go(slug, "design")}>← Back to the editor</button></div> : (
        <table className="cmpt">
          <thead>
            <tr>
              <th />
              {pinned.map((d, i) => {
                const on = keep[d.id] !== false;
                return (
                  <th key={d.id} className={"colh" + (r.dragging === i ? " dragging" : "")} {...r.handle(i)} {...r.row(i)} title="Drag to reorder: saving follows this order, the first is the app's icon">
                    <div className="colgrip" aria-hidden><span className="grip">⠿</span>{d.id === firstKept ? `${i + 1} · the app's icon` : `${i + 1}`}<span className="grip">⠿</span></div>
                    <div className="wraps" title={d.name}>{d.name}</div>
                    <div className="row" style={{ justifyContent: "center", gap: 4, marginTop: 4 }}>
                      <button className={"btn small" + (on ? " on" : "")} aria-pressed={on} onClick={() => void useDesign.getState().setKeep(d.id, !on)}>{on ? "✓ Keep" : "Keep"}</button>
                      <button className="btn small" onClick={() => { useDesign.getState().openPin(d.id); go(slug, "design"); }}>Edit</button>
                    </div>
                    {host?.wrapps && <button className="btn small ghost" style={{ marginTop: 4 }} onClick={() => setTrying(d)}>Try on an app…</button>}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.label}>
                <th>{row.label}{row.hint && <div className="faint" style={{ fontWeight: 400 }}>{row.hint}</div>}</th>
                {pinned.map((d, i) => <td key={d.id} className={(keep[d.id] === false ? "dropped" : "") + (r.dragging === i ? " dragging" : "")}
                  {...r.handle(i)} {...r.row(i)} title="Drag to reorder">{row.cell(d)}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {saved && (
        <div className="scrim" onClick={() => setSaved(null)}>
          <div className="dlg" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Saved">
            <header><h2>Saved {saved.length} icon{saved.length === 1 ? "" : "s"}</h2></header>
            <div className="saved-list">
              {saved.map((s) => (
                <div key={s.id} className="saved-row">
                  {docs[s.id] && <IconArt doc={docs[s.id]} size={40} real="eager" />}
                  <div className="col" style={{ gap: 2, minWidth: 0 }}>
                    <b>{docs[s.id]?.name ?? s.id}</b>
                    <span className="mono wraps" title={s.icon}>{tail(s.icon)}</span>
                    <span className="mono wraps" title={s.png}>{tail(s.png)}</span>
                  </div>
                  <button className="btn small" onClick={() => void copyText(s.icon)}>Copy path</button>
                </div>
              ))}
              {toBundle && <BundleSaved bundle={bundle ?? ""} result={toBundle} />}
            </div>
            <footer><button className="btn primary" onClick={() => setSaved(null)}>Done</button></footer>
          </div>
        </div>
      )}
      {trying && <TryOnWrapp slug={slug} doc={trying} onClose={() => setTrying(null)} />}
      <TitleActions.Fill>
        <button className="btn" onClick={() => go(slug, "design")}>‹ Back to design</button>
        <button className="btn primary" disabled={!kept.length || saving} onClick={save}>{saving ? <><span className="spin" /> Saving…</> : `Save ${kept.length} kept`}</button>
      </TitleActions.Fill>
      <StatusSlot.Fill><span>{kept.length} of {pinned.length} kept</span><span className="faint">Saving writes each kept design's .icon and a 1024 px PNG to data/programs/{slug}/saved/{host?.saveToBundle && bundle ? `, and to ${bundle}'s assets/ with its Wrappfile giving the app the first` : ""}</span></StatusSlot.Fill>
    </div>
  );
}

/** What saving wrote to the program's bundle (a build from a checkout): its files, and how its Wrappfile now gives
 *  the app the first design. Nothing is committed. */
function BundleSaved({ bundle, result }: { bundle: string; result: { saved?: SavedToBundle; lines?: { lines: string[]; change: string }; error?: string } }) {
  const { saved, lines, error } = result;
  const how = lines?.change === "unchanged" ? "already gives the app the first design"
    : lines?.change === "added" ? "now gives the app the first design (lines added)"
    : lines?.change === "replaced" ? "now gives the app the first design, instead of its module's icon"
    : lines ? "now gives the app the first design (its icon lines updated)" : null;
  return (
    <div className="col" style={{ gap: 6, marginTop: 6 }}>
      <b>Also saved to {bundle}</b>
      {saved && <div className="notice">Wrote {saved.files.join(", ")}{saved.allowPathAdded ? ", and added \"assets/\" to the manifest's allow-paths" : ""}.</div>}
      {saved?.manifestNote && <div className="notice bad">Still to do: {saved.manifestNote}.</div>}
      {how && <div className="notice">Its Wrappfile {how}:<pre className="mono" style={{ margin: "4px 0 0" }}>{lines?.lines.join("\n")}</pre></div>}
      {saved?.wrappfileLines && !lines && <>
        <p className="muted" style={{ margin: 0 }}>Its Wrappfile has several stages: add these lines to the one that launches it, after its LAUNCH:</p>
        <pre className="mono">{saved.wrappfileLines.join("\n")}</pre>
      </>}
      {error && <div className="notice bad">Couldn't save to the bundle: {error}</div>}
      <p className="faint" style={{ margin: 0 }}>Check the changes with git, then commit them yourself.</p>
    </div>
  );
}

/** A saved file's path from the lab's data folder on ("data/programs/…"), the rest in its tooltip. */
const tail = (p: string) => { const i = p.indexOf("/data/programs/"); return i >= 0 ? p.slice(i + 1) : p; };
