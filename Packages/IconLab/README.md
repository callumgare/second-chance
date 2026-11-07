# Icon Lab

Icon Lab designs the icons the program bundles ship: it finds pictures of a
program (catalogues, its own files), cuts out their parts, suggests designs
and renders them as Icon Composer `.icon`s. It's a tool for us, not something
a player sees. This package is its engine and API; the page (a React app) and
the window that hosts it come later.

Where things are:

- `Sources/IconLabKit/`: the engine. Catalogues and sources (`Catalog/`),
  gathering, analysis (`Analysis/`, Vision and Core ML), parts and cut-outs
  (`Lab*.swift`), treatments, rendering (`Render/`, its own sketch renderer
  and Icon Composer's `ictool`), documents, jobs and the store. `Lab` is the
  entry point; `LabTools` is what it uses from outside (`icon-extract`,
  `ictool`, where built wrapps are), which the host finds and passes in.
- `Sources/IconLabAPI/`: the API, with no web server in it.
  `IconLabAPI.handle(_:)` takes an `APIRequest` and answers an `APIResponse`
  (data or a file to stream); `events()` streams what the engine broadcasts.
  It also serves the page's files from the web root it's given.
- `Tests/IconLabKitTests/`: parsers against recorded answers (`Fixtures/`),
  documents, imaging, the models' pure code and the API's routes. The live
  model tests run only with `ICONLAB_MODELS_LIVE=1` (they download about
  320 MB); `ICONLAB_DATA` names the data folder they and the tokenizer tests
  read, by default the checkout's `.local/tools/icon-lab/data`.
- `docs/api.md`: the API, the contract the page is written against.
  `docs/document.md`: the document model.
- `Tools/icon-lab-server/` (at the repo root): a dev host that serves the API
  over HTTP on 127.0.0.1 with the `/api/events` WebSocket, for working on the
  page in a browser: `swift run --package-path Tools/icon-lab-server
  icon-lab-server --data <dir>` (`--port`, `--env`, `--web`,
  `--icon-extract`, `--ictool`, `--v1`, `--no-refresh`; its `main.swift` says
  what each does). Hummingbird and SwiftNIO live only there, so the app never
  fetches them.

The rules are the repo's (AGENTS.md): Swift 6 with `MainActor` default
isolation, so the engine's types are `nonisolated` or actors and nothing heavy
runs on the main actor; swift-log; no force unwraps; subprocesses through
ProcessKit.
