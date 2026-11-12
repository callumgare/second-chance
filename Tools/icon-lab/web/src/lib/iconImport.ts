// Icon Composer `.icon`s dropped from the Finder onto the pins (Design's strip, Review): each one's pictures are
// added to Gather as Your files pictures, and the icon is made again from them as a design, pinned. A `.icon` is a
// folder, so its files are read through the drop's entries (a folder's File has no bytes).
import { api } from "../api";
import { useApp } from "../state/app";
import { useDesign } from "../state/design";
import { uid } from "./doc";
import { docFromIcon, imageNames, type IconJSON, type IconPicture } from "./iconDoc";

/** The `.icon` folders a drop carries. Read during the drop event: its items are gone once it returns. */
export function droppedIcons(dt: DataTransfer): FileSystemDirectoryEntry[] {
  const out: FileSystemDirectoryEntry[] = [];
  for (const item of [...dt.items]) {
    if (item.kind !== "file") continue;
    const entry = item.webkitGetAsEntry?.();
    if (entry?.isDirectory && /\.icon$/i.test(entry.name)) out.push(entry as FileSystemDirectoryEntry);
  }
  return out;
}

/** Whether a drag could be bringing `.icon`s (its files' names aren't known until the drop). */
export const mayBeIcons = (dt: DataTransfer) => dt.types.includes("Files");

const children = (dir: FileSystemDirectoryEntry) => new Promise<FileSystemEntry[]>((resolve, reject) => {
  const reader = dir.createReader();
  const all: FileSystemEntry[] = [];
  // readEntries gives them in batches, then an empty one
  const next = () => reader.readEntries((batch) => { if (!batch.length) resolve(all); else { all.push(...batch); next(); } }, reject);
  next();
});
const fileOf = (entry: FileSystemFileEntry) => new Promise<File>((resolve, reject) => entry.file(resolve, reject));

/** An SVG drawn into a PNG big enough for the icon, and its size in points (what Icon Composer places it by). */
async function svgToPNG(file: File): Promise<{ png: File; width: number; height: number }> {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const width = img.naturalWidth || 1024, height = img.naturalHeight || 1024;
    const k = Math.max(1, 2048 / Math.max(width, height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(width * k); canvas.height = Math.round(height * k);
    canvas.getContext("2d")?.drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, "image/png"));
    if (!blob) throw new Error(`couldn't draw ${file.name}`);
    return { png: new File([blob], file.name.replace(/\.svg$/i, ".png"), { type: "image/png" }), width, height };
  } finally { URL.revokeObjectURL(url); }
}

/** Adds one `.icon`'s pictures to the program and pins the design it makes. The design's name, or throws. */
async function importIcon(slug: string, dir: FileSystemDirectoryEntry): Promise<string> {
  const name = dir.name.replace(/\.icon$/i, "");
  const entries = await children(dir);
  const jsonEntry = entries.find((e) => e.isFile && e.name === "icon.json") as FileSystemFileEntry | undefined;
  if (!jsonEntry) throw new Error(`${dir.name} has no icon.json`);
  let icon: IconJSON;
  try { icon = JSON.parse(await (await fileOf(jsonEntry)).text()) as IconJSON; }
  catch { throw new Error(`${dir.name}'s icon.json can't be read`); }
  const assetsDir = entries.find((e) => e.isDirectory && e.name === "Assets") as FileSystemDirectoryEntry | undefined;
  const assets = new Map((assetsDir ? await children(assetsDir) : []).filter((e) => e.isFile).map((e) => [e.name, e as FileSystemFileEntry]));

  const pictures = new Map<string, IconPicture>();
  for (const imageName of imageNames(icon)) {
    const entry = assets.get(imageName);
    if (!entry) continue;   // said below, as its layer is left out
    let file = await fileOf(entry);
    let points: { width: number; height: number } | null = null;
    if (/\.svg$/i.test(imageName)) { const s = await svgToPNG(file); file = s.png; points = s; }
    // named after the icon, so Gather says where the picture came from
    const m = await api.uploadPicture(slug, new File([file], `${name} › ${file.name}`, { type: file.type || "image/png" }));
    useApp.getState().upsertMedia(slug, m);
    pictures.set(imageName, { asset: m.id, width: points?.width ?? m.width, height: points?.height ?? m.height, pixelArt: m.analysis?.pixelArt });
  }
  const { doc, missing } = docFromIcon(icon, { name, program: slug, pictures, newId: uid });
  if (!doc.groups.length) throw new Error(`${dir.name} has no pictures Icon Lab can use`);
  await useDesign.getState().pinNew(doc);
  if (missing.length) useApp.getState().say(`${name}: left out ${missing.length === 1 ? `the layer showing ${missing[0]}` : `${missing.length} layers`}, as the icon doesn't have ${missing.length === 1 ? "its picture" : "their pictures"}`, "error");
  return name;
}

/** The drop handler for a list of pins: imports each dropped `.icon`. True if the drop was for it. */
export function dropIconsOnPins(slug: string, e: React.DragEvent): boolean {
  if (!mayBeIcons(e.dataTransfer)) return false;
  e.preventDefault();
  const icons = droppedIcons(e.dataTransfer);
  if (!icons.length) { useApp.getState().say("Only Icon Composer icons (.icon) can be dropped on the pins", "error"); return true; }
  if (useApp.getState().transport === "mock") { useApp.getState().say("Bringing in an icon needs the engine", "error"); return true; }
  void (async () => {
    for (const dir of icons) {
      try { await importIcon(slug, dir); }
      catch (err) { useApp.getState().say(`Couldn't bring in ${dir.name}: ${(err as Error).message}`, "error"); }
    }
  })();
  return true;
}
