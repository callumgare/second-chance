# Icon Lab

Icon Lab designs the icons the program bundles ship: it finds pictures of a
program (catalogues, its own files), cuts out their parts, suggests designs
and renders them as Icon Composer `.icon`s. It's a tool for us, not something
a player sees. This package is its engine and API; the page (a React app) is
built from `Tools/icon-lab/web`. Second Chance opens it with Debug ▸ Icon
Lab… (`SecondChance/IconLab/`): a web view whose `iconlab://` scheme handler
answers the page and its API through `IconLabAPI.handle`, with one engine for
the app's life. Its data is in `~/Library/Application Support/SecondChance/Icon
Lab` (`SECOND_CHANCE_ICON_LAB_DATA` names another). It lists Second Chance's
programs first when finding one (each opens as the program for its bundle);
a Debug build also reads the checkout's `.env`, lists its `built-apps/`
wrapps to scan and try designs on, saves pinned designs to its `Bundles/`
(`SECOND_CHANCE_ICON_LAB_BUNDLES` names another), and offers to move the
standalone lab's `.local/tools/icon-lab/data` in when its own is empty.

Where things are:

- `Sources/IconLabKit/`: the engine. Catalogues and sources (`Catalog/`),
  gathering, analysis (`Analysis/`, Vision and Core ML), parts and cut-outs
  (`Lab*.swift`), treatments, rendering (`Render/`, its own sketch renderer
  and Icon Composer's `ictool`), documents, jobs and the store. `Lab` is the
  entry point; `LabTools` is what it uses from outside (`ictool`, where
  built wrapps are) and `LabHostInfo` what its host knows (its programs, a
  `Bundles/` to save to), which the host finds and passes in. "Add from
  files" finds images with WrappKit's `ProgramImages` in-process.
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
- `Sources/IconLabAPI/Resources/web/`: the page, built from
  `Tools/icon-lab/web` by `sc icon-lab build`, and served by `IconLabAPI`
  when its host names no other web root. `source.sha256` beside it is the hash
  of the source it was built from; `WebBuildTests` fails while it's stale.
- `Tools/icon-lab/` (at the repo root): the page's source (`web/`) and a dev
  host (`server/`) that serves the API over HTTP on 127.0.0.1 with the
  `/api/events` WebSocket, for working on the page in a browser.
  `sc icon-lab serve` runs it with Vite's live-reloading dev server in front
  ([docs/dev-cli.md](../../docs/dev-cli.md#icon-lab)); its `main.swift` says
  what each of its options does. Hummingbird and SwiftNIO live only there, so
  the app never fetches them.

## The page's host

The page reaches its host only through `src/host.ts`, so the same page runs in
the dev host and in Second Chance's Icon Lab window.

- **The API** is at `/api` on the page's own origin in both: the dev host
  serves it over HTTP; the app's URL scheme handler answers it by calling
  `IconLabAPI.handle(_:)`.
- **Which host**: the page is in the app when
  `window.webkit.messageHandlers.iconLab` exists, or when its URL has
  `?host=app`.
- **Events** (`IconLabAPI.events()`, each a JSON object with a `type`):
  - In the dev host, the page listens on the `/api/events` WebSocket.
  - In the app there's no WebSocket. The app calls
    `window.iconLabHost.event(json)` with each event, as a JSON string or an
    object, once the page has loaded (`host.ts` defines the function as it
    loads).
- **Messages to the app**: the page posts these to the `iconLab` script
  message handler:
  - `{ "type": "open", "url": "…" }`: open a link in the person's browser.
    The page sends every link that would open a new tab this way.
  - `{ "type": "copy", "text": "…" }`: put text on the clipboard, when the web
    view's `navigator.clipboard` refuses.

  In the dev host, links open with `window.open` and copying uses
  `navigator.clipboard`.

The rules are the repo's (AGENTS.md): Swift 6 with `MainActor` default
isolation, so the engine's types are `nonisolated` or actors and nothing heavy
runs on the main actor; swift-log; no force unwraps; subprocesses through
ProcessKit.
