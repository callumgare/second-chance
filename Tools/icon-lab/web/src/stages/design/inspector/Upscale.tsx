// For a picture layer: a warning when it's shown larger than its pixels, and upscaling (Real-ESRGAN ×4 for a scan
// or photo, whole-number scaling for pixel art) that swaps the layer to the upscaled copy, with a switch back.
import { useEffect, useState } from "react";
import { api, type Layer } from "../../../api";
import { useApp } from "../../../state/app";
import { partUrl } from "../../../parts/shim";
import { Seg } from "../../../components/controls";
import { editLayer } from "../actions";

const ICON_PX = 1024;

export function UpscaleSection({ program, layer }: { program: string; layer: Layer }) {
  const c = layer.content;
  const asset = c.kind === "image" ? c.asset : "";
  const base = asset.replace(/@(x4|px4)$/, "");
  const upNow = asset !== base;
  const [info, setInfo] = useState<{ width: number; height: number; pixelArt: boolean } | null>(null);
  const [mode, setMode] = useState<"photo" | "pixel">("photo");
  const [up, setUp] = useState<{ asset: string; url: string; width: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [before, setBefore] = useState<string | null>(null);
  const media = useApp((s) => s.media);

  useEffect(() => {
    let live = true;
    setInfo(null); setUp(null);
    api.assetInfo(program, base).then((i) => { if (live) { setInfo(i); setMode(i.pixelArt ? "pixel" : "photo"); } }).catch(() => { /* no warning without its size */ });
    return () => { live = false; };
  }, [program, base]);

  // The "before" crop: the part's own picture (or the whole one).
  useEffect(() => {
    let live = true;
    const [mid, pid] = base.split("/");
    const m = media.get(mid);
    const p = m?.parts?.find((x) => x.id === (pid ?? "whole"));
    if (m && p) partUrl(m, p, 1024).then((u) => { if (live) setBefore(u); }).catch(() => {});
    else if (m) setBefore(m.url);
    return () => { live = false; };
  }, [base, media]);

  // An upscaled copy already in use: fetch its URL (cached by the engine) for the "after" crop.
  useEffect(() => {
    if (!upNow || up?.asset === asset) return;
    let live = true;
    api.upscale(program, base, asset.endsWith("@px4") ? "pixel" : "photo").then((r) => { if (live) setUp(r); }).catch(() => {});
    return () => { live = false; };
  }, [upNow, asset, base, program, up?.asset]);

  if (c.kind !== "image" || !info) return null;
  const shownPx = layer.transform.width * ICON_PX;
  const factor = shownPx / info.width;
  const enlarged = factor > 1.25;
  const run = async () => {
    setBusy(true);
    try {
      const r = await api.upscale(program, base, mode);
      setUp(r);
      editLayer(layer.id, (l) => { if (l.content.kind === "image") l.content.asset = r.asset; });
    } catch (e) { useApp.getState().say("Couldn't upscale: " + (e as Error).message, "error"); }
    finally { setBusy(false); }
  };
  const use = (which: "original" | "upscaled") => editLayer(layer.id, (l) => {
    if (l.content.kind === "image") l.content.asset = which === "original" ? base : up?.asset ?? asset;
  });

  return (
    <>
      {enlarged && !upNow && (
        <div className="warnbox"><b>Enlarged {factor.toFixed(1)}× past its pixels.</b> It's {info.width}×{info.height} px, shown {Math.round(shownPx)} px wide on the 1024 canvas, so it will look soft. Upscale it, or pick a larger copy if one was found.</div>
      )}
      {(enlarged || upNow) && <>
        <div className="sec">Upscale</div>
        <div className="row" style={{ flexWrap: "wrap", gap: 6 }}>
          <Seg value={mode} options={["photo", "pixel"] as const} labels={{ photo: "Photo / scan ×4", pixel: "Pixel art ×4" }} onChange={setMode} />
          <button className="btn small primary" disabled={busy || (upNow && up?.asset === base + (mode === "pixel" ? "@px4" : "@x4"))} onClick={() => void run()}>
            {busy ? <><span className="spin" /> Upscaling…</> : "Upscale"}
          </button>
        </div>
        <p className="faint note">{mode === "photo" ? "Real-ESRGAN, a few seconds the first time." : "Whole-number scaling: every pixel stays hard."} The layer keeps the original; switch between them below.</p>
        {(up || upNow) && <>
          <div className="kv wide"><span>Use</span>
            <Seg value={upNow ? "upscaled" : "original"} options={["original", "upscaled"] as const} labels={{ original: "Original", upscaled: "Upscaled" }} onChange={use} />
          </div>
          <div className="ba">
            <figure><Crop url={before} pixel={false} /><figcaption>Original · {info.width} px</figcaption></figure>
            <figure><Crop url={up?.url ?? null} pixel={(up?.asset ?? asset).endsWith("@px4")} /><figcaption>Upscaled ×4 · {up ? up.width : info.width * 4} px</figcaption></figure>
          </div>
        </>}
      </>}
    </>
  );
}

/** A close-up of the middle of a picture, to compare the edges. */
function Crop({ url, pixel }: { url: string | null; pixel: boolean }) {
  return <span className="crop checker" style={url ? { backgroundImage: `url("${url}")`, imageRendering: pixel ? "pixelated" : "auto" } : undefined} />;
}
