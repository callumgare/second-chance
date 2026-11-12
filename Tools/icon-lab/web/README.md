# Icon Lab's page

The page of Icon Lab (`Packages/IconLab`): React 18 + TypeScript (Vite), react-konva for the canvas, dnd-kit for the
layers, react-colorful for colours, TanStack Virtual for big grids, zustand for state. Its contract with the engine
is `Packages/IconLab/docs/api.md` and `docs/document.md`; how it reaches its host (the dev server, or Second
Chance's window) is in `Packages/IconLab/README.md`, and all of it goes through `src/host.ts`.

## Running

From the repo root:

```sh
./sc icon-lab serve   # the dev server (127.0.0.1:8767) and Vite (http://localhost:5173), /api proxied, live reload
./sc icon-lab build   # type-checks, then builds into IconLabAPI's resources, with the source's hash
```

`sc icon-lab serve` without `--data` uses a scratch data folder, `.local/icon-lab-dev/data`
([docs/dev-cli.md](../../../docs/dev-cli.md#icon-lab)). After changing anything here, run `sc icon-lab build` and
commit what it wrote: a test fails while the built page is stale.

The page uses the engine when `GET /api/programs` answers, and otherwise an in-browser mock (a `mock` tag shows in
the title bar). `?mock` forces the mock, `?engine` the engine. The mock only works under Vite's dev server: its
fixtures are the old prototype's per-game folders, named by `ICON_LAB_MOCK_GAMES` and served at `/mock-files` by
`mock-plugin.ts`; without them it has no programs. Its state (docs, pins, picks) is kept in localStorage.

Routes are hashes: `#/` (choose a program), `#/p/<slug>/find|gather|design|review`.

## Layout

- `src/host.ts`: the host: events (a WebSocket, or the app's bridge), opening links, the clipboard.
- `src/api.ts`: every type and call of the API, and the transport (engine or mock).
- `src/state/`: zustand stores: `app` (programs, the open program, media), `design` (the doc, undo, pins,
  suggestions, view toggles), `jobs` (the event socket and jobs).
- `src/render/`: `resources` (layer contents, shapes and masks fetched at the size shown, sharper on demand),
  `sketch` (the browser's drawing of a doc, shared by the canvas and every tile), `iconRenders` (the queue of
  real ictool renders).
- `src/shell/`: breadcrumb, activity pill and jobs panel, the title and status bar slots stages fill.
- `src/stages/find`, `gather`: placeholders for stages 1 and 2.
- `src/stages/design/`: layout A (workbench) and its expanded gallery (B): `EditorCanvas` (Konva: selection,
  transform handles, snapping, drop), `LayersPanel`, `inspector/`, `MediaDrawer`, `PinsStrip`, `Suggestions`,
  `AdjustAll`, `actions` (the edits).
- `src/stages/review/`: layout D, compare pins and save.
- `src/mock/`: the mock engine (routes, treatments as doc generators, canvas renders).

## Behaviour worth knowing

- Every edit goes through `useDesign().edit`, which keeps pins frozen: the first edit of a pinned doc continues on
  a copy whose `parent` is the pin. Drags and sliders are transient and become one undo step when let go.
- The current doc autosaves 0.7 s after a change (`PUT …/docs/:id`, `PUT …/current`).
- Keys: ⌘Z / ⇧⌘Z, arrows nudge (⇧ ×10), ⌫ delete, ⌘D duplicate, Tab cycles layers, H hide, P pin, G gallery,
  L glass, # grid, Esc. Alt while dragging turns snapping off.

## Stages 1 and 2

- `src/stages/find/`: the search (streams `search` snapshots from the event socket, polling as a fallback), kind
  chips, "why merged", recents and the sources panel. `src/state/search.ts` holds the snapshots.
- `src/stages/gather/`: the grouped, virtualised grid with filters and folded duplicates (`GatherStage`), cards,
  the inspector with its overlays, the docked activity panel, the path browser and live scan tree (`FilesDialog`,
  `ScanTree`, with `src/state/scans.ts` building the tree from icon-extract's lines), and the wait before designing.
- Under `?mock`, `src/mock/search.ts` stands in for the catalogues and `mock-data/scan-sample.jsonl` (a real
  icon-extract run) is replayed when you scan a `.app`.
- The status bar's "Models" opens the on-device models' states (`GET /api/models`, `model` events), with Download
  for any not here yet.

## Parts

- `src/parts/`: `actions.ts` (picking, turning, kinds, deleting parts, and cut-out candidates: the engine's routes,
  falling back to the page), `shim.ts` (parts made in the page under `?mock`, or while a route is missing: kept in
  localStorage), `PartImage.tsx` (a part's picture, and the grid's whole thumbnail zoomed to its parts).
- Stage 2: the grid's "Thumbnails: Whole pictures | Parts" switch, three-state pick circles, "No kind"; the inspector's
  parts list, picture turn and outlines; `CutoutEditor.tsx` (region, + and − clicks, how much to take, edges, save or
  update a part).
- Stage 3: the drawer lists picked parts (asset `"<media>/<part>"`); `inspector/Upscale.tsx` warns when a layer is
  enlarged past its pixels and swaps it to an upscaled copy (`@x4` / `@px4`).
