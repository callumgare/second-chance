# Icon Lab

Icon Lab designs the icons the program bundles ship: it finds pictures of a
program (catalogues, the program's own files), cuts out their parts, suggests
designs, lets you edit them, and renders them as Icon Composer `.icon`s with
macOS's Liquid Glass. It's a tool for us, not something a player sees, and its
text is written for us. It opens from **Debug ▸ Icon Lab…** in Second Chance,
in a window of its own.

The API it runs on is [Packages/IconLab/docs/api.md](../Packages/IconLab/docs/api.md),
and its documents (the designs) are
[Packages/IconLab/docs/document.md](../Packages/IconLab/docs/document.md). They
stay beside the code they describe, as the package's own contract; this page
doesn't repeat them.

## The stages

A program goes through four stages, each a route of the page
(`#/p/<slug>/<stage>`):

1. **Find the program.** Before a search, the programs worked on recently
   are listed, then Second Chance's own, one for each bundle (those Recent
   already shows are left out until **Show all**); choosing one opens the Icon
   Lab program kept for that bundle (`nancy-drew--old-clock`, its bundle id
   recorded in its `program.json`), shown with its picture once it has one.
   The search box searches every
   catalogue (Wikidata, LaunchBox, IGDB and the rest). Second Chance's own
   programs take part in the search, so each is merged with its catalogue
   entries, and opening one the first time finds it in the catalogues before
   it gathers, so its pictures are looked up by the catalogues' ids. When the
   automatic merge misses, **Merge results…** joins several results into one
   program, and a merged result's entries can be separated or its merge
   undone; merges are remembered (`merges.json` in the data folder). A result
   opened before says so (a program is a result's by the catalogues' ids it
   was opened with, or its bundle; one made before programs kept ids, by its
   title, Second Chance's own result first when several share it), and one
   with designs shows them, pinned, with **Continue designing**; choosing it opens that program again. Merging
   results that had each been opened makes one program of them (its pictures,
   designs and pins together, Second Chance's own program or else the one with
   the most sources taking the rest), and separating them leaves it with the
   part that has the most sources. A result opened as two programs offers
   **Combine them**.
2. **Gather.** Pictures from the sources, and from **Add from files**, which
   scans an app, installer, disc image or folder for every image in it
   (WrappKit's `ProgramImages`, [program-images.md](program-images.md)), in
   Second Chance's own process. An Icon Composer `.icon` brings in every layer
   in it, and the icon itself rendered by `ictool` (when Xcode is installed). In
   the window it's macOS's open panel; in a
   browser (`sc icon-lab serve`) the page's own browser, which offers the
   built apps (`built-apps/` in a checkout) with one click. A scan's progress
   is in its job in the activity panel, where any job can be cancelled (what
   it found is kept). Jobs run in lanes with slots of their own (`Jobs.Lane`):
   waiting on the network (gathering, finding a program in the catalogues),
   scanning files, and the rest (analysis, hi-res), held to a third of the
   cores, so a scan never queues behind gathering. Pictures dropped from the Finder onto the grid are
   added as your files, picked; dropped on Design's canvas or layers, they're
   also added as a layer. Each picture is analysed (its kind, its subject,
   its parts), and you pick the ones worth using.
3. **Design.** Suggestions from the picked pictures (treatments), and an
   editor for layers, effects, masks and Liquid Glass. A mask is a layer
   dragged onto another in the Layers panel (or a layer's **Mask the layer
   above / below**): nested under it, it shows the layer only where it has
   pixels, moving with it unless unlocked
   ([document.md](../Packages/IconLab/docs/document.md#mask-layers-2026-11-12)).
   A colour picker's **From the canvas** takes a colour from where the
   canvas is clicked: the design's own colour there, its layers with their
   effects over a plain fill, without what Icon Composer adds (the fill's
   gradient, specular, translucency, shadows, the tinted and clear looks),
   drawn by the sketch's `flat` mode (`src/state/eyedropper.ts`). Designs worth keeping
   are pinned. A pin never changes by editing: opening one edits a copy, and
   **Update pin** saves the copy back to it.
4. **Review.** Every pinned design side by side, in each appearance and at the
   sizes an icon is seen, from Icon Composer's real renders; and getting one
   out (below). Pins are dragged into order here or in Design's strip, and
   saving follows it: the first is the app's icon. An Icon Composer `.icon`
   dropped from the Finder on either is made again as a new pin: its
   pictures are added to Your files, and its fill, groups' Liquid Glass and
   layers' places are read from its `icon.json` (`lib/iconDoc.ts`), where
   Icon Composer draws a picture at its size in points on a 1024-point canvas,
   moved by `translation-in-points` (y down). What a design can't hold, such
   as a layer's blend mode or an appearance's own settings, is left out.

## Getting an icon out

- **Try on an app** puts a design on a built app as its Wrappfile's
  `APP --icon` would: compiled to `.icns` in `Contents/Resources/`, named by
  `CFBundleIconFile` (with `CFBundleIconName`, the template's own icon,
  removed), the app signed again ad hoc as a build signs it, and touched so
  the Dock and Finder look again. Only apps in `built-apps/` unless the page
  says the person chose another.
- **Save** (Review's button) writes each kept design's `.icon` and a
  1024 px PNG into the program's `saved/` folder in Icon Lab's data. Which
  pins are kept, and their order, are remembered (`state.json`).
- In a Debug build, which knows its checkout, **Save** also writes the kept
  designs, in order, to the program's bundle as `assets/<name>.icon`,
  `<name>-2.icon`, … (`<name>` the bundle's folder), each with its `.icns`,
  adds `"assets/"` to the manifest's `allow-paths`, and makes the Wrappfile
  give the app the first: an `APP --icon` it has is pointed at it (with the
  `COPY` that put the old icon in `/Resources/`), a module's
  `DO <module>.set-icon` is replaced by the two lines, or they're added after
  its stage's last `LAUNCH` (a Wrappfile of several stages with no icon is
  left to the person, the lines shown). The language has no `ICON`
  instruction any more. Nothing is committed: check the changes with git.
  `sc generate` compiles a bundle's `.icon`s to `.icns` too, with the same
  code (`IconCompile`, in ProcessKit), so running it after a save changes
  nothing ([wrappfile.md](wrappfile.md) has `APP --icon`).

## How it's built

- **`Packages/IconLab`**: `IconLabKit`, the engine (catalogues and sources,
  gathering, analysis with Vision and Core ML, parts and cut-outs,
  treatments, rendering, documents, jobs, the store), and `IconLabAPI`, its
  API with no web server in it: `IconLabAPI.handle(APIRequest)` answers an
  `APIResponse` off the main actor, and `events()` streams what the engine
  sends. The built page is the package's resource
  (`Sources/IconLabAPI/Resources/web`). Only the app (and the dev server)
  depend on it; the builder never does.
- **`Tools/icon-lab/web`**: the page, React and TypeScript built with Vite
  ([its README](../Tools/icon-lab/web/README.md)).
- **`Tools/icon-lab/server`**: the dev host, a Hummingbird server over
  `IconLabAPI`. A package of its own, so Hummingbird and SwiftNIO never reach
  the app's package graph.
- **`SecondChance/IconLab/`**: the window. `IconLabHost` makes one engine for
  the app's life, the first time the window opens; `IconLabSchemeHandler`
  answers `iconlab://`; `IconLabWebView` holds the web view and the bridge;
  `IconLabWindow` the move-in offer.

### The host contract

The page reaches its host only through `src/host.ts`, so the same page runs in
both ([Packages/IconLab/README.md](../Packages/IconLab/README.md#the-pages-host)
has the details):

- **In the app**, the web view loads `iconlab://app/`, and a
  `WKURLSchemeHandler` answers both the page's files and `/api/…` by calling
  `IconLabAPI.handle`. There's no server on a port: one would be reachable by
  every process and, through DNS rebinding, by web pages, and the API reads
  the file system. Files stream in pieces read off the main actor, and a
  request the page has stopped hears nothing more. Events reach the page as
  `window.iconLabHost.event(json)` (`callAsyncJavaScript`, the JSON passed as
  an argument), from once it has loaded. The page posts `{type: "open"}` and
  `{type: "copy"}` to the `iconLab` message handler for links (the browser)
  and the clipboard; it can't navigate away from `iconlab://`.
- **In the dev host**, the API is HTTP on 127.0.0.1 and the events come over
  the `/api/events` WebSocket.

## Working on it

- `./sc icon-lab serve` runs the dev server and Vite's dev server in front of
  it, with live reload; `./sc icon-lab build` builds the page into
  `IconLabAPI`'s resources with the hash of its source
  ([dev-cli.md](dev-cli.md#icon-lab)). The built page is checked in, so a Mac
  building the app needs no Node, and `WebBuildTests` fails while it's
  stale: after changing anything in `Tools/icon-lab/web`, build and commit
  what it wrote.
- The dev server's data is a scratch folder unless `--data` names one; its
  `--bundles <dir>` lists a `Bundles/` folder's programs and saves designs to
  it (give it a copy), `--built-apps <dir>` names the built apps.
- The package's tests (`swift test --package-path Packages/IconLab`, part of
  `sc test unit`) cover the parsers, documents, imaging and every route over
  scratch data; `IconLabWindowTests` loads the page in an offscreen web view
  through the scheme handler. The live model tests run only with
  `ICONLAB_MODELS_LIVE=1`.

## Where its data lives

- **The data folder** is `~/Library/Application Support/SecondChance/Icon
  Lab`, beside Second Chance's other folders; `SECOND_CHANCE_ICON_LAB_DATA`
  names another. It holds the programs (pictures, masks, parts, designs,
  pins, saved icons), caches, the catalogues' local copies (LaunchBox,
  TheGamesDB, My Abandonware: about 300 MB) and the models (about 400 MB),
  which are downloaded the first time they're needed.
- **Moving the old data in**: the first time the window opens with nothing in
  the data folder, a Debug build offers to move the standalone lab's
  `.local/tools/icon-lab/data` in (`SECOND_CHANCE_ICON_LAB_OLD_DATA` names
  another). It's moved, never copied and deleted, and never into a folder that
  already has files.
- **The checkout** a Debug build came from is recorded in its Info.plist as
  `SourceCheckout` (`$(SECOND_CHANCE_SOURCE_CHECKOUT)`, set for Debug only),
  and gives the keys (its `.env`), `built-apps/` and `Bundles/`
  (`SECOND_CHANCE_ICON_LAB_BUNDLES` names another). A Release build has none
  of them: no keys, no built apps, no saving to bundles.

## Keys, Xcode and models

- **Keys** are read from the checkout's `.env` (and the environment, which
  wins), all optional: `IGDB_CLIENT_ID` and `IGDB_CLIENT_SECRET`,
  `STEAMGRIDDB_API_KEY`, `SCREEN_SCRAPER_DEV_ID`,
  `SCREEN_SCRAPER_DEV_PASSWORD`, `SCREEN_SCRAPER_USERNAME`,
  `SCREEN_SCRAPER_PASSWORD`, and `BRAVE_SEARCH_API_KEY` (paid per request,
  so only used when asked), listed in `.env.example`. A source without its
  keys says so in the sources panel.
- **Xcode** is needed for the real renders (Icon Composer's `ictool`; without
  it the page's own sketch stands in) and for compiling `.icns` (`actool`,
  for Try on an app and saving to a bundle). Saving `.icon`s needs neither.
- **Models** (Core ML) are downloaded on the Mac that uses them, never
  shipped: MobileCLIP (what kind of picture it is, and similar pictures),
  BiRefNet (subject masks), Real-ESRGAN (upscaling) and SAM 2.1 (picking
  parts). `GET /api/models` lists each with its licence. MobileCLIP's weights
  are for research and personal use only, which is fine for a tool we use but
  is why Icon Lab isn't something players get: it would need another
  classifier first.
