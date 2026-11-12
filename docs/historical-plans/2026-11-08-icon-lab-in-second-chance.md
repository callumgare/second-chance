# Icon Lab in Second Chance — plan (2026-11-08)

Status: implemented 2026-11-08, in phases 1–5 below; "As built" at the end says where it went differently.

Bring Icon Lab (today `.local/tools/icon-lab`: a Swift engine served over localhost by Hummingbird, and a React UI)
into Second Chance as **Debug ▸ Icon Lab…**, a window of its own. It stays a tool for us — designing the icons the
program bundles ship — not something a player sees. Later it could grow into a player-facing feature; nothing here
should make that harder, but nothing here is built for it either.

## What it is today

- Engine: `IconLabKit` (~10.5k lines) — catalogues and sources, gathering, analysis (Vision, Core ML models), parts
  and cut-outs, treatments, rendering (its own sketch renderer, and Icon Composer's `ictool` for the real thing),
  documents, jobs. `icon-lab`, a Hummingbird server with a WebSocket for events, wraps it in ~4 route files.
- UI: React + Vite + TypeScript + react-konva (~8.8k lines), built to `web/dist` (~0.9 MB).
- Data (`data/`): programs (media, masks, documents, pins, saved `.icon`s), caches, catalogue copies (LaunchBox,
  TheGamesDB, My Abandonware: 286 MB), models (405 MB). Models and copies are fetched on first use.
- Needs from outside: `icon-extract` (WrappKit's `ProgramImages`, on the unmerged `icon-lab` branch), Xcode's
  Icon Composer (`ictool`, for Final renders), API keys in the repo's `.env` (IGDB, SteamGridDB, ScreenScraper,
  Brave — all optional).

## Decisions (proposed)

1. **The UI stays web, in a `WKWebView`.** Rewriting 8.8k lines of React (a konva canvas, XY pads, the inspector)
   in SwiftUI isn't worth it for a debug tool. The page is the same one the standalone tool serves.
2. **No localhost server inside the app.** The window's web view loads `iconlab://app/`, and a
   `WKURLSchemeHandler` answers both the page's files and `/api/…` by calling the engine directly; events (jobs,
   media, scans) go to the page through `evaluateJavaScript`, not a WebSocket. A server on a port would be reachable
   by every process and, through DNS rebinding, web pages — and the API reads the file system (`/api/fs`). Same
   origin for page and images also keeps the canvas untainted.
3. **One API, two hosts.** The route layer becomes transport-free: `IconLabAPI.handle(Request) async -> Response`
   plus an event stream. The app's scheme handler is one host; a small Hummingbird server is the other, kept for
   working on the UI with Vite's hot reload. Hummingbird (and SwiftNIO) stay out of the app: the server is a
   package of its own under `Tools/`, so the app's package graph never fetches them.
4. **Where the code goes:**
   - `Packages/IconLab/` — `IconLabKit` (the engine) and `IconLabAPI` (routes, events), with the repo's Swift
     settings, swift-log, lint, tests in `sc test unit`. Depends on `WrappKit` (`ProgramImages`, logging); nothing
     depends on it but the app and the dev server. Not part of the builder (`WrappBuilder` never imports it).
   - `Tools/icon-lab/` — the dev server (`icon-lab serve`) and the web UI's source (`web/`).
   - The built page is checked in as the package's resource (`Packages/IconLab/Sources/IconLabAPI/Resources/web/`),
     made by `sc generate` (or `sc icon-lab build`), like the `.icns` it already makes: a Mac building the app
     needn't have Node. A test fails when it's stale, as for the other generated files.
5. **Data lives in Application Support** (`~/Library/Application Support/Second Chance/Icon Lab/`), as a
   parameter the host passes (the dev server takes `--data`). First open offers to bring in an existing
   `.local/tools/icon-lab/data` (programs, catalogue copies and models, moved or linked rather than downloaded
   again).
6. **Keys**: a Debug build reads the checkout's `.env` (the build records the checkout's path, Debug only); any build
   can also take them in Icon Lab's own settings, kept in the Keychain. Without keys those sources say so, as now.
7. **Final renders need Xcode's Icon Composer**, found as now; without it, Final is unavailable (the sketch still
   works) and saving `.icon` still works. Compiling `.icns` needs `actool` (Xcode) too.
8. **Licences**: models are downloaded on the Mac that uses them, never shipped. MobileCLIP's weights are research-
   use only: fine for us; if Icon Lab ever reaches players it needs another classifier first (noted, not done here).

## How it fits Second Chance (the reason to move it)

- **Programs come from the bundles.** Icon Lab's program list starts with the shipped (and extra) bundles' programs,
  by their ids, titles and years, so "Find the program" is a pick rather than a search (search stays for anything
  else). A program's Icon Lab folder is keyed by its bundle id.
- **Your files: a built wrapp.** "Add from files" lists the wrapps Second Chance knows (its builds, `built-apps/` in
  a checkout) and scans one through `ProgramImages` in-process (no `icon-extract` binary), as well as any path.
- **Using an icon:**
  - *Try it on a wrapp*: puts the design's compiled `.icns` into a built wrapp's `Resources/` and points
    `CFBundleIconFile` at it, as `WrappBuildHelper.completeBuild` does (re-signing it after), to see it in the Dock.
  - *Save to the bundle* (Debug builds with a checkout): writes the pinned designs to the bundle's `assets/` as now
    by hand (`<name>.icon`, `<name>-2.icon`, …), compiles their `.icns` (sc generate's code, moved where both can
    use it), adds `assets/` to `allow-paths`, and — when the Wrappfile has no `APP --icon` — shows the two lines to
    add (or adds them, if the user says so). Nothing is committed.

## Phases

0. **Merge the `icon-lab` branch** (`icon-extract`, `ProgramImages`, `ClassicMacFormats` and `WindowsFormats`
   work) into main, rebased on today's main. Icon Lab calls `ProgramImages` as a library from then on.
1. **The package.** Move the engine into `Packages/IconLab` as `IconLabKit`; bring it to the repo's rules (Swift 6
   with MainActor default isolation, `nonisolated` where it runs off the main thread, swift-log not `print`,
   no force unwraps, SwiftLint strict); data dir, env and tool paths as parameters. Pull the routes out of
   Hummingbird into `IconLabAPI`. Tests move with it and run in `sc test unit`.
2. **The dev host.** `Tools/icon-lab`: the Hummingbird server over `IconLabAPI`, the web source, `sc icon-lab serve`
   (engine + Vite) and the build into the package's resources. The page talks to its host through one small module
   (fetch for `/api`, and an events source that's a WebSocket here and the native bridge in the app).
   `.local/tools/icon-lab` is retired once this works.
3. **The window.** Debug ▸ Icon Lab… opens a `Window` scene with the web view, the scheme handler and the event
   bridge; file choosing through `NSOpenPanel` where the page asks (the custom path browser can stay, as the app is
   unsandboxed). Jobs run off the main thread (`Blocking.run` / detached tasks), as the build does.
4. **Second Chance's side.** Programs from the bundles, wrapps as files, Try on a wrapp, Save to the bundle.
5. **Docs.** `docs/icon-lab.md` (and its AGENTS.md row), the API doc and document model moved under it; this plan
   to `docs/historical-plans/` when done.

## Settled (2026-11-08)

- **Wherever the Debug menu is**, Release builds too; Save to the bundle only where the build knows a checkout.
- **No server in the app**: the scheme handler and native event bridge (decision 2).
- **Existing data moves in** on first open, to Application Support; the `.local` tool is retired after.
- **The standalone server stays only as `sc icon-lab serve`**, the dev host for working on the UI with live reload.

## Risks

- Swift 6 strictness and MainActor default isolation over 10k lines written without them: the largest single cost.
- WKWebView differences from Chrome (the canvas, pointer events, pinch zoom, the clipboard API used by copy/paste).
- App size: the page (~1 MB) and the engine's code; models and copies stay downloads.

## As built (2026-11-08)

- **Phase 0 wasn't a merge of its own**: the Icon Lab work was built on the `icon-lab` branch, on top of the
  `icon-extract` and `ProgramImages` work, and goes to main with it.
- **The data folder** is `~/Library/Application Support/SecondChance/Icon Lab` ("SecondChance", without a space,
  as Second Chance's other folders are), `SECOND_CHANCE_ICON_LAB_DATA` to name another. Moving the old data in is
  offered only while the new folder has no files, and only before the engine has started.
- **Keys** come only from the checkout's `.env` in a Debug build (recorded as `SourceCheckout` in the Info.plist).
  Icon Lab's own settings and the Keychain weren't built: a Release build has no keys.
- **Events** reach the page through `callAsyncJavaScript`, the event passed as an argument, not
  `evaluateJavaScript`, so nothing in it needs escaping. No `NSOpenPanel`: the page's own path browser stayed.
- **The built page** is made by `sc icon-lab build`, not `sc generate`; `WebBuildTests` fails while it's stale.
- **Known programs carry only a bundle id and title**: the bundles record no year, platforms or makers. Their
  programs open as `<group>--<name>` (`nancy-drew--old-clock`), the bundle id kept in `program.json`.
- **Built apps aren't recorded by Second Chance**, so "Add from files" and Try on an app list only a checkout's
  `built-apps/` (Debug builds). Try on an app changes only those, unless the page says the person chose another.
- **Add the icon lines for me** works only for a Wrappfile of one stage; for more, the page shows the lines.
- **Scans run in-process** through `ProgramImages`; a crawl stops when its job is cancelled
  (`ExtractionOptions.isCancelled`, and `POST /api/jobs/:id/cancel`). `icon-extract` stays as the command-line tool.
- **Compiling `.icns`** moved from `sc generate` into ProcessKit (`IconCompile`), which both use.
- **Swift's `Float16` is unavailable on Intel Macs**, which the app is built for, so Core ML's half floats are read
  through a small converter of IconLabKit's own.
- **The API doc and document model stayed in `Packages/IconLab/docs/`**, beside the code they describe;
  `docs/icon-lab.md` links to them.
- **The standalone `.local/tools/icon-lab`** isn't deleted by any of this; it's retired by not being used.
