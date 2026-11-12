// Dropping things into the page: pictures from the computer (Finder) and the Add section's tiles. Pictures from the
// computer are added to Gather as Your files pictures (picked, at the top of the scale) through the engine; dropped
// on the design, each also becomes a layer.
import { api, type Layer, type Media } from "../api";
import { newImageLayer, newPartLayer, newShapeLayer } from "./doc";
import { useApp } from "../state/app";

export const PART_DRAG = "application/x-iconlab-part";
export const SHAPE_DRAG = "application/x-iconlab-shape";

const PICTURE = /\.(png|jpe?g|gif|bmp|webp|tiff?|ico|icns|heic)$/i;

/** Whether a drag carries files from the computer (their names aren't known until the drop). */
export const hasFiles = (dt: DataTransfer) => dt.types.includes("Files");
/** Whether a drag carries anything the design takes: files, or a tile from the Add section. */
export const designDrag = (dt: DataTransfer) => hasFiles(dt) || dt.types.includes(PART_DRAG) || dt.types.includes(SHAPE_DRAG);

/** The pictures among the dropped files. */
export function droppedPictures(dt: DataTransfer): File[] {
  return [...dt.files].filter((f) => f.type.startsWith("image/") || PICTURE.test(f.name));
}

/** Adds each dropped picture to the program; the pictures added (those that failed are said). */
export async function addDroppedPictures(slug: string, files: File[]): Promise<Media[]> {
  const app = useApp.getState();
  const added: Media[] = [];
  const failed: string[] = [];
  for (const f of files) {
    try {
      const m = await api.uploadPicture(slug, f);
      useApp.getState().upsertMedia(slug, m);
      added.push(m);
    } catch (e) {
      failed.push(`${f.name}: ${(e as Error).message}`);
    }
  }
  if (failed.length) app.say(`Couldn't add ${failed.length === 1 ? failed[0] : `${failed.length} pictures (${failed.join("; ")})`}`, "error");
  else if (added.length) app.say(`Added ${added.length === 1 ? added[0].name : `${added.length} pictures`} to your files, picked`);
  return added;
}

/** The layers a drop on the design makes: a tile's part or shape, or each dropped picture (added to the program
 *  first). `at` places image layers (canvas units, 0…1); a dropped shape fills the canvas as one added by a click. */
export async function layersFromDrop(slug: string, dt: DataTransfer, at?: { x: number; y: number }): Promise<Layer[]> {
  const shape = dt.getData(SHAPE_DRAG);
  if (shape) {
    const colours = useApp.getState().program?.colours ?? {};
    return [newShapeLayer(shape as never, colours.striking, colours["second striking"])];
  }
  const key = dt.getData(PART_DRAG);
  if (key) {
    const [mid, pid] = key.split("/");
    const m = useApp.getState().media.get(mid);
    const p = m?.parts?.find((x) => x.id === pid);
    return m && p ? [newPartLayer(m, p, at)] : [];
  }
  const pictures = droppedPictures(dt);
  if (!pictures.length) {
    if (hasFiles(dt)) useApp.getState().say("Only pictures can be dropped here", "error");
    return [];
  }
  const added = await addDroppedPictures(slug, pictures);
  // several at once fan out a little, so they don't sit exactly on top of each other
  return added.map((m, i) => newImageLayer(m, at ? { x: at.x + i * 0.04, y: at.y + i * 0.04 } : undefined));
}
