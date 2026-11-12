# The icon document

Everything in stage 3 is a **document**: an editable icon design. Suggestions are documents a treatment
generated, the editor edits a document, a pin is a frozen document, and the history is documents linked by
`parent`. The engine turns a document into an Icon Composer `.icon` (one PNG per layer, `icon.json` for groups,
glass and fill) and renders it with `ictool`.

The JSON below is the wire and storage format (schema 1). Colours are `#rrggbb`. Canvas units are fractions of the
1024-point icon canvas: `x: 0.5` is the centre, `width: 1` is the full canvas.

```ts
type Doc = {
  schema: 1
  id: string                 // uuid
  parent: string | null      // the document this one was derived from (history / branching)
  name: string               // "Lifted", "Lifted (edited)", …
  program: string            // program slug
  origin?: { treatment: string; params: SuggestionParams }   // set on generated suggestions
  fill: Fill                 // the icon's background (Icon Composer "fill")
  groups: Group[]            // FRONT first, as in icon.json. At most 4 (Icon Composer's limit).
  created: string            // ISO date
}

type Fill = { kind: "gradient" | "solid" | "none"; color: string; dark?: string }
// "gradient" is Icon Composer's automatic gradient from `color`. `dark`: the dark appearance's colour
// (default: color darkened to 45 %).

type Group = {
  id: string
  name: string
  hidden?: boolean
  glass: Glass
  layers: Layer[]            // FRONT first
}

type Glass = {
  specular: boolean          // default true
  shadow: number             // the shadow's opacity 0…1 (Icon Composer's percent)
  shadowKind?: "none" | "neutral" | "chromatic"   // Icon Composer's Off / Neutral / Chromatic ("layer-color");
                             // absent: neutral when shadow > 0, else none
  lighting?: "individual" | "combined"            // Liquid Glass mode: each layer its own glass, or the group as one
                             // (absent: individual)
  translucency: number | null // null = off, else 0…1
  blur: number | null        // blur-material, null = off
}

type Layer = {
  id: string
  name: string
  role?: Role                // what the layer is, so "adjust all" and the UI can find it
  hidden?: boolean
  opacity: number            // 0…1
  content: Content
  transform: Transform       // where the content sits on the canvas
  mask?: Mask | null         // clips the layer (applied in canvas space, after the transform)
}

type Role = "subject" | "logo" | "backdrop" | "pattern" | "frame" | "icon" | "disc" | "decoration"

type Transform = {
  x: number; y: number       // the content's centre, canvas units
  width: number              // the content's width, canvas units; height follows its aspect
  rotation: number           // degrees, clockwise
}
// A shape layer (below) is drawn on the whole canvas, so its natural transform is
// { x: .5, y: .5, width: 1, rotation: 0 }.

type Content =
  | { kind: "image"
      asset: string           // a media id of the program (see api.md)
      cutout: boolean         // cut to the image's subject mask (and its own alpha), cropped to the cut-out
      crop?: [number, number, number, number] | null   // x, y, w, h in 0…1 of the (cut-out) image
      smoothing: "smooth" | "pixel"                    // pixel = nearest-neighbour scaling (pixel art)
      effects: Effect[] }     // applied in order, in the content's own space
  | { kind: "shape"; shape: Shape }

type Shape =
  | { type: "solid"; color: string }
  | { type: "gradient"; from: string; to: string; angle: number }       // linear, degrees
  | { type: "pattern"; pattern: "stripes" | "dots" | "grid" | "checker" | "rays"; a: string; b: string }
  | { type: "bands"; colors: string[] }                                  // horizontal stripes, top first
  | { type: "window"; frame: string; bar: string }                       // retro window, pane transparent
  | { type: "crt"; bezel: string }                                       // CRT bezel, screen transparent
  | { type: "disc-rims"; color: string }                                 // the hub and edge highlights of a CD
  | { type: "text"; text: string; font: string; color: string; size?: number }  // e.g. a monogram letter, centred; size = share of the canvas (0.86)
  | { type: "rounded-rect"; rect: [number, number, number, number]; radius: number; color: string }  // canvas units
  | { type: "circle"; radius: number; color: string }                    // centred

type Effect =
  | { op: "silhouette"; color: string }                // every visible pixel becomes the colour
  | { op: "outline"; color: string; width: number }    // a border behind (die-cut sticker); width in canvas units
  | { op: "feather"; softness: number; offset: number } // the edge fades out across `softness`, centred on the edge
                                                      // moved by `offset` (negative in, positive out); canvas units.
                                                      // Moved out, a cut-out shows the picture it was cut from (as
                                                      // far as that picture goes); anything else carries its edge
                                                      // colours out.
  | { op: "halftone"; ink: string; cell: number; angle: number }   // cell in canvas units
  | { op: "tone"; level: 0 | 1 | 2; color: string }    // screenprint: pixels in this third of the brightness range
  | { op: "gradient-map"; dark: string; light: string }
  | { op: "blur"; radius: number }                     // canvas units
  | { op: "autocontrast" }
  | { op: "edges"; color: string }                     // traced edges as a glowing line
  | { op: "riso"; ink: string; band: "dark" | "mid"; offset: [number, number] }
  | { op: "posterize"; colors: number }                // flat enamel fills
  | { op: "scanlines" }
  | { op: "tint"; color: string; amount: number }      // blend towards a colour
  | { op: "key"; tolerance: number }                   // the corners' colour made transparent (a logo on a plain ground)
  | { op: "flatten"; color: string }                   // transparency over a plain colour

type Mask =
  | { kind: "shape"; shape: Shape; transform: Transform; invert?: boolean }   // e.g. a disc ring, a letter
  | { kind: "image"; asset: string; cutout: true; crop?: [number, number, number, number] | null;
      transform: Transform }                           // another image's silhouette (double exposure)
  | { kind: "ring"; outer: number; inner: number }     // centred circle with a hole, radii in canvas units
  | { kind: "linear-fade"; angle: number; start: number; end: number }  // opaque→transparent along angle

type SuggestionParams = {
  primary?: string; secondary?: string; background?: string
  scale?: number; dx?: number; dy?: number            // the subject's
  logoScale?: number
  dx2?: number; dy2?: number                          // the second element's move
  angle?: number; pattern?: string; cell?: number; offset?: number; letter?: string
  roles?: Partial<Record<"subject" | "fill" | "disc" | "logo" | "icon", string>>   // media ids
}
```

## How it renders

- **In the browser (sketch, instant):** each layer's content is fetched as a PNG from the engine
  (`/api/render/content`), effects already applied, at the pixel width it will show at. The browser places it with
  the transform (Konva), applies the mask (also a PNG from the engine) with `destination-in`, draws the fill as a
  plain gradient, and stacks groups back to front. Moving or rotating never needs the engine; scaling past the
  rendered size asks for a sharper copy.
- **The real thing (Liquid Glass):** `/api/render/icon` writes the `.icon` (each layer flattened to a 1024 PNG in
  canvas space) and runs `ictool` for an appearance and size. Cached by a hash of the document's visual parts, the
  assets' hashes and the engine's revision.

## Rules

- Optional keys (`parent`, `crop`, `translucency`, `blur`, `mask`, `hidden`, …) may be left out instead of written as
  `null`; readers treat a missing key and `null` alike.

- At most 4 groups. A layer belongs to exactly one group; the editor may move layers between groups.
- Editing never mutates a pinned document: a pin is a snapshot, and the editor works on a copy whose `parent` is
  the document it came from.
- Unknown keys are kept when a document is read and written (Icon Composer 2 adds per-layer refraction, and later
  schema versions will add more).

## Masks are effects (2026-11-08)

A mask is an effect: `{ op: "mask", mask: Mask, lock: "canvas" | "image", invert?: boolean }`, anywhere in an image
layer's `effects` (so masks stack, and order matters: mask then blur softens the edge; blur then mask keeps it sharp).

- `lock: "canvas"` — the mask stays put on the canvas while the layer moves (a disc's ring, a window's pane, a
  monogram's letter). Its coordinates are canvas units, as `Layer.mask` was.
- `lock: "image"` — the mask moves, scales and turns with the picture; its 0…1 coordinates are the picture's own box
  (a silhouette from another picture usually wants this).

`POST /api/render/content` takes the layer's `transform` too; the engine uses it only when a canvas-locked mask is in the
effects (and only then does the render depend on the layer's place — the UI can apply a canvas-locked mask that is
the *last* effect itself, so moving such a layer stays instant). Treatments now make their masks this way (last,
canvas-locked). `Layer.mask` still renders, for documents made before; editing should move it into the effects.
