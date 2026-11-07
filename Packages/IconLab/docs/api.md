# Engine API

The engine (`IconLabKit`) answers this API through `IconLabAPI` (`Packages/IconLab`), which has no web server in
it: a host hands it each request (`IconLabAPI.handle`) and passes on its events (`IconLabAPI.events()`). The dev
server (`Tools/icon-lab/server`) is one host: it serves the API, the web UI and `/api/events` on
`http://127.0.0.1:8767`. Paths other than the API's are the web UI's files. JSON in and out. Documents are as in
`document.md`.

## Programs and media

`GET /api/programs` → `ProgramSummary[]` (recent first)

```ts
type ProgramSummary = { slug: string; title: string; year?: number; thumb?: string; media: number; pins: number; updated: string }
```

`GET /api/programs/:slug` → `Program`

```ts
type Program = {
  slug: string; title: string; year?: number
  media: Media[]
  colours: Record<string, string>   // named colour options ("striking", "complement", …) from the best subject image
  colourOrder: string[]             // the names in the order to show them
  roles: { subject?: string; fill?: string; disc?: string; logo?: string; icon?: string }  // default media per role
}

type Media = {
  id: string                    // stable, URL-safe
  name: string                  // original file name
  kind: MediaKind; kindConfidence: number
  source: string                // "Your files", "LaunchBox", "Wikipedia", …
  sourceUrl?: string
  provenance?: string           // for extracted images: "disc.iso › SETUP.EXE › … › 32×32"
  width: number; height: number
  url: string                   // full image (PNG or original)
  thumb: string                 // ≤ 256 px
  cutout?: string               // the subject cut out, cropped (PNG), when there's a mask
  mask?: string                 // the subject mask (L8 PNG) at the image's size
  picked: boolean
  analysis: {
    subject: boolean; subjectBox?: [number, number, number, number]   // 0…1
    flatSides: ("left" | "right" | "top" | "bottom")[]
    text: string[]; textFraction: number
    busyness: number            // 0…1
    palette: string[]           // most common first
    circle?: [number, number, number]   // a disc's centre x, y and radius, 0…1
    pixelArt?: boolean
    scores: Record<string, number>      // silhouette, fill, disc, logo, scene
  }
  suitability: number           // 0…5
  cutoutSize?: [number, number] // the cut-out's pixel size, once it has a mask
}

type MediaKind = "box-front" | "box-back" | "box-spine" | "disc" | "logo" | "icon" | "title-screen" | "screenshot"
  | "banner" | "manual" | "cutout" | "art" | "other"
```

`PATCH /api/programs/:slug/media/:id` `{ picked?: boolean, kind?: MediaKind }` → `Media`

## Suggestions

`POST /api/programs/:slug/suggestions` `{ params: SuggestionParams, treatments?: string[] }` → `Suggestion[]`

```ts
type Suggestion = { treatment: string; title: string; about: string; uses: string[] /* role names: "subject", "fill", "disc", "logo", "icon" — not media ids; the images it uses are its doc's image layers' assets */; doc: Doc }
```

Generating is cheap (no pixels). Treatments that can't be made from the program's media are left out.

`GET /api/treatments` → `{ key, title, about, uses }[]`

## Rendering

`POST /api/render/content` `{ program, content: Content, pixelWidth: number, canvasWidth: number }`
→ `{ url, width, height, box: [x0, y0, x1, y1] }`
The layer's content with its effects applied, `pixelWidth` wide (capped at 4096). `canvasWidth` is the layer's
`transform.width`: effect sizes are in canvas units, so the engine needs it to turn them into pixels. `box` says where
the PNG sits relative to the content's own box: `[0, 0, 1, 1]` normally, larger when an effect draws outside it (an
outline: e.g. `[-0.05, -0.04, 1.05, 1.04]`). Place the PNG so that the content box (not the PNG) matches the
transform: the content box is `transform.width` wide and `width / (x1 - x0)`… scaled accordingly, and the PNG covers
`box` of it. `url` is cached by hash (`/api/cache/content/<hash>.png`), so asking twice is cheap.

`POST /api/render/shape` `{ program, shape: Shape, size: number }` → `{ url }` (a canvas-space shape, square)

`POST /api/render/mask` `{ program, mask: Mask, size: number }` → `{ url }` (alpha in an L8/RGBA PNG, canvas space,
mask's transform applied, square `size`)

`POST /api/render/icon` `{ doc: Doc, appearance: "light" | "dark" | "tinted" | "clear", size: number }`
→ `{ url, icon }` — the real Liquid Glass render through `ictool` (`size` 16…1024) and the `.icon` it came from.
Slow the first time (0.3–2 s); cached by content. Renders are full bleed (the icon's shape fills the PNG).
With `cachedOnly: true` it answers `404` instead of rendering when there's no cached render.

## Documents, pins and saving

`GET /api/programs/:slug/docs` → `{ docs: Doc[], pins: string[], current: string | null }`
Every document the program has (history), which ids are pinned, and which is open in the editor.

`PUT /api/programs/:slug/docs/:id` `Doc` → `Doc` (create or update; the editor autosaves the current document)

`PUT /api/programs/:slug/current` `{ id }` → `{}`

`POST /api/programs/:slug/pins` `{ id }` or `{ doc }` (saves the doc, then pins it) → `{ pins }`; `DELETE /api/programs/:slug/pins/:id` → `{ pins }`

`POST /api/programs/:slug/save` `{ ids: string[] }` → `{ saved: { id, icon, png }[] }`
Writes each document's `.icon` and a 1024 PNG to `data/programs/<slug>/saved/`.

## Search

`GET /api/sources` → `SourceInfo[]`: every program and media source, then the link-only ones.

```ts
type SourceInfo = { id: string; name: string; state: "ready" | "needsKey" | "linkOnly" | "disabled"
  note?: string        // "needs IGDB_CLIENT_ID and IGDB_CLIENT_SECRET in .env", "local copy", "downloading its database…"
  local: boolean       // answers from a local copy (LaunchBox, TheGamesDB, My Abandonware's sitemap)
  homepage?: string }
```

Local copies download in the background when missing or a week old (jobs in the group `"sources"`); until then the
source is `disabled` with a note. `POST /api/sources/refresh` `{ force?: boolean }` → `SourceInfo[]` starts them now.

`POST /api/search` `{ q }` → `{ id }`. Progress and results stream over `/api/events` as fresh snapshots (at most a few
a second, and always one when it's done); `GET /api/search/:id` → the latest snapshot.

```ts
type SearchEvent = { type: "search"; id: string; q: string
  sources: { id: string; name: string; state: SourceState; note?: string
             running: boolean        // still answering (Wikidata runs last: it looks up the ids the others gave)
             count: number }[]       // hits; for id- and link-only sources, results that link to them
  results: ProgramResult[]           // merged and ranked, best first (at most 40)
  done: boolean }

type ProgramResult = {
  key: string                        // "wikidata:Q…", else the best hit's "source:id"
  title: string; year?: number; platforms: string[]   // "DOS", "Windows 3.x", "Windows", "PC", "Mac OS", "Mac OS X", …
  developer?: string; publisher?: string
  kind?: "game" | "software" | "demo" | "remake" | "compilation" | "expansion"
  thumb?: string                     // the best small picture (LaunchBox box front first)
  ids: Record<string, string>        // every id known; several ids in one value are comma-separated ("155059,466377")
  links: Record<string, string>      // source id → page (link-only sites too: MobyGames, Macintosh Garden, Discmaster…)
  hits: ProgramHit[]                 // what it was merged from
  mergeReasons: string[]             // "“Myst” 1993 (LaunchBox) — same Wikidata item (Q6497116)", "… — title, year and developer match"
  score: number }                    // 0…100

type ProgramHit = { source: string; sourceId: string; title: string; alternateTitles: string[]; year?: number
  platforms: string[]; developer?: string; publisher?: string; kind?: string; thumb?: string; url?: string
  ids: Record<string, string>; summary?: string }
```

Id namespaces in `ids`: `wikidata`, `wikipedia` (page title), `launchbox`, `thegamesdb`, `igdb`, `igdb-slug`,
`steamgriddb`, `screenscraper`, `pcgamingwiki`, `lutris`, `steam`, `gog`, `gog-slug`, `internetarchive`,
`macintoshrepository`, `macintoshgarden`, `myabandonware`, `winworld`, `mobygames`, `mobygames-slug`, `gamefaqs`,
`winehq`, `abandonia`, `oldgamesru`, `abandonwarefrance`, `commonscat`.

`POST /api/programs` `{ result: ProgramResult }` → `ProgramSummary` (201). Makes the program: its slug from the title
(with the year when the slug is taken by another program; the same program again reuses its folder), and
`program.json` with its title, year, ids and platforms. Recent programs are `GET /api/programs`.

## Gathering

`POST /api/programs/:slug/gather` `{ brave?: boolean; sources?: string[]; clear?: boolean }` → `{ jobs: string[] }`

`sources` gathers from just those sources (ids; Brave included when named). With `clear: true` (and `sources`), every
picture those sources found before is removed first (files, masks, parts, picks and all) and
`{ type: "media-removed", program, ids }` is sent, so the source gathers again from nothing: "Clear and gather again".
The source id `"files"` is "Your files": gathering it again scans every path scanned before (that's still there)
as `extract` does; with `clear`, its pictures and the old scans are removed first. Its scan jobs carry `source: "files"`.
`GET /api/programs/:slug/scans` → `{ scan, path, at }[]`, newest first: what has been scanned (scans from before
paths were recorded aren't listed, so "Your files" from them can be cleared but not scanned again).

Queues a job per ready media source (group `"gather"`, titled "Gather · LaunchBox" and so on). Each finds the
program's pictures there (by the ids in `program.json`, else by its title), downloads a small copy of each new one (the
source's thumbnail, else the image itself up to 20 MB), adds it, sends `{ type: "media", program, media }`, and queues
the cheap analysis (which sends another when it's done). Pictures already in the program (same `remote.url`) are
skipped, so gathering again only adds what's new. Brave image search is paid per search, so it only runs with
`brave: true`. When every source is done, a job "Find duplicate pictures" compares the small copies (a dHash) and sets
`duplicateOf` on every copy of the same art but the best one (the largest the source offers, then the better source).

Every `Media` has `link?: { url, kind: "page" | "search" | "home", label }`: where to see it at its source — the page
it came from when the source gave one, else a search there for the program, else the source's home page (`label` is
the source's name). Pictures from your files have none.

A gathered `Media` has `source` (the source's name), `sourceUrl` (its page there), `provenance`
(`"LaunchBox › Box - Front"`), and `remote`:

```ts
type RemoteMedia = { source: string        // source id
  url: string                               // the largest copy the source offers
  thumbUrl?: string                         // the small copy that was downloaded, if the source has one
  kind?: MediaKind; sourceLabel?: string    // what the source called it ("Box - Front", "Clear Logo", "wheel-hd")
  width?: number; height?: number           // of `url`, when known
  region?: string; title?: string; pageUrl?: string; license?: string }
```

When the source labels its pictures reliably (LaunchBox, ScreenScraper, SteamGridDB, IGDB, Steam, GOG, Wikidata,
TheGamesDB, Lutris, PCGamingWiki) the kind is kept (`kindSet`); otherwise it's a first guess that analysis replaces.
ScreenScraper's URLs are stored without credentials: download them through `Catalog.downloadURL(_:)`.

## Events

`GET /api/events` (WebSocket, from an HTTP host; `IconLabAPI.events()` in Swift) → a stream of JSON messages:

```ts
type Event =
  | { type: "job"; job: Job }                         // a job started, progressed or finished
  | { type: "media"; program: string; media: Media }  // new or updated media (analysis finished, hi-res arrived)
  | { type: "media-removed"; program: string; ids: string[] }   // media removed (a source cleared)
  | { type: "render"; key: string; url: string }      // a requested icon render is ready
  | SearchEvent                                       // a search's progress (see Search)

type Job = { id: string; program?: string; title: string; state: "queued" | "running" | "done" | "failed"
  progress: number /* 0…1 */; eta?: number /* seconds */; detail?: string; group?: string }
```

`GET /api/jobs` → `Job[]` (for a page that connects late).

## Stage 2: picks, hi-res, deep analysis and your files

Media gains these fields (all optional):

```ts
type Media = { …
  remote?: RemoteMedia          // where it came from online: { source, url (largest copy), thumbUrl, kind, sourceLabel,
                                //   width, height, region, title, pageUrl, license }
  hires?: "queued" | "running" | "done" | "failed"   // the hi-res download + deep analysis for a picked image
  duplicateOf?: string          // same art as that media id (fold it under the best copy)
  derivedFrom?: string          // made from that media id by the deep analysis (straightened, trimmed, its title)
  deep?: {                      // the deep tier, on picked images
    aesthetics?: number; utility?: boolean        // Vision's aesthetics score, and whether it's a "utility" picture (a scan)
    faces?: number; faceBoxes?: number[][]
    rectangle?: number[][]                       // a box/scan's corners (TL, TR, BR, BL), 0…1
    trim?: [x, y, w, h]                          // pixels inside a plain border
    titleBox?: [x, y, w, h]                      // where the program's title is, 0…1
    legibility?: number                          // 0…1: how well the cut-out reads at 32 and 16 px
    paletteRoles?: { dominant, accent, background, ink, paper }
    accentContrast?: number                      // WCAG ratio, accent on background
  }
}
```

`POST /api/programs/:slug/media/:id/pick` `{ picked }` → `Media`. Picking queues the hi-res download (when a larger
copy exists online) and the deep analysis (a job, group "hires"); `media` events report each step. `PATCH … {picked}`
does the same.

`POST /api/programs/:slug/media/:id/deepen` → `{}` (run the deep analysis again)

`GET /api/fs?path=<dir>&hidden=1` → `{ path, parent, entries: FSEntry[], places: FSEntry[] }` — our own file browser
(real paths, no upload).

```ts
type FSEntry = { name: string; path: string; dir: boolean; size?: number
  type: "wrapp" | "app" | "disc-image" | "installer" | "archive" | "program" | "image" | "folder" | "other"; hint?: string }
```

`POST /api/programs/:slug/extract` `{ path }` → `{ scan }` — finds every image in a wrapp, installer, disc image or
folder with WrappKit's `ProgramImages`, in the engine's process (a job, group "scan"; cancelling the job stops the
crawl). Its progress streams as events `{ type: "scan", program, scan, event }`, where `event` is one of the
extraction's JSON lines, as `icon-extract` writes them (`node`, `image`, `skip`, `progress`, `done` — see the repo's
docs/program-images.md) — enough to draw the unpacking tree live. The images it finds arrive as `media` events
(source "Your files", with `provenance`).

## The host's programs

What the host knows of programs (Second Chance: its bundles and its built wrapps), passed to the engine as
`LabHostInfo` and `LabTools.builtApps`. A host with none answers with empty lists.

`GET /api/host` → `{ knownPrograms: number; wrapps: boolean; saveToBundle: boolean }` — what it offers.
`saveToBundle` is true only when the host named a `Bundles/` folder that may be written (a Debug build of Second
Chance, its checkout's).

`GET /api/known-programs` → `{ id, title, slug, year?, platforms, developer?, publisher?, opened }[]`, by title: the
programs the host has bundles for (`id` is the bundle id, `freeware/skifree`; `slug` the program it opens as,
`freeware--skifree`; `opened` whether that program exists yet).

`POST /api/known-programs/open` `{ id }` → `{ slug }`, 201 when the program was made, 200 when it was there. Its
`program.json` records the bundle as `bundleId`, which `GET /api/programs` and `GET /api/programs/:slug` give too.

`GET /api/wrapps` → `{ name, path, bundleIdentifier?, modified? }[]`, newest first: the apps in the host's built-apps
folder, which "Add from files" offers to scan with one click.

`POST /api/programs/:slug/try-icon` `{ id?: string; doc?: Doc; wrapp: string; anywhere?: boolean }` →
`{ wrapp, icns }` — puts a saved design (`id`) or `doc` on a built app as its `APP --icon` would: compiled to
`Contents/Resources/<slug>.icns` (actool), named by `CFBundleIconFile` with `CFBundleIconName` removed, the app signed
again ad hoc and touched, so the Dock and Finder show it. Only apps in the built-apps folder, unless `anywhere`
(the person chose another app themselves); otherwise 400.

`POST /api/programs/:slug/save-to-bundle` `{ ids: string[] }` → `{ bundle, files, allowPathAdded, manifestNote?,
wrappfileLines?, canAddLines }` — writes the designs, in order, to the program's bundle (its `bundleId`) as
`assets/<name>.icon`, `<name>-2.icon`, … (`<name>` the bundle folder's name), each with its compiled `.icns`, and adds
`"assets/"` to the manifest's `allow-paths` (a one-line list, or a new line after the title; otherwise
`manifestNote` says what to do). When the Wrappfile has no `APP --icon`, `wrappfileLines` are the `COPY` and `APP`
lines that give the app the first icon; `canAddLines` says whether the engine can add them itself (the Wrappfile has
one stage). Nothing is committed. 400 when saving isn't available or the program isn't from a bundle.

`POST /api/programs/:slug/save-to-bundle/lines` → `{ added: string[] }` — adds those lines after the stage's last
`LAUNCH`.

`POST /api/jobs/:id/cancel` → `{ cancelled: boolean }` — a queued job never starts (it ends `failed`, detail
`"cancelled"`); a running one's task is cancelled, which stops a scan or a download.

## Models

On-device machine-learning models (Core ML). None ships with the lab: each is downloaded the first time something
needs it (or when asked here), into `data/models/<name>/`, checked against the size and SHA-256 in
`Sources/IconLabKit/Models/ModelManifest.swift`, compiled once and kept. A download is a job (group
`models`), so the activity panel shows it with its progress; it starts at once rather than queueing, since analysis
jobs may be waiting on it.

| Name | What it's for | Size | Licence |
| --- | --- | --- | --- |
| `mobileclip-s2-image` | an image's kind (zero-shot) and its embedding, for "similar images" and duplicates | 72 MB | Apple ML Research Model licence (research and personal use only) |
| `mobileclip-s2-text` | the kind descriptions' embeddings, and text search over images | 127 MB | the same |
| `clip-tokenizer` | CLIP's vocabulary and merges, for the text model | 1.4 MB | MIT |
| `birefnet-lite` | a subject mask, as a second opinion on Vision's | 95 MB | MIT |
| `realesrgan-x4plus` | ×4 upscaling of small scans and low-resolution box art (not pixel art) | 31 MB | BSD-3-Clause |

`GET /api/models` → `ModelStatus[]`

```ts
type ModelStatus = { name: string; purpose: string; size: number /* bytes to download */; licence: string
  source: string /* its page */
  state: "absent" | "downloading" | "compiling" | "ready" | "failed"
  progress?: number /* 0…1, while downloading */; error?: string /* when failed */ }
```

`POST /api/models/:name/download` → `202 ModelStatus` — fetch a model now rather than when first needed. Harmless if
it's already here or downloading (several callers share one download). An interrupted download resumes where it
stopped.

`DELETE /api/models/:name` → `ModelStatus` — remove a model's files (it downloads again when next needed); `500` while
it's downloading.

Every change of state is also an event: `{ type: "model"; model: ModelStatus }`.

## Parts (rotation, kinds, cut-outs) — 2026-11-07 revision

Every media item has **parts**: the whole picture (always first, id `whole`) and anything cut or cropped out of it.
Picking happens per part; a media item's `picked` is true when any part is picked (the grid's circle is empty / half
/ full from `parts`). Kinds are only set when we're confident: `kind` is `"unknown"` otherwise, and the UI shows no
kind at all for it ("No kind" filter).

```ts
type Media = { …
  kind: MediaKind | "unknown"; kindSource?: "you" | "source" | "analysis"
  kindGuesses?: { kind: MediaKind; p: number }[]   // MobileCLIP's best three, for the inspector
  sourceLabel?: string                             // what the source called it ("Cart - Front")
  rotation: 0 | 90 | 180 | 270                     // the picture's own turn (clockwise), applied to every part
  rotationAuto?: boolean; rotationWhy?: string     // turned automatically, and why (or why not)
  parts: Part[]
}

type Part = {
  id: string                // "whole", "subject", "inst-2", "title", "rect", "disc", "frame-<n>", or "p-<id>" for yours
  name: string              // "Whole picture", "Freddi and friends", "Title “SkiFree”", …
  source: "whole" | "subject" | "instance" | "text" | "rectangle" | "disc" | "region" | "sam" | "frame"
                            // "frame": a frame of a video (a picture of its own, not a crop of the whole; its `box` is
                            // [0,0,1,1]). A scanned video is one media item: every frame is a "frame" part, in time
                            // order, the best one included (`deep.bestFrame` names it; `deep.frames` counts them).
                            // The whole is a copy of the best frame and is what cut-outs (analysis, SAM) come from;
                            // the page shows frames, not the whole, for a video.
  frame?: string            // a cut-out from another frame: that frame's part id (its box and mask are in that
                            // frame's picture). `POST …/media/:id/parts/:frame/cutouts` → `{ job }` finds the subject
                            // and instances in that frame and adds them as "f<n>-subject", "f<n>-inst-1", … (named
                            // "Subject (frame n)"), next to the existing parts; asking again replaces only that
                            // frame's, keeping their picks. A media event follows when the job is done.
  kind: MediaKind | "unknown"; kindSet?: boolean
  box: [x, y, w, h]         // where it is in the picture (unturned), 0…1
  quad?: number[][]         // a straightened rectangle's corners in the picture (TL, TR, BR, BL), 0…1
  hasMask: boolean          // a cut-out (else a crop of `box`, or `quad` straightened)
  rotation: 0 | 90 | 180 | 270; rotationAuto?: boolean; rotationWhy?: string
  picked: boolean
  size: [w, h]              // the part image's pixel size, turned
  flatSides?: ("left" | "right" | "top" | "bottom")[]
  edges?: { grow: number; soften: number; fillHoles: boolean }   // px at the picture's size
  prompt?: { region?: [x, y, w, h]; points?: { x: number; y: number; positive: boolean }[]; choice?: number }
  image: string; thumb: string; mask?: string     // URLs: the part as a picture (cut, straightened, turned), ≤256 px, its mask
}
```

A part as content in a document: `ImageContent.asset` is `"<media id>/<part id>"` (the part's picture: already cut,
straightened and turned; `cutout` is ignored). A plain media id still means the whole picture with `cutout` as before.
Append `@x4` to use the part upscaled (see Upscaling).

Routes:

- `POST /api/programs/:slug/media/:id/pick {picked}` → Media: picks or clears **every** part (the grid's circle).
- `PATCH /api/programs/:slug/media/:id {rotation?, kind?}` → Media (the picture's turn, its kind; a kind you set
  is `kindSource: "you"` and never guessed again).
- `PATCH /api/programs/:slug/media/:id/parts/:part {picked?, kind?, rotation?, name?, edges?}` → Media.
- `DELETE /api/programs/:slug/media/:id/parts/:part` → Media (not `whole`).
- `GET …/media/:id/parts/:part/image|thumb|mask` → PNG.
- **Making a cut-out** (the editor): ask for candidates, then save one.
  - `POST …/media/:id/detect {region: [x,y,w,h]}` → `{ candidates: Candidate[] }` — Vision's subject inside a region
    (one candidate, or one per instance plus all of them).
  - `POST …/media/:id/segment {points?: {x,y,positive}[], region?: [x,y,w,h]}` → `{ candidates: Candidate[] }` —
    SAM 2.1: three candidates, small part → whole object, best first by its score. The first call for a picture
    encodes it (a second or two; the model downloads on first use as a `model` job); later clicks are fast.
  - `type Candidate = { id: string; url: string /* the cut-out preview PNG */; mask: string; score: number; box: [x,y,w,h]; area: number }`
  - `POST …/media/:id/candidates/:cand/preview {edges}` → `{ url, box }` — the candidate with grow/soften/fill holes applied, and where it sits in the picture (0…1). Softening fades the edge inward: it never grows the box.
  - `POST …/media/:id/parts {candidate, name?, kind?, edges?, prompt?}` → Media (adds a part, picked).
  - `PUT …/media/:id/parts/:part {candidate, edges?, prompt?}` → Media (replaces that part's mask: "Update").

## Upscaling (design stage)

`POST /api/upscale {program, asset, mode: "photo" | "pixel"}` → `{ asset, url, width, height }` — the part (or
media) upscaled ×4 (Real-ESRGAN for "photo", whole-number nearest-neighbour for "pixel"); `asset` is the original
with `@x4` (photo) or `@px4` (pixel) appended, to put in the layer's `ImageContent.asset`. Runs as a job the first
time; cached after. `GET /api/programs/:slug/assets/:asset/info` → `{ width, height, pixelArt, upscaled: string[] /* the upscaled copies already made, as asset ids */ }` for the layer
inspector's "enlarged past its pixels" warning.

`SourceInfo` also has `search?: boolean` (it finds programs, stage 1) and `media?: boolean` (it gives pictures,
stage 2). Gather jobs carry `source` (the source's id) as well as `group: "gather"`.

## Relevance (general searches)

Pictures found by a general search (Wikimedia Commons, Openverse; later Brave) carry `relevance` (0…1) and
`relevanceWhy` (reasons, e.g. "found by the game-specific search", "mentions Brøderbund", "dated 1908, far from 1996",
"looks like game material") on `Media`; pictures from catalogue sources (LaunchBox, IGDB, …) have none and count as
relevant. Half the score is the words (title, description, categories), half is MobileCLIP's view of the picture.
Commons and Openverse each search twice — the title as it is, and with game words / the developer and publisher —
and keep both; `remote.relevance.text` is the words' part. Nothing is dropped: the UI ranks by it and folds the
unlikely ones (below 0.4) into a "Probably unrelated" group.

## Hiding pictures

`PATCH /api/programs/:slug/media/:id {hidden: true|false}` → Media. A hidden picture has `hidden: true`: the grid
leaves it out unless "Show hidden" is on, and suggestions never use it (its picks stay as they were).

`MediaAnalysis.hasAlpha`: some of the picture is see-through (usable as a silhouette as it is).
