# Draft plan: Second Chance for any program

_Post-implementation note, 2026-11-03, added by Claude (Claude Code) as the
plan was filed: phases 1–11 were implemented and merged; phase 12 (telling
the owners of apps built with a since-fixed bug) was deliberately left for
later, as it is the first thing people would see. The validation notes this
plan drew on (`generic-programs-validation-results.md`, `validation/*.md`)
were working notes and aren't kept. Engines were then made downloads rather
than part of the template: [2026-11-03-engines-on-demand.md](2026-11-03-engines-on-demand.md)._

_Status: draft, 2026-11-02. The first validation pass is done, and its findings are
folded in below, each marked with the item it came from (A3, C1, …). What
is still to be checked is listed under [Still to
validate](#still-to-validate); decisions that depend on it are marked
**(validate)**._

## Validated so far

**Decided 2026-11-02:** the manifest is **YAML, checked against a JSON
Schema** (replacing C3's TOML): comments and easy editing, an editor that
knows the schema completes and checks a bundle as it's written, and
`sc bundle check` and a unit test validate every bundle with the same schema.

From A3 and A10 (2026-11-02, Blue Moon on this Mac):

- **A wrapp built through cloned layers is the same as one built today**
  (all 15,282 entries alike; only timestamps and the temporary build path
  differ, none from layering), and rebuilding from the patched layer took
  13 s against 131 s. Sealing a layer takes 0.1–0.3 s.
- **Restoring a layer renames the old tree aside** and deletes it later,
  off the main thread: deleting it in place was most of a 1 s restore.
- **A layer's Wine session is ended with `wineserver -k`** once the step's
  programs have finished, not waited out: 0.3 s against 3.1 s for
  `wineserver -w` (the server's linger), with the registry saved either
  way. `wineboot --end-session --shutdown` took 6.2 s. Not `-p0` (no
  linger) instead: installers that restart themselves would lose the server
  between the two, as games did when it was tried for wrapps. And check a
  session is running before ending or waiting for one: A3 saw `-w` with
  none take 5–6 s (0.3 s on a quieter Mac).
- **Host paths in a layer need no rewriting**: the font entries pointing
  at the build folder are rewritten by Wine at every start.
- **A new Wine within a major version needs no reinstall**: a prefix
  installed under 10.0_8 played under 10.0_6, with or without
  `wineboot -u` (40–50 s on a loaded Mac, rewriting only Wine's own DLLs).
  The update must run in the Wine module's environment (without
  `USER=crossover` it made a second user profile), and Wine's automatic
  updates are off in our prefixes, so Second Chance always runs it itself:
  `USE wine` does, when it finds a prefix another 10.x made ([A prefix
  follows its Wine](#a-prefix-follows-its-wine)). Wine 11 doesn't start in
  today's wrapper at all, so across a major version is still untested.

From J1, B4 and B5 (2026-11-02):

- **Validate the raw YAML against the schema**, never only the Swift
  decoding: Yams decoded unquoted `no`, `off` and `10.10` as the text
  written, and ignored a mistyped key; the schema rejected all of them.
- **A missing `drm` means "not known"**, not "none": 22 of 30 Steam games
  have none recorded.
- **A layer is keyed by the build part of a module's code**, hashed from
  the files the build compiles; launch-only code stays out of it.
  `key.json` keeps a hash per file, so a miss names the file.
- **The A: placeholder gets a fixed path**: today a random temporary one
  makes two builds with the same key differ.

The rest of the first pass's findings are in the sections they concern.

## Goal

Second Chance today knows how to build, launch and test Nancy Drew games, and
that knowledge is spread through its code. The goal is for everything specific
to one program to live in a **program bundle** — data that ships with Second
Chance and that people can also write themselves — and everything specific to
one technology (Wine, ScummVM, Steam, a future DOSBox) to live in a
**module**. The core is left knowing how to read bundles, run recipes, cache
layers, detect programs and drive tests, and nothing about any one program or
engine.

The model is Docker's, adapted: a recipe of steps builds an image (the
wrapp), in cached layers, from a base and the modules it uses; at run time the
wrapp is an isolated world that touches the rest of the Mac only where it
declares it should, the way a container only sees the volumes mounted into it.

**Where a concept maps cleanly onto one of Docker's, it takes Docker's
name and Docker's syntax** (decided 2026-11-02): stage, layer, target,
`FROM`, `FROM scratch`, `ARG`, `RUN --mount=type=…`, `ADD --checksum=`,
volume, and Compose's `build: target:`. Someone who knows Docker should be
able to guess what each does and how to write it; a new name or form is
only for something Docker has no equivalent of (`previous`, editions,
variants), and a Docker word is never used for something that works
differently.

### Not goals (for now)

- **No change the player can see** until the last phases. Every phase leaves
  the Nancy Drew games building, launching and passing the integration test
  exactly as they do now. The user-facing generalisation (wording, a catalogue
  of programs, adding your own bundle) comes after the internals are generic.
  Moving a wrapp's user files to the new layout ([Volumes](#volumes)) isn't
  a change the player sees, so long as nothing is lost: their saved games
  are where the game shows them, whichever folder holds them (decided
  2026-11-02).
- Not a separate command-line builder yet. Turning a bundle into a wrapp
  may one day be released as a tool of its own, apart from Second Chance,
  so the code that does it is kept apart now, to make that easy later
  ([The builder, kept apart](#the-builder-kept-apart)); nothing here
  builds that tool.
- Not a sandbox. A recipe runs Windows programs, and Wine programs can reach
  the Mac's files; see [Trust](#trust).
- Not a package manager for engines. The newest version of each engine
  ships with Second Chance, and the older ones it supports download on
  demand, checked against a hash ([Engine versions](#engine-versions));
  there is no catalogue of engines fetched from a server.

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Program bundle** | A folder holding everything about one program: manifest, Wrappfile, files, tests, icon. |
| **Manifest** | The bundle's declarative half: identity, editions and their inputs, variants, updates, detection, runtime, tests. |
| **Wrappfile** | The bundle's build recipe: an ordered list of instructions, in stages. |
| **Module** | Shared capability a stage brings in with `USE`: a folder of data (default stages, functions, files, needles, runtime defaults, detection matchers), optionally with a Swift implementation compiled into Second Chance. `wine` and `steam` have one; `nancy-drew` or a DirectX runtime is data alone. Anyone can write a data-only module. |
| **Function** | A named group of Wrappfile steps, defined by a bundle (in its Wrappfile) or a module (in its data), and run with `DO`: `DO prefix-setup`, `DO nancy-drew.patch --id=…`. Earthly's `FUNCTION`. |
| **Variant** | The same copy of a program set up a different way — a game that runs in Wine or in ScummVM has a variant for each — with its own build stage, runtime and volumes. Cuts across editions. |
| **Stage** | A named sequence of instructions producing a filesystem (`FROM … AS name`). The last stage is the wrapp. |
| **Target** | The stage an edition, variant or update builds (`build: { target: "disc" }`), Compose's term. |
| **Layer** | A cached snapshot of a stage's filesystem after a group of instructions, stored as an APFS clone. |
| **Edition** | A different copy of a program, or the same copy got from a different place, needing its own instructions to fetch and set up — the CD, the Steam release, the Her download, a shareware zip — with its own source, inputs, build stage and runtime overrides. A bundle has one or more. |
| **Input** | Something an edition's build needs from outside — the person's disc, a download, a Steam app — declared in the edition's optional `inputs` list by id, which the Wrappfile uses (`COPY --from=disc-1`). Docker's named build context. |
| **Source** | Where an edition's inputs come from (disc, Her download, Steam, the internet). Each source is provided by a module. Sources are either _brought_ (the person points at something and detection finds the edition) or _chosen_ (the person picks from a list). |
| **Choice** | A question an edition asks before building (launch through Steam or directly). Docker's `ARG`. |
| **Version**, **release** | A module's version is what a bundle constrains with `@` — for an engine module, the engine's (`wine@10.0_8`). A release is our fixes beneath it: one counting number per module (`release 14`), never written in a Wrappfile. |
| **Lock** | What a wrapp records about how it was built: modules' versions and releases, the bundle's version, the variant, the inputs' identities, download hashes, choices, `${install-dir}`, the updates applied, the steps skipped, the answer to the Wine question if it was asked, and whether the program was picked rather than detected. |
| **Update** | A rebuild that starts from an existing wrapp, declared in the manifest's `updates` list by id and run like a database migration ([Updating a wrapp](#updating-a-wrapp-decided-2026-11-02)). |
| **`previous`** | What an update starts from: the old wrapp, or the result of the update before it in the chain. A stage name (`FROM previous`) and a condition prefix (`previous.bundle<4`). |
| **Install folder** | Where a program is installed: a path the bundle chooses, given to the step that installs it (`--into=`), and written once, as a global `ARG` the Wrappfile's stages and the manifest's launch both read. If the person picks another folder in an installer's wizard, the path is made a link to it. |
| **Volume** | Storage kept outside the wrapp (the person's files, settings), surviving a rebuild: declared by name in a `volumes:` map, as in Compose, and mounted at a path by each variant or edition that uses it. |
| **User files** | What the person makes and keeps in a volume — a game's saves, a program's documents — as opposed to the program's own settings. Each volume says what shows it is in use (`in-use-when`) and what people call what it holds (`display-name`). |
| **Series** | The series a program belongs to (`"Nancy Drew"`), for its display name and grouping in lists: what people call it. |
| **Namespace** | The first part of a program's or an added module's id (`nancy-drew/blue-moon`, `someone/directx9`): where it comes from, so ids from different authors can't collide. |
| **Needle** | A test reference: a screenshot, match areas, tags and a click point (openQA). |

## The program bundle

```text
nancy-drew/blue-moon/
  manifest.yaml        identity, editions, variants, detection, runtime, tests
  Wrappfile            build steps
  assets/              anything the Wrappfile references
    disc.iss
    patches.lock       (generated: resolved downloads and their hashes)
  tests/
    needles/           title-screen.png + title-screen.json, …
    play.yaml          the test scenario (or a module's, such as nancy-drew's)
  icon.icns            optional; a default is used without one
```

Bundles and modules that ship with Second Chance live in its resources;
ones someone adds live in Second Chance's folder in Application Support.
Both are loaded the same way.

### Bundles and modules someone adds (decided 2026-11-02)

```text
~/Library/Application Support/Second Chance/
  bundles/<namespace>/<name>/        one per program, as shipped bundles are laid out
  modules/<module id>/<release>/     every release imported, side by side
```

- **They are imported, not hand-placed.** The app imports a bundle or a
  module from a folder (or an archive of one), copying it into place after
  checking it against the schema. Settings has a control that opens each
  folder in Finder, for anyone who wants to look or edit in place; what's
  put there by hand is checked the same way when it's loaded, and one that
  fails is listed with why rather than silently skipped.
- **Bundles and modules are distributed separately, by preference.** A
  bundle names the modules it uses (`USE <module>@<constraint>`), and
  importing it says, in plain words, which it needs that aren't there.
- **A bundle may carry them, for ease of passing one around:** an optional
  `dependencies/` folder of modules, each in its own folder with its
  `module.yaml`. Importing the bundle imports each one **only if that
  module id and release aren't already there**; a module already present
  at that release is left as it is. Dependencies are never loaded from inside
  the bundle: they are imported like any other module, so there is one
  place modules live and one copy of each release.
- **A module's id and release identify it for good.** A release, once
  imported, never changes: importing the same id and release with
  different contents is refused (each release's files are hashed when it's
  imported), and the person is told the module needs a new release.
  Several releases sit side by side. `USE <module>` takes the newest
  version, and `@<constraint>` (optional) the newest that satisfies it; a
  version always gets the newest installed release that provides it,
  shipped or added ([Engine versions](#engine-versions)).
- **Ids follow the program ids' rule.** A module someone writes has a
  namespaced id (`someone/directx9`), so it can't collide with a shipped
  module (`wine`, `nancy-drew`) by accident. The same id and release
  shipped and added is the shipped one.
- **A shipped module always wins over an imported one with its id**
  (decided 2026-11-02, after the review, replacing "an added release of a
  shipped module is allowed"): release numbers for one id given out by two
  parties would collide, and an imported release numbered higher would
  shadow every later shipped fix. Importing a module whose id is a shipped
  one's warns, in plain words, that Second Chance's own will be used, and
  the imported one is never loaded. An added module is always data alone.
- **An added bundle with the id of a shipped one overrides it**, with a
  note in the log and in reports.
- **Removing** a module some bundle still needs isn't offered; a module
  nothing needs is listed as unused and can go.

### Program ids and bundle ids

(Decided 2026-11-02.) A program's id is **`<namespace>/<name>`**, unique
on its own: `nancy-drew/blue-moon`, `freeware/skifree`. Two ids are the
same program exactly when the strings are equal, and the namespace still
groups bundles by where they come from (list everything in `nancy-drew/`, a
folder per namespace in the bundles' directory). Lower case letters, digits and
hyphens, one `/`. A bundle someone writes uses a namespace of their own,
so it can't collide with a shipped one by accident; one that means to
override a shipped bundle uses its id.

The wrapp's bundle id comes from it: `au.gare.callum.second-chance.program.`
then the namespace and the name, joined by a dot:
`au.gare.callum.second-chance.program.nancy-drew.blue-moon`. That matches
the prefix the rest of Second Chance uses (its logging subsystems), and it
differs from today's `au.gare.callum.SecondChance.nancy-drew.<slug>`
deliberately, so a wrapp built from a bundle gets a folder of its own and
today's saves can move into it ([Volumes](#volumes)). The id replaces the
draft's `bundle-id-group`. Today's short ids (`blue-moon`) stay as the
name part, so logs, `sc` and the integration test can keep using them
within a namespace.

### The manifest

**`series` and the app's name.** A program can name the series it belongs
to (`series: "Nancy Drew"`, as for a game series or a suite of programs).
The wrapp's name is `display-name`, which takes `{title}` and `{series}`
and defaults to `"{series} - {title}"` when there is a series, `"{title}"`
when there isn't. A manifest sets `display-name` only to override that,
for a series whose programs are known by another form of name. The series
is also what the app's lists can group by; it is not the namespace, which
is about where a bundle comes from rather than what people call it.

YAML, checked against a JSON Schema (decided 2026-11-02; validation J1).
Every bundle starts with a line naming the schema, so an editor that knows
it completes and checks the manifest as it's written, and `sc bundle check`
validates against the same schema. **A bundle is validated from the raw
YAML, never only by decoding it into Swift types**: decoding read unquoted
`no`, `off` and `10.10` as the text written and ignored a mistyped key,
where other YAML tools read the first three as true, false and a number;
the schema rejects all of them (J1).

**Bundles are checked with ajv, run in JavaScriptCore** (decided
2026-11-02, after trying three validators: see the validation results).
It is the only one that builds here unchanged, supports all of draft
2020-12, registers module schemas offline, and words its errors well
enough to reword for a bundle's author; JavaScriptCore is part of macOS,
so the cost is a 132 KB JavaScript bundle in the app and a step to update
it. A small Swift type wraps it, turning its errors into plain messages.
Swift-JSON is worth another look once the app requires macOS 27.

**Bundles are YAML 1.2, read the same way by the editor and the checker**
(decided 2026-11-02). J1 found the two disagreeing: the editor's YAML
extension (yaml-language-server) reads YAML 1.2, where a bare `no` is the
text "no", while Yams, by default, reads YAML 1.1, where it is false. YAML
1.2 is the one to keep: it is the current version, and the one where `no`,
`off` and `on` are just words. Yams parses through libyaml, which reads
both versions' syntax alike; what differs is how a plain value's type is
decided, and Yams takes that from a `Resolver` that can be replaced. So
Second Chance reads bundles with Yams and a resolver for YAML 1.2's core
schema (only `true` and `false` are booleans; `null`, `~` and empty are
null; numbers as YAML 1.2 writes them) **(validate: that a custom resolver
covers it, on J1's cases)**. No Swift library implements YAML 1.2 in full,
so a different library would mean a less used one for no gain. Strings are
still quoted by convention, which keeps a bundle clear of any reader's
quirks.

**`notes:` are for people, never for the build** (decided 2026-11-02).
One key whose contents the schema doesn't check, for what is worth
recording about a program but changes nothing: which installer family it
uses, whether it draws with DirectDraw or Direct3D, quirks of its install.
It is one key rather than unchecked keys anywhere, because rejecting a
mistyped key is what catches real mistakes (J1). Nothing reads it: `sc
bundle check` rejects a Wrappfile or function that refers to `${notes…}`, and
the app, the wrapp and reports never look at it. A note that starts to
matter to how a program builds or runs becomes a real field. Generated
bundles start with notes filled in from what `GameInfo` already knows
(which installs need AutoIt, which games run in ScummVM). Checking notes
against what a build finds is left for later.

A sketch:

```yaml
# yaml-language-server: $schema=../../manifest.schema.json
format: 1                                    # a newer format than this app reads is refused
id: "nancy-drew/blue-moon"                   # namespace/name, unique on its own
version: 3                                   # the bundle's own revision
title: "Last Train to Blue Moon Canyon"
series: "Nancy Drew"                         # the series it belongs to, if any
# display-name: "{series} - {title}"         # the default when there's a series; "{title}" without
former-bundle-ids: ["au.gare.callum.SecondChance.nancy-drew.blue-moon"]   # moved in and linked (Volumes)

runtime:                                     # shared by every edition and variant unless overridden
  aspect: "4:3"
  wine:                                      # module options, checked against the module's schema
    exit-code-meaningless: true
    clean-exit-log: { file: "Documents/*/Debug.LOG", marker: "ExitInstance(), good exit" }

volumes:                                     # what is kept outside the wrapp, by name (Compose's map)
  wine-documents:                            # also the nancy-drew module's; this is merged over it
    in-use-when: ["*/*.Hi*Save", "*/*.SAV", "*/HICONTINUE.*"]   # the person's; the rest is settings (L2)
    display-name: "saved games"              # what people are told it holds

variants:
  - id: "wine"
    volumes:                                 # mounted by name, where this variant wants it
      - source: "wine-documents"
        target: "C:/users/crossover/Documents"
        wine: { drive: "A:" }                # also the A: drive, as today's wrapps have it
    launch: { wine: { exe: "${install-dir}/Game.exe" } }

tests:
  scenario: "nancy-drew/quit-from-menu"  # from a module, or local

notes:                                       # for people only; nothing reads these
  installer: "installshield"
  graphics: "ddraw"
  quirks:
    - "Disc 2 holds the second half's videos; the installer asks for it."

editions:
  - id: "cd"
    source: "disc"                           # brought: detection finds it
    inputs:                                  # optional; the Wrappfile uses each by its id
      - { id: "disc-1", requires: "Setup.exe", prompt: "Insert the game's first disc" }
      - { id: "disc-2", requires: "Disk2.id", prompt: "Insert the game's second disc" }
    build: { target: "disc" }                # the Wrappfile stage this edition builds (Compose's term)
    patches: ["blue-moon-taffy-sort"]
    detect:
      matchers:                              # any matcher may identify the edition
        - matcher: "exe-version"
          file: "setup.exe"
          product-name: { contains: "Blue Moon Canyon" }
        - matcher: "file-hash"                 # ScummVM-style: md5 of the first N bytes
          file: "Data/game.dat"
          bytes: 5000
          md5: "…"
          size: 123456
          language: "en"

  - id: "her-windows"
    source: "her-download"                   # brought: the person's own download, detected
    inputs:
      - { id: "installer", format: "windows" }   # Her sold this game for Windows only
    patches: ["blue-moon-taffy-sort"]

  - id: "steam"
    source: "steam"                          # chosen: listed if the account owns it
    inputs:
      - { id: "game", app-id: 31810 }
    drm: "launch-when-steam-running"         # left out: not known (J1)
    # no `build`: the steam module's default stages install it,
    # into the Wrappfile's global ARG install-dir
```

What it borrows:

- **Inputs declared up front by id** (Lutris `files:`), so the app knows
  every prompt before step one, multi-disc games fall out of the list, and
  the Wrappfile refers to `disc-1` rather than a path. Every source's
  inputs are one list, `inputs`, whose fields are the source module's and
  are checked against its schema; a program whose Wrappfile needs nothing
  from outside leaves it out. The program the person is getting is always
  an input, never an `ADD`, which is for supporting files such as patches
  and runtimes (decided 2026-11-02). They are called
  inputs rather than Docker's `contexts` (decided 2026-11-02): each is
  something brought into the build from outside, as a named build context
  is, but "context" says nothing to someone who doesn't know Docker. Nothing
  that would need the vaguer word is one: the Steam sign-in is a `secret`
  mount, and the old wrapp an update starts from is `previous`, a stage.
- **A `requires` file per disc** (Lutris `insert-disc`, CrossTie CD profile),
  which is how a swapped-in second disc is checked.
- **Detection as a list of matchers**, ScummVM-style, each naming the variant
  it identifies (language, edition, demo). See [Detection](#detection).
- **Runtime as image config**: launch, volumes, environment and module
  options are metadata, not layers ([below](#runtime-settings-are-not-layers)).

### The Wrappfile

Dockerfile-like. Core instructions:

| Instruction | Does |
| --- | --- |
| `FROM scratch` / `FROM <stage>` `AS <name>` | Starts a stage from the bare wrapp template (Docker's `scratch`, its empty start), or from another stage. `FROM base` and `FROM previous` are the two stages Second Chance supplies ([Updating a wrapp](#updating-a-wrapp-decided-2026-11-02)). |
| `USE <module>[@<constraint>] [AS <name>] [options]` | Adds a module to the stage: its files and set-up (a layer), its instructions, its extensions to core ones. Brings in what it `depends-on`. Its instructions and functions are then `<name>.INSTRUCTION` and `DO <name>.function`; the name is the module's own without `AS` (Earthly's `IMPORT … AS`). |
| `RUN [--with=<module>] [--mount=…] <program> <args>` | Runs a program **inside an engine**, never on the Mac. The executor is the stage's only module that can run programs, or the one named. |
| `COPY [--from=<stage or input>] <src> <dest>` | Copies files; `src` may be a bundle file, a path in another stage, or an input's files. Modules provide path roots (`C:` for Wine). |
| `ADD --checksum=sha256:<hash> <url> <dest>` | A download, keyed by its expected hash (Docker's `--checksum`). |
| `LAYER` … `END` | Groups instructions into one layer (see [Layers](#layers)). |
| `FUNCTION <name>` … `END`, `DO <name>` / `DO <alias>.<name>` | A named group of steps (Earthly's `FUNCTION` and `DO`), with `ARG`s as parameters (`--id=…`). A bundle defines its own in its Wrappfile and runs them by name; a module's live in its data and run through the stage's name for the module (`DO nancy-drew.patch`, or `DO nd.patch` after `USE nancy-drew AS nd`), at the version its `USE` gave. Steps, not a stage, so they run on top of whatever the stage started from (shared set-up for a disc edition's `prefix` and the Steam edition's `steam/client`), and each `DO` is cached as if its steps were written there. |
| `IF <condition>` … [`ELSE IF <condition>` …] [`ELSE` …] `END` | Steps for one kind of Mac (`arch=arm64`, `macos>=26`), as Porting Kit's per-step `conditions`; one value of a choice (`launch-mode=direct`); or updating (`updates`, `updates has <id>`, `previous.bundle<4`). Not for editions: they get stages of their own. |
| `ARG <name>[=<value>]` | Before the first `FROM`, a global build argument with its value (the install folder, written once). Inside a stage, brings a global one or a choice into it as `${name}`, as Docker requires. |
| `EXPORT <path>` | Says where this stage left the program, for a variant that copies it out (validation C1). |
| `MOVE`, `REMOVE`, `EDIT <file> --ini=<section>.<key>=<value>` | File changes inside the stage, done by Second Chance itself — no step runs on the Mac. |

`FROM` also takes a module's stage (`FROM disc/install`, `FROM
steam/client`), with a version constraint as `USE` takes one (`FROM
steam@2/client`, the one form Docker doesn't have, as it puts a tag at the
end: `@` means a module's version everywhere here). **A stage can use a
module's instructions if it `USE`s the module, or is built `FROM` a stage
that did** (decided 2026-11-02): stages carry their modules forward, and a
module's own stage has `USE`d its module and what that depends on, so
`FROM steam/client` brings in `steam` and `wine` as Docker's `FROM
<image>` brings in what the image has installed. Naming the module in
`FROM` is as explicit as `USE`. And
substitutions take a default (`${name:-default}`) and a part of a path
(`${path:dir}`). No step sets a value: every value comes from an `ARG`
([below](#what-a-wrapp-launches-decided-2026-11-02)). Functions are
written in ordinary Wrappfile syntax, `IF` included, with `ARG`s as their
parameters, but no loops.

Mount types (`RUN --mount=type=…`), all core, with module options under the
module's namespace:

| Type | Lasts | In the layer? | In the key? | For |
| --- | --- | --- | --- | --- |
| `source` | The step | No | The input's identity | The person's disc or download (`wine.drive=D:`). |
| `cache` | Across builds | No | No | Download caches: winetricks', Steam's. |
| `secret` | The step | No | No | The shared Steam sign-in. Put in for the step, any refresh copied back to the shared store (`rw`), and removed from the stage before the layer is sealed, so a token never reaches a layer or the cache folder (today's `SteamSessionStore.strip`, at every step rather than once at the end). |
| `bind` | The step | No | The file's hash | A bundle file, at a path the program needs: `--mount=type=bind,source=assets/disc.iss,target=C:/setup.iss` (Docker's name). `${assets/disc.iss}` in an argument is shorthand: a `bind` mount at a path the executor picks, written in its place — for Wine, a folder of the step's own inside the prefix (`C:/.second-chance/assets/…`), removed before the layer is sealed, never a Z: path. In a module's function, `assets/` is the module's. (`assets/` rather than `files/`, decided 2026-11-02: everything in a bundle is a file.) |
| `fetch` | The step | No | Its sha256 | A download one step needs and nothing keeps, such as a patch's installer: `--mount=type=fetch,url=…,sha256=…,target=…`. Looked for in the download cache first, as `ADD` is. (C1) |
| `volume` | The step | No | No, and a layer built with one is never cached | An update that has to change the person's files: `--mount=type=volume,source=wine-documents`, the volume copied aside first ([Updating a wrapp](#updating-a-wrapp-decided-2026-11-02)). The name reuses Docker's word for what a volume is. |

A tool a step runs beside the program — AutoIt driving an installer — is a
`bind` from a module rather than a type of its own: `from=` names the
module by the stage's name for it, as Docker's names an image or stage
(`--mount=type=bind,from=wine,source=autoit/AutoIt3.exe,target=…`). It is
the one way to name a module's file: an instruction that takes one, such
as `installer.RUN --driver=`, is given the path in the prefix the mount
put it at. A
`cache` or `secret` takes `rw` where a step must write back (Steam
refreshing the shared sign-in), and a `cache` can sit over a path inside
the layer (Steam's download folder). (C1)

#### Copying in, and drives kept for play

(Decided 2026-11-02.) `COPY` is core: it copies into the stage, and so into
the wrapp. It knows nothing of Wine. A destination's first part is a root
some module provides — `C:/…` is the Wine module's, which turns it into the
right place in the prefix — the same way the Wine module extends `RUN
--mount` with `wine.drive=`. So `COPY assets/game.ini "C:/Program Files
(x86)/…/"` works because the stage `USE`s Wine, and is an error in one that
doesn't. A path with no drive, such as `/game/…`, is in the stage's own
files, outside any engine's drive: a ScummVM variant copies the game to
`/game`, and its launch names that (`path: "/game"`).

A source input is copied the way Docker copies from a named build context:
`COPY --from=disc-1 . <dest>`. Its key is the input's identity (a disc's
listing hash), never a hash of gigabytes of files.

**A disc needed only to install** is mounted for that one step and never
copied, the simplest case and the right one for most programs:

```dockerfile
FROM prefix AS disc
RUN --mount=type=source,id=disc-1,wine.drive=D: \
    --creates="C:/Program Files (x86)/Example/Game.exe" \
    D:/setup.exe /s
```

**A disc needed while playing** — some games check their disc is in the
drive before they'll play, and which files they check isn't known, so the
whole disc is kept — is copied in and given a drive with `wine.MOUNT`, as
the Nancy Drew games are today. The drive is recorded in the prefix, so it
is there for every later step, the installer included, and at launch:

```dockerfile
FROM prefix AS disc
ARG install-dir
USE nancy-drew
COPY --from=disc-1 . C:/discs/disc-1/
COPY --from=disc-2 . C:/discs/disc-2/
wine.MOUNT C:/discs/disc-1/ D: --cdrom   # kept in the wrapp: install and play
wine.MOUNT C:/discs/disc-2/ E: --cdrom
RUN --creates="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.exe" \
    D:/setup.exe /s /sms /f1${assets/disc.iss}
DO nancy-drew.patch --id=blue-moon-taffy-sort --into=${install-dir}
COPY assets/game.ini "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/"
```

That is common enough to be one instruction: **`wine.KEEP-DISCS`** does
it for every disc the edition declares, one, two or six — copied to
`C:/discs/<id>/` and given drives from D: in order — so a two-disc game's
stage starts:

```dockerfile
FROM prefix AS disc
USE nancy-drew
wine.KEEP-DISCS
RUN --creates="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.exe" \
    D:/setup.exe /s /sms /f1${assets/disc.iss}
```

It belongs to the Wine module, not a Nancy Drew one: any game that checks
for its disc needs it. And it is Swift, not a function, because it repeats
for each disc and functions have no loops. A module that wants its own
name for it can define a one-line function that runs it.

The folder the disc is copied to is the bundle's choice; the drive letter
is what the game looks for. (`nancy-drew-installer` is today's folder,
and generated Nancy Drew bundles keep it until phase 12 renames it; the
`C:/discs/…` in these examples is how bundles written after that look.) A ScummVM variant that `EXPORT`s the game's
folder takes the disc's files it needs with it and never needs a drive.

A condition on the Mac is about the Mac **building** the wrapp, and a wrapp
can be copied to another one. So a Mac condition's result goes in the
layer's key, and anything that should follow the Mac the game _runs_ on is a
runtime setting with its own condition instead, decided at launch.

`RUN --creates=<path>` names a file the step must leave behind (Porting
Kit's `neededFileOnClose`, Ansible's `creates`). A step that doesn't create
it fails, with a clear message, rather than a later step failing obscurely.
Today's check that `internalGameExePath` exists after install becomes this,
and it complements the installer-family completion checks
(`InstallCompletion`), which stay in the Wine module.

**Runtime settings live only in the manifest** (C5): the launch, volumes,
environment and module options. The Wrappfile is purely the build, so
there is one place to look for each.

#### An example, two editions

```dockerfile
ARG install-dir="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"

# Set-up every edition shares, as steps rather than a stage, since the
# Steam edition starts from Steam's own stage, not from this bundle's
FUNCTION prefix-setup
  wine.WINETRICKS cnc_ddraw
END

FROM scratch AS prefix
USE wine@10
DO prefix-setup

# The CD edition (its manifest entry says build: { target: "disc" })
FROM prefix AS disc
ARG install-dir
USE nancy-drew                     # a data-only module: functions, needles, scenario
COPY --from=disc-1 . C:/discs/disc-1/   # kept: the game checks for its disc
wine.MOUNT C:/discs/disc-1/ D: --cdrom
RUN --creates="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.exe" \
    D:/setup.exe /s /sms /f1${assets/disc.iss}
DO nancy-drew.patch --id=blue-moon-taffy-sort --into=${install-dir}   # a function: a fetch mount with its hash, a RUN of the patcher (under AutoIt for a wizard)
COPY assets/game.ini "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/"

# The Steam edition names no stage: the steam module's default stages
# start from steam/client, run the set-up function the manifest names
# (`setup: "prefix-setup"`), and install the app. Written out, that is:
#
# FROM steam/client AS steam
# ARG install-dir
# DO prefix-setup
# steam.INSTALL game --into=${install-dir}   # the module mounts the sign-in itself
```

And a ScummVM game bought on Steam, where Wine is only a build tool and never
reaches the wrapp:

```dockerfile
ARG install-dir="C:/Games/Message in a Haunted Mansion"

FROM steam/client AS fetch                      # Steam installed and signed in
ARG install-dir
steam.INSTALL game --into=${install-dir}

FROM scratch
ARG install-dir
USE scummvm
COPY --from=fetch ${install-dir} /game           # launched as path: "/game"
```

The edition picks the final stage. Stages per edition, sharing their
common steps through `FROM`, keep a Wrappfile free of conditionals; `IF` is
left for the Mac and for choices.

### Knowledge shared between programs

The inventory found a whole layer of knowledge that is about the Nancy
Drew games as a series rather than any one of them: the `splash-any-her-*` needles, the InstallShield
custom-dialog AutoIt script, the two patch wizards, `HerEngineLog`'s
clean-exit marker, `configureGameINI`'s `WindowMode`/`LoadSavePath` rewrite,
the quit scenario, `game.exe` as the usual exe name. These become a
**`nancy-drew` module**, data only, that each Nancy Drew bundle's
stages `USE` (its functions run as `DO nancy-drew.<name>`) — named for the series, not the publisher, since it supports
the Nancy Drew games, not everything Her Interactive made (decided
2026-11-02). Shared components such as a DirectX runtime are data-only
modules too (Bottles' dependencies; CrossTie's "component" flag). There is
one way to bring in shared capability — `USE` — whether it comes with Swift
or not ([Modules](#modules)).

## Editions and sources

The same program bought on a disc, on Steam or as a download is built and
launched quite differently — Steam's editions install through Steam and,
with DRM, launch through it; disc editions need patches. Separate bundles
per source would duplicate the title, detection, user files, tests and icon, and
split one program's identity. So a bundle has **editions**, as a Lutris
game page has several installers and several CrossTie application profiles
share one install profile. Everything not in an edition is shared; an
edition overrides what differs.

Each edition has:

- **A source, and its inputs** if it needs any.
- **A target stage** (`build: { target: "disc" }`), or none, in which case its source
  module's default stages build it.
- **Runtime overrides** of the shared `runtime` (Steam as the launcher).
- **Choices** asked before building.
- **Detection matchers**, for brought sources.
- **Optionally, volumes and tests of its own** (below).

### What overrides what

One order everywhere — runtime settings, volumes, needles, scenario
parameters: **the edition and the variant, then the bundle, then the
modules the final stage uses.** The first that says something wins. An
edition and a variant both setting the same thing differently is a
validation error, since neither is more specific than the other.

### Choices

A choice is a declared question with options and a default:

```yaml
editions:
  - id: "steam-drm-free"
    source: "steam"
    inputs:
      - { id: "game", app-id: 615770 }
    choices:
      launch-mode:
        options: ["direct", "steam"]
        default: "direct"              # what the app pre-selects, and what a headless build takes
        prompt: "…"
```

The app asks it, with the default pre-selected; a headless build takes the
default unless an environment variable says otherwise (as
`STEAM_LAUNCH_MODE` does now). One default serves both, as it does in
today's code (decided 2026-11-02; J1's prototype had a separate headless
default only because a hand-written bundle had made `steam` the default). The
answer reaches the Wrappfile through `ARG` and the runtime settings as a
value. Today's Steam launch-mode question becomes the first one. The answer
is part of the cache key of every layer that reads it, and is recorded in the
wrapp's lock.

### Default stages

Most editions of a source are built the same way: a Steam edition installs
the app and copies it out; a download fetches, unpacks and runs a setup
program. A source module provides that as **default stages**, parameterised
by the edition's fields. An edition with no `build` uses them, so a bundle
writes stages only where it differs from the usual. A default stage starts
where its source needs (a disc's from `scratch`, Steam's from
`steam/client`), so it can't start from the bundle's `prefix`; instead it
runs the set-up function the manifest names, `setup: "prefix-setup"`, right
after its start, so shared set-up (winetricks verbs) still applies to every
edition (decided 2026-11-02). A source module's default stages are named
as any module's stage is: the `her-download` module's for a Windows
download is `her-download/windows`, which a Her edition's own stage can
start `FROM`.

In C1, 10 of the 16 Nancy Drew editions needed no stage of their own; the
other six were a default stage plus `DO nancy-drew.patch`. A module can let an
edition name such additions as data (`patches: ["blue-moon-taffy-sort"]`,
applied by `nancy-drew` at the end of the default stage), which brings
that to none.

### Brought and chosen sources

- **Brought** — a disc or a file the person downloaded themselves. The
  person points at it; detection decides which program and edition it is.
- **Chosen** — Steam and the internet. The person picks from a list of
  every edition available through that source (for Steam, those the
  account owns); no detection needed.

**Steam is built before the game is chosen** (decided 2026-11-02). Which
games the person owns, and each app's build id (its cache key), come from
a signed-in Steam, so there is nothing to pick from until Steam is running.
So choosing Steam starts a build at once: the `steam` module's stage
`client`, which installs Steam in a prefix, signs in (or reuses the shared
sign-in) and lists the library — the same stage for every Steam game,
built once and cached, with the sign-in only ever a `secret` mount, never
in the layer. Once the person picks a game, the build carries on with that
game's bundle, whose Steam edition starts `FROM steam/client` instead of
`FROM scratch` and uses the Steam it finds there to install the game:

```dockerfile
FROM steam/client AS steam-install                # the Steam that listed the library
ARG install-dir
wine.WINETRICKS cnc_ddraw
steam.INSTALL game --into=${install-dir}
```

The `steam/client` stage is built once, with the Wine a Steam bundle would
get by default. A game whose bundle `USE`s another Wine gets the prefix
moved to that Wine when its stage starts, as any `USE wine` does ([A
prefix follows its Wine](#a-prefix-follows-its-wine)): under a minute,
cached as a layer of its own, rather than a second Steam install. A headless build with no saved sign-in fails
before it starts (C1, D5).

The welcome screen's options become one per source — "Disc or a file you
downloaded", "Steam", "Free from the internet", and "The game's app you
already have", a fourth brought source for updating a wrapp, reached
through the disc source until phase 12 — and each list is built
from whichever bundles have an edition for it. A new downloadable program
needs no change to the app. GOG would be a later chosen source. Until the
last phase, the internet source is hidden: it appears only after a
double-click on the Second Chance icon at the top left of the main window
([Phases](#phases-provisional)).

### The download source

```yaml
editions:
  - id: "freeware"
    source: "download"
    licence: "free-release"          # what the person is told: one of K4's classes
    licence-from: "the author's website"
    inputs:
      - id: "game"
        urls:                        # tried in order; the hash alone decides
          - "https://ski.ihoc.net/ski32.exe"
          - "https://web.archive.org/web/2007…id_/https://ski.ihoc.net/ski32.exe"   # full timestamp
        sha256: "3572d375…"
        size: 118784                 # shown before the download starts
        unpack: "none"               # or "zip", "rar", "zip:<member>" for an archive inside one
        install: "none"              # or the setup program to run, with its arguments
        # disc-image: "game.iso"     # an archive holding a disc image: mounted as a disc
```

`unpack`, `install` and `disc-image` are the download module's input
fields (C2, K3) and drive its default stage, which installs to the
Wrappfile's `${install-dir}`, so most download editions need no stage of
their own.

- **The hash alone decides.** Any URL whose file matches is fine, which
  is what makes mirrors safe. Status codes and content types are ignored —
  a Wayback capture of a page that has gone can come back 200 with HTML —
  and a mismatch counts as "not here", so the next URL is tried. The hash
  is also the cache key, so nothing is fetched to compute it.
- **Mirrors, in order**: the publisher, or a distributor it names
  (ScummVM's site); then the Wayback `id_` copy of that same URL, with its
  full 14-digit timestamp pinned, since a partial one redirects to
  whichever capture is nearest, which can change; then archive.org items.
  No fan sites, and no servers of ours.
- **Archive.org is a source like any other** (decided 2026-11-02). A file
  is fetched only when the person asks for that program, so it is them
  downloading it from the archive, as they could themselves, with Second
  Chance doing the clicking. An archive.org item no longer has to be
  byte-identical to the publisher's file (K3's rule, which was there for
  licensing): the bundle's hash says which file it is, wherever it came
  from.
- **Every archive lookup happens when the bundle is written** — the
  Wayback index, archive.org's metadata — never in the app, which only
  downloads.
- **The downloader is polite, and resumes.** One download at a time per
  site; a User-Agent naming Second Chance and its website; backing off on
  429 or 503, honouring `Retry-After`; resuming an interrupted download
  with `Range` (Wayback serves about 0.4 MB/s, so a disc image takes 10–25
  minutes). Downloads go into a cache keyed by hash, so each file is
  fetched once per Mac, and a long one says so in its progress step ("This
  is a big download and may take a while").
- **The licence is what the person is told**, not a gate on where the file
  comes from or whether a bundle may offer it: `licence` is one of K4's
  classes (`freeware-licensed`, `free-release`, `shareware`, and
  `abandonware`, allowed too — decided 2026-11-02 — for a program its
  rights holder has said nothing about), each with plain-words text shown before the
  download (the K3 validation notes have
  it; it never says "freeware", "licence" or "mirror"), and `licence-from`
  says where the permission comes from. The licence's own words are saved
  into the wrapp, for anyone who wants them.
- **A failed fetch says so plainly** ("The places that had it don't have
  it any more, or aren't answering") rather than looking like a build
  failure. **Each failed URL is reported**, not only a total failure, so a
  dead publisher URL is noticed even when a mirror quietly takes over.
- **Supporting downloads** — a patch, a runtime — are `ADD --checksum=sha256:… <url>`
  in a Wrappfile or function, not inputs: they are part of how the program is
  built, not what the person is getting. Second Chance ships a **download
  cache**, keyed by sha256, holding the files its own bundles `ADD` (the 23
  Nancy Drew patches, 11 MB), and `ADD` looks there before the network. So
  shipped bundles build offline and don't depend on Her's site staying up,
  and bundles someone writes use the same `ADD` and simply download (B3).

## Variants

Editions are what the person _has_; variants are how the program is
_run_. A game that runs in Wine today may later run better in ScummVM, as
ScummVM's Nancy Drew engine takes on more of the games. The two keep saves
in different formats, so the Wine variant has to stay for the people whose
saves are in it, while a first build should get ScummVM. A variant can run
several editions — ScummVM runs a game's CD and Steam releases alike.

```yaml
variants:
  - id: "scummvm"
    editions: ["cd", "steam"]
    build: { target: "scummvm" }     # its Wrappfile stage
    volumes:
      - source: "scummvm-saves"      # the scummvm module's volume, at its own target
    preference: 1                    # best for a first build

  - id: "wine"
    editions: ["cd", "steam"]
    build: { target: "wine" }
    volumes:
      - { source: "wine-documents", target: "C:/users/crossover/Documents" }
    preference: 2
```

A bundle with one way of running has one variant, which can be left
implicit. How the edition's stage and the variant's stage combine
depends on the engine (validation C1):

- **The variant runs on the engine the edition built with** (a Wine game
  installed by its installer under Wine, run in Wine): the variant's stage
  continues `FROM` the edition's. The game exists only inside the prefix its
  installer ran in, registry included, so it can't be lifted out.
- **The edition's engine was only a build tool** (Steam under Wine
  fetching a ScummVM game; Wine installing a game ScummVM then runs): the
  edition `EXPORT`s where it left the game, and the variant's stage starts
  fresh `FROM scratch`, `USE`s its engine and copies the export in. Wine never
  reaches the wrapp.

The ScummVM module supplies that second shape as a default stage, so a
ScummVM variant usually needs no stage of its own.

### Who chooses: editions are picked, variants are worked out

(Decided 2026-11-02.) **An edition is always the person's choice**,
because it is where they are getting the game from: choosing Steam or a
download picks it outright, and choosing "a disc" picks the source while
the disc they put in says which disc edition it is. Second Chance never
switches someone to another edition.

**A variant is conditional.** It is worked out from the circumstances
(below), and a variant says when it is on offer at all:

- `available: "yes"`: can be chosen, and the preferred one is the default.
- `available: "existing-files-only"`: only for someone with user files in
  its volumes, or rebuilding a wrapp that already uses it.
- `available: "no"`: known, not runnable yet (a reason in plain words).

Whether the person is asked depends on the circumstances: a first build
with one available variant asks nothing; someone whose user files are in a
variant that is no longer preferred is told and offered the switch.

### Which variant a build gets

A choice whose default is worked out, in this order:

1. **A rebuild keeps its variant.** The wrapp's lock records it, so
   updating a wrapp never quietly switches engine. A wrapp from before
   bundles has no lock; its variant comes from `WrappSettings`'
   `GameEngine`.
2. **Otherwise, a variant whose user files exist** — files in its volumes
   match their `in-use-when`, so a settings file left by one launch
   doesn't count. A volume shared with the preferred variant doesn't hold
   anyone back, since that variant reads it too. If
   more than one does, the most recently changed. This covers someone who
   deleted the app and kept their files.
3. **Otherwise, the preferred one** (the lowest `preference`).

When it matters, the person is told in plain words, naming their files
as the volume holding them does (its `display-name`: "saved games";
"files" if it doesn't) — "You have saved games from the earlier version, so it'll keep working the same way. A newer
way to run this game is available, but it can't open those saved games" —
and offered the switch, never switched automatically. Switching leaves the
old files where they are, so switching back finds them.

- **Converting user files.** Where they can be converted, the volume
  they would go into says so in its definition (`convert-from:`, naming the
  other volume and the module instruction or function that brings them
  across), so a module that declares a volume can carry its conversions
  with it. Rule 2 then stops holding anyone back: the conversion
  runs and the preferred variant wins.
- **Retiring a variant.** `available: "existing-files-only"`: new builds
  never get it, but anyone with user files in its volumes still can.
- The variant is a choice, so it is in the key of every layer it affects;
  layers both variants share are built once.
- The integration matrix becomes program × edition × variant; a retired
  variant can be tested less often.

## Modules

A module is a folder of data, and may also name a Swift implementation
compiled into Second Chance:

```text
wine/
  module.yaml        id, release, the versions it provides, options schema, depends-on, native: "wine"
  stages/            default stages, as Wrappfile fragments
  functions/         functions, run with DO
  assets/ddraw.ini
  needles/           Wine's own dialogs, for tests
```

So there aren't two kinds of module, only modules with or without code, and
the line between Swift and data falls per capability, not per module:

- **Swift** does what has to run on the Mac: executors, mount realisers,
  sources, launchers, in-process helpers, detection matchers that read
  binaries.
- **Data** does the rest: default stages, functions, files, needles,
  scenarios, runtime defaults, routine-error lists, matchers built from the
  core's. Much of what is Swift today moves into the Wine module's data —
  the winetricks verbs, `ddraw.ini`, `GameQuitCheck.routineErrors` — where it
  can change without recompiling and is readable in one place.
- `native: "<id>"` must name an implementation compiled into Second
  Chance. A module someone else writes can't name one, so it stays data and
  can't give itself powers on the Mac.
- **Functions** keep data-only modules useful: a named group of steps,
  written in ordinary Wrappfile syntax and run with `DO` (Earthly's
  `FUNCTION` and `DO`; Dockerfiles have nothing like it). A bundle's own
  are written in its Wrappfile and run by name (`DO prefix-setup`); a
  module's are in its data and run through the stage's name for the module
  (`DO nancy-drew.patch`, or `DO nd.patch` after `USE nancy-drew AS nd`),
  at the version the `USE` gave. `DO nancy-drew.patch
  --id=crystal-skull-1` becomes a `fetch` mount with its hash and a `RUN`
  of the patcher (under AutoIt for a wizard). A function can only do what a
  Wrappfile could say itself, so [Trust](#trust) is unchanged, and `DO`
  shows a reader that what follows is a function anyone can read, not a
  module's Swift. (Decided 2026-11-02: one form for what were a module's
  functions and a bundle's functions.)
- **A module contributes through the stage that uses it.** The modules an
  edition's final stage `USE`s supply its runtime defaults, needles and
  scenarios, as `USE wine` supplies the launcher. Detection runs before any
  stage, but validation has parsed the Wrappfile already, so which modules
  each edition uses is known statically and their matchers can be indexed.
- **A module's Swift has three facets** (D1), one per process, linked only
  by the module's id and the wrapp's settings: **build** (executors, mount
  realisers, sources, matchers; in the builder package, not the app — [The
  builder, kept apart](#the-builder-kept-apart)), **runtime** (a launcher
  or a service, and what watches the game; in the wrapp) and **test
  support** (in WrappPuppeteer). A wrapp's runtime is a **composition** —
  one launcher plus services — not an engine: today's four engine values
  are three compositions (Wine; ScummVM; Steam as a service with Wine's or
  Steam's launcher). A module used only to build, such as Wine applying a
  ScummVM game's patches, is one the final stage doesn't `USE`.
- **Versions and releases** are under [Engine versions](#engine-versions).

A module declares:

- **Identity, release and versions**: its id, its release number, and the
  versions that release provides ([Engine versions](#engine-versions)).
- **Options schema** for `USE` and its namespaced options, so a Wrappfile is
  checked whole before a build starts (Dev Container Features).
- **`depends-on`** (installed automatically, and giving typed access to
  the other module: Steam's runtime reads Wine's, and Steam's output
  reaches Wine's quit check through the core, D1) and **`installs-after`**
  (ordering only).
- **Files and set-up**: the layer `USE` adds — the engine itself, and for
  Wine a prefix (`wineboot`, `EmulateModeset`, `isolate_home`, `ddraw.ini`,
  the blocked drive letters).
- **Instructions** of its own, for ideas only it has (`wine.WINETRICKS`,
  `wine.REGISTRY`, `steam.INSTALL`). An instruction of a module's is its own
  instruction, not something `RUN` runs: `steam.INSTALL game` mounts the
  Steam sign-in (a `secret`) itself, as the module knows it needs it.
  **A module's instructions and functions are named through the stage's
  name for the module** (decided 2026-11-02, replacing short forms such as
  `ND.` and namespaced prefixes). `USE nancy-drew@2 AS nd` brings the
  module in under the name `nd`, and the version is written there and
  nowhere else; without `AS`, the name is the module's own (`wine`, or
  `directx9` for `someone/directx9`). Its Swift instructions are then
  `<name>.<INSTRUCTION>` (`wine.REGISTRY`) and its
  functions `DO <name>.<function>` (`DO nd.patch`): upper case after the
  dot is always Swift, `DO` and lower case always a function, and neither
  ever carries a version, so neither can disagree with the `USE`. As
  Earthly's `IMPORT … AS lib` is used as `lib+…`. Two modules a stage knows
  by one name are a validation error, fixed with `AS`. A stage built
  `FROM` another keeps its modules under the names they had, and its own
  `USE … AS` can rename one. `FROM` names a module's stage with `/` and a
  version (`FROM steam@2/client`), as it is the line that brings the module
  in, before any `AS`; a `.` beside a version (`10.0_8`) would be
  ambiguous there. Only shipped modules have Swift, so a module someone
  adds has functions alone.
- **Extensions to core instructions**: a `RUN` executor, mount
  realisers (`wine.drive`), `COPY` path roots (`C:`), how a bundle file path
  is shown to the program.
- **Sources**, for modules that provide one: brought or chosen; how an
  input is asked for (or a list offered), identified and keyed; its
  edition fields and their schema; its default stages (`disc`, a source
  module with Swift; `steam`; `download`; `her-download`, used only by Nancy Drew
  bundles, holding `CiderPackage` and the InstallShield launcher
  unpacking).
- **Detection matchers**, e.g. ScummVM's own detection, or
  `exe-version`/`msi-summary`, from the readers of Windows programs and
  MSI files the `installer` module uses.
- **Runtime**: a launcher (one per wrapp, the module the variant's
  `launch` names) or a service started before it (Steam before a Wine
  game); loading-window stages; quit checks and their routine errors;
  diagnostics; settings keys in `AppSettings.plist`.
- **Defaults for the core's runtime settings**, which a bundle can
  override. The **save warning** is one (on for Wine, off for ScummVM): a
  policy rather than engine behaviour, so the wrapp and WrappPuppeteer
  both read the setting, not the engine (D1).
- **A fallback launcher.** Steam's, for a DRM-free game launched through
  Steam, is Wine's: when such a launch fails, the core offers "Launch
  Directly" and relaunches with the composition rebuilt without Steam
  (D1).
- **How to load the in-process helpers**, which are the core's, not
  Wine's: puppet control is a test facility every engine needs. A module
  only says how to put the dylib in its program (Wine through winemac's
  variables, ScummVM through `DYLD_INSERT_LIBRARIES`); helpers only Wine
  uses stay Wine's (D1).
- **Volumes** a bundle can mount by name, with a default target
  ([Volumes](#volumes)): the ScummVM module's `scummvm-saves`, the
  `nancy-drew` module's `wine-documents`.
- **Steps added to every final stage** that `USE`s it, after the stage's
  own (C1's `assemble`): the `nancy-drew` module's INI rewrite, so no Nancy
  Drew bundle has to remember it. A module can't know a bundle's folders,
  so these steps run in the final stage's scope and may read the bundle's
  global `install-dir` there, and nothing else of the bundle's
  (`assemble: ["DO nancy-drew.configure-ini --into=${install-dir}"]`); `sc
  bundle check` rejects a bundle that uses such a module without declaring
  the global `ARG install-dir` (decided 2026-11-02, while implementing:
  functions take the folder as a parameter, and `assemble` is where the
  bundle's value is passed in).
- **Test support**: traits WrappPuppeteer needs (the ScummVM process name,
  how focus works, Steam's overlay, the cnc-ddraw first-click check).

The rule for what goes where: **if an idea is generic, extend a core
instruction; module instructions only for what makes sense nowhere else.**
Otherwise every module grows a `x.RUN` and the core can no longer cache,
validate or log steps the same way for all of them.

Today's modules would be `wine`, `scummvm` and `steam` (each with Swift);
`installer` (with Swift, depending on `wine`);
`disc` and `her-download` as source modules (with Swift); and
`nancy-drew` (data only). The inventory found engine branching at
about 45 sites (11 `switch gameEngine`, 30+ `runsInWine`/`needsSteam`/…);
each becomes a call through the module protocol.

### Engine versions

```dockerfile
USE wine@10.0_8     # exact
USE wine@10         # any 10.x
USE wine@>=10.0_6   # a minimum
USE wine            # the newest
USE wine@10 --esync=off   # with options, checked against the module's schema
```

**Two numbers, with two names** (decided 2026-11-02). A module has:

- **versions**, what a bundle sees and constrains with `@`. For an engine
  module a version is the engine's (`wine@10.0_8`: upstream 10.0,
  Sikarugir's packaging 8, ordered as E2 has it). For a module with no
  engine (`nancy-drew`) it is a plain number of its own (`@1`), raised
  only by a change that would break bundles.
- **releases**, our fixes beneath a version: one number per module,
  counting up (`release 14`), never written in a Wrappfile. A release says
  which versions it provides (the Wine module's release 14 provides
  `10.0_6` and `10.0_8`), and a version always gets the newest release that
  provides it.

So `wine@10.0_8` is always Wine 10.0_8 as Second Chance runs it best
today. Logs, reports and the lock say both: "Wine 10.0_8 (module release
14)". The word "version" is never used for a release, in code, docs or
`sc` output, so "which version" has one answer.

**Within a version, every release is backwards compatible**, because a
Wrappfile can't choose a release: a new release may add instructions,
options, functions and files, and fix how existing ones behave, but never
remove one or change what it means. Something that would break bundles
waits for a new version (a new engine version, or the next number of an
engine-less module). Two checks hold it: `sc module check` compares a
release's instructions, functions and option schemas with the previous
release's for each version it provides, and fails on anything removed or
changed in type; and the integration test rebuilds every bundle with the
new release before it ships. A release can stop providing an old version;
the older release still installed keeps providing it, so nothing pinned to
it breaks.

- **The constraint is optional** (decided 2026-11-02): without one, the
  newest version is used, and a loose one picks the newest that satisfies
  it. **How tight to pin is the bundle's call, case by case** (decided
  2026-11-02, after the review). A program known to break between Wine
  versions, as the Nancy Drew games have, pins at least the major version
  (`wine@10`, generated bundles' default) and perhaps the minor; one that
  has run on every Wine for years leaves it loose, since every pin is a
  chance that the engines a Mac already has don't fit and another has to
  be downloaded. A bare `USE wine` moves to a new major version when one
  ships, which makes every rebuild of that bundle a fresh one. A module can mark a version a **preview**, which is used only where a
  constraint names it, so "newest" never means one not yet ready.
- The resolved version and release are recorded in the wrapp (a
  lockfile, in effect), so logs, reports and rebuilds know what it runs.
- A built wrapp keeps its engine. A newer version reaches it only
  by rebuilding, which user files surviving as volumes makes safe.
- The integration test records the resolved version each game passed with,
  so a newer engine that breaks a game shows as a failure and a
  tighter constraint in that bundle.
- A module can mark a version **withdrawn**, naming what replaces it
  (Porting Kit's `engineReplacements`, `10.0_2 → 10.0_3`). Validation then
  warns about a bundle pinned to it, and a rebuild can offer the move. The
  table ships with Second Chance, not from a server, so a build means the
  same thing on every Mac with the same version.
- **The newest version ships in Second Chance; others download on
  demand** (validation E1: a Wine engine is ~1 GB unpacked, 160 MB
  compressed), each checked against a sha256 in the module's data. Wrapps
  are signed ad hoc as a whole at the end of a build, so a downloaded
  engine needs no signature of its own.
- **A layer's key carries the version, and hashes of the release's build
  files rather than its number** (B4): a release that changes only what
  happens at launch, or only another version's files, leaves cached
  installs alone, so a release doesn't mean rebuilding every game from its
  disc. The release number is for people and the lock; the hashes are for
  the cache. A **bug fix** in a file a build uses changes its hash, so the
  layers built with it miss and those games reinstall, which is wanted;
  what decides is whether a file the layer depended on changed, never the
  release. To keep that precise:
  - **Each layer is keyed on the module files its own instructions used**
    (`wine.WINETRICKS d3dx9`: winetricks and that verb; a `DO nancy-drew.patch`
    layer: that function and its patch's data), not the module's whole build
    folder.
  - **A module's default stages put what changes often late.** Keys chain,
    so a change early misses everything after it, install included. The
    Wine module's set-up splits into what installers need (the prefix,
    winetricks verbs), before the install, and what only the game needs
    (`ddraw.ini`, run-time registry settings), after it or in the runtime
    settings: a fix to `ddraw.ini` rebuilds a one-second layer.
  - **Hashes are of normalised text** (comments and whitespace dropped in
    Wrappfile fragments and YAML), so a comment isn't a reinstall. There is
    no flag to say a change doesn't matter; that is how caches go wrong.
  - **A release can force a miss** where hashes can't see a change
    (`invalidates: { versions: ["10.0_8"], from: "install" }`), which
    should be rare, as build-time Swift is hashed too (B4).
  - **Owners of affected wrapps are told.** A release that fixes a build
    bug says so, and Second Chance tells the owner of a wrapp built with
    the bug, in plain words, that updating it fixes a problem, and whether
    that needs the disc. That is worked out as for any update (decided
    2026-11-02): no disc when the layers before the fix are still in the
    cache, or when the release ships an update that brings an old wrapp
    past the fix — a module lists updates as a bundle does, `FROM
    previous`, and its default update is one of them — and otherwise the
    fresh build's disc. So a release that fixes something after the
    install should ship such an update where it can, as re-running a fixed
    step on an installed game usually can. A launch-only fix needs a
    rebuild too, as the launch code is in the wrapp, but never the disc:
    nothing in the wrapp's layers changed, so the module's default update
    carries it over.
  - **The core's own build code is hashed too, by target** (decided
    2026-11-02). A change to how `COPY` or `RUN` behaves must miss; a
    change to logging mustn't. Code that decides what a layer holds — the
    core instructions' executors, mount realisers, the layer store — sits
    in Swift targets of its own, as each module's build facet does, and a
    layer's key carries the hash of the targets its instructions ran, with
    everything they depend on, less a short reviewed list of targets that
    can't change a layer's contents (logging, `Blocking`). The parser needs
    no hash: what it produces, the normalised instruction, is in the key
    already. Per target rather than per function, because the package
    graph says reliably what a target uses and nothing says it per
    function; a target that turns out too coarse is split. If that can't
    be kept tidy, the fallback is a hand-maintained cache version per
    instruction and module, with `sc module check` warning when build code
    changed and the version didn't. **(validate:
    B4's prototype, per target.)**

#### Updating a wrapp (decided 2026-11-02)

An update is a rebuild that may start from the old wrapp. Working out
automatically what an install did, and redoing it from a finished wrapp,
would hold for some programs and quietly fail for others, so beyond the
cache it is never guessed: the bundle says how, as a list of **updates**,
the way a database's migrations bring it from one version to the next.

**The layer cache is the only automatic path.** When every key matches,
the cached layers are what a fresh build would make, byte for byte. Keys
carry the exact engine version, so a new engine misses them and the build
goes on to the updates.

**Updates are listed in the manifest**, so whether a wrapp can be updated,
how, and whether that needs the disc is answered from the manifest and the
old wrapp's lock alone, without running anything. Each names its target
stage the way Docker Compose does (`build: target:`):

```yaml
updates:
  - id: "from-wine-9"
    from: { wine: "9" }              # what the program must be at for this update to apply
    build: { target: "wine-9-to-10" }
  - id: "taffy-patch"
    from: { bundle: "<4" }           # wrapps built before bundle 4 lack this patch
    build: { target: "add-taffy-patch" }
```

- **The updates that apply run in order, each starting from the last.**
  `previous` is the old wrapp for the first to run, and the result of the
  one before for every one after. An update applies when its `from`
  matches the program as it is at that point in the list, and runs at most
  once. One with no `from` applies to any old wrapp.
- **The program's state is what the old wrapp's lock records**: each
  module's version and release, and the bundle's version. An update moves
  a module to the version this build resolves when its stage `USE`s that
  module; `to: { wine: "10.0_8" }` stops it short of that, for an update
  meant to be followed by another. Every other module stays at the version
  it has at that point. A module's version is written as a plain value
  (`from: { wine: "9" }`); a release goes under `release`, as in
  `from: { nancy-drew: { release: "<3" } }`, for an update that applies by
  a module's release.
- **Each update says which bundle version it brings the program to**
  (`to: { bundle: 4 }`; an update with no `build` brings it to this one).
  `sc bundle check` fails a bundle whose version went up with a change to
  its build that no update covers, so a gap between versions can't leave a
  wrapp quietly stale. An update entry with `fresh-build: true` is what it
  accepts in place of one: wrapps matching that update's `from` can't be
  brought forward, and are rebuilt from the source (the disc, say).
  (Decided 2026-11-02, after the review.)
- **Wrapps from before bundles get a lock made up for them**, from
  `WrappSettings` (engine, source, game) and the Wine engine's
  `SharedSupport/wine/version`, at bundle version 0. One whose source was
  never recorded (`WrappSettings.source` is nil in the oldest) is matched
  to the program's disc edition, the only source those wrapps had.
- **An update is asked for nothing it doesn't use.** An input (a disc, a
  download) is asked for only when a step that uses it runs, so an update
  that takes the installed game from `previous` never asks for the disc.
  That is the point of updates: the old wrapp is the source.
- **An update with no `build`** runs the edition's own target stage — a
  fresh build, with `previous` there to take things from. It makes the
  program exactly what this bundle builds, bundle version included, so no
  update after it applies. Its stage tells an update from a first build by
  conditions (below).
- **Updates can share a target stage, and it runs once.** Which updates
  apply is worked out before anything runs, so the stage runs where the
  first of them would and counts as all of them; inside, `IF updates has
  <id>` does each one's part. Updates with no `build` share the edition's
  stage the same way.
- **The bundle's updates come first; then modules' default updates, for
  the modules still behind**, in the order the bundle first `USE`s them.
  After a fresh-build update nothing is behind, and Wine's doesn't run
  after a bundle update that already brought Wine up to date. A bundle that
  wants a default earlier (an engine update before a content update) lists
  its id where it wants it, and replaces one by listing an update with its
  id. A new Wine needs no default update of its own: an update stage built
  `FROM previous` `USE`s Wine, and that moves the prefix to this build's
  Wine ([A prefix follows its Wine](#a-prefix-follows-its-wine)). The Wine
  module's default update, `wine-prefix`, applies when the hashes of the
  prefix set-up's files changed (registry settings, `ddraw.ini`) and
  re-applies just that set-up — not on every release, most of which only
  change launch code (decided 2026-11-02, after the review). Steam's,
  `steam`, applies when Steam's differs. So a Wine and Steam bundle that
  lists nothing gets Wine's prefix brought along when Wine changed, Steam's
  update when Steam did, and both when both did.
- **The chain must reach this build.** At its end every module must be at
  the version this build resolves; a chain that can't get there is worked
  out before anything runs, and the build is a fresh one instead. So is one
  where no update applies at all but something changed. The person is
  told which, and whether it needs the disc (an update mounting one, or the
  fresh build's source), before it starts.
- **An old wrapp is always matched on its edition and variant**, without
  being asked: a disc edition's wrapp is never the `previous` of a Steam
  build, nor a Wine wrapp of a ScummVM one.
- There is no instruction for refusing an update inside a stage, and no
  trying one and falling back if it fails, which would find out too late,
  perhaps asking for the disc half way.
- **An update is named for what it is for**, not how its stage does it.

**An update's own stage** starts `FROM previous`, for a program whose
install is complicated and can be brought up to date where it stands:

```dockerfile
FROM previous AS wine-9-to-10
USE wine                                  # this build's Wine: the prefix is kept and moved to it
wine.WINETRICKS d3dx9                     # something Wine 9 prefixes lacked, say

FROM previous AS add-taffy-patch
ARG install-dir
USE nancy-drew
DO nancy-drew.patch --id=blue-moon-taffy-sort --into=${install-dir}

FROM base AS disc                         # the edition's target, the shared tail
ARG install-dir
USE wine                                  # again: on an update, base is the chain's result
EDIT "${install-dir}/Game.ini" --ini=Display.WindowMode=2   # safe to run twice
```

**`base` is what the target starts from** (made definite 2026-11-02,
after the review; a stage name Second Chance supplies, as `previous` is):
on a fresh build, the stage the edition's `build.base` names, its install
stage (`build: { target: "disc", base: "disc-install" }`, with the
install written `FROM prefix AS disc-install`); on an update, the result
of the chain. A target that doesn't start `FROM base` has no shared tail,
and an update with no `build` runs it from the beginning. The bare
template is `scratch`, as in Docker.

`previous` carries files, not modules (its module versions are the old
ones), so a stage built `FROM previous` `USE`s its modules again; a stage
built `FROM` another stage of the same Wrappfile carries its modules over.
A target that starts `FROM base` `USE`s again what it calls all the same,
since on an update `base` is the chain's result, whose stages may know a
module by another name or not at all; for a module already there, that
only adds its name. `USE` on a stage that already has the
module's set-up doesn't redo it: the Wine module keeps the prefix it finds
rather than making one, and moves it to its own Wine if another made it.

#### A prefix follows its Wine

(Decided 2026-11-02, replacing an explicit `WINE.UPDATE-PREFIX`.) The
Wine version that made a prefix is recorded with each layer. When `USE
wine` finds a prefix another Wine made — built `FROM previous`, or `FROM
steam/client` under another version, or from any stage that `USE`d a
different Wine — it moves the prefix to its own:

- **Within the same major version, automatically**: `wineboot -u` under
  this Wine, in the module's environment. It works in either direction
  (validation A10 moved a prefix from 10.0_8 down to 10.0_6, and it played),
  takes 40–50 s on a loaded Mac and rewrites only Wine's own files. It is
  logged and shown as a step ("Updating the game's Windows files"), and is
  a layer of its own, so it happens once for each starting point and Wine.
- **When nothing is known to work, the person is asked** (decided
  2026-11-02). Constraints say what is known to work: each module's (Steam
  needing `wine@>=10`), the stage's own `USE wine@…`, and that a prefix
  moves only within a major version, which is all that has been tested.
  When some Wine satisfies all of them, the build takes it without asking.
  Only when none does — this stage asks for Wine 11 and the prefix it starts
  from was made by Wine 10, say, or the Wine this stage asks for is one
  another module in it doesn't list — are the choices put to the person,
  each saying what isn't known to work about it: keep the Wine the prefix
  already has (against this stage's own constraint), move the prefix to
  the Wine this stage asks for (across a major version, or against another
  module's), or cancel. Trying one is better than having no way to build at
  all. In plain words: "This game is set up for a newer version of the
  software that runs Windows games than the one Second Chance already has
  ready. It can keep the one it has, or try the newer one. Either may not
  work." A headless build fails unless an environment variable answers.
  The answer is recorded in the lock, and a wrapp built on a combination
  its bundle and modules don't list says so in reports.
- **A combination that can never be met is still the author's to fix.**
  `sc bundle check` warns when a bundle's own constraints can't all be
  satisfied together (its `USE wine@9` in a stage built `FROM
  steam@2/client`, whose Steam lists only Wine 10 or later), so a bundle
  doesn't ship relying on the question.

**An update reads the Wrappfile's global `ARG install-dir`**, as any
stage does (decided 2026-11-02). The old wrapp's lock records the value it
was built with; if the two differ, the chain must include an update that
moves the program, or the build is a fresh one, and `sc bundle check` warns
about a bundle that changes the global `ARG` without such an update. The
lock's other recorded values are read as `previous.*` in conditions
(`previous.bundle<4`).

**The player's files are not connected while an update runs** (decided
2026-11-02, after the review). In a played wrapp, the prefix's
`Documents` and A: drive are links to the person's real folders, and they
come along with `previous`; so before any step runs, every volume's link
and drive in `previous` is replaced with an empty placeholder, and `COPY
--from=previous` leaves out any path that is a volume. An update that
genuinely has to change the person's files — a patch that repairs broken
saves — opts in on that step with a `volume` mount, a type of our own
that reuses Docker's word for what a volume is:
`--mount=type=volume,source=wine-documents`. The person is told before the
update starts that it will change their saved games, the volume is copied
aside first (and restored if the step fails), and only that step sees it.

**Or the edition's own stage, with a condition**, for a program simplest
to build afresh with only its getting replaced, such as a one-exe
shareware program. Whatever changed, updating it is the same — build
afresh, and copy the exe from the old wrapp rather than download it — so
one update with no `from` and no `build`:

```yaml
updates:
  - id: "refresh"              # no `from`: any old wrapp; no `build`: the edition's target
```

```dockerfile
ARG install-dir="C:/SkiFree"

FROM scratch AS download
ARG install-dir
USE wine
IF updates
  COPY --from=previous ${install-dir}/ ${install-dir}/
ELSE
  COPY --from=game . ${install-dir}/       # the edition's download input
END
```

SkiFree's update copies its exe only so the rest can be built afresh, so
it is `refresh`, not `copy-exe`.

**Conditions on updating** read `updates`, the list of updates this build
applies, known before anything runs and the same in every stage (empty on
a fresh build). `IF updates` holds when it isn't empty; `IF updates has
<id>` when it includes that update, which any stage can ask, the shared
tail included:

```dockerfile
FROM base AS disc
USE wine
IF updates has from-wine-9
  # Wrapps built on Wine 9 carry a DirectDraw override that Wine 10 and
  # cnc-ddraw don't need. Only a chain that came through from-wine-9 has
  # it.
  wine.REGISTRY --remove "HKCU/Software/Wine/DllOverrides:ddraw"
END
```

The author picks whichever form is simplest, and both can be in one
bundle. A condition suits an update that is an instruction or two, as
SkiFree's; once it grows — several instructions, branches, anything
nested — it belongs in a stage of its own, and `sc bundle check` suggests
that for an `IF updates` branch past a few lines. `sc bundle check` also
checks every `updates has` names an update and every target names a
stage, and warns about an update that can never apply.

**What is cached:** branches need nothing special — a layer's key is
chained from its parent's and made of the instructions that ran, so the
branch an `IF` took is in it, and a different branch is simply a different
layer. The one rule: nothing taken from `previous` is cached, nor any layer
after one that was, since the old wrapp has been played in and no key can
describe its contents. The fresh stages and the shared tail on a fresh
build are cached as usual. The new wrapp's lock records the chain
("updated from bundle 3 and Wine 9.0_2 by `from-wine-9`, then
`taffy-patch`"), for reports and the next update.

**What lives in the prefix outside a volume** keeps through an update and
is lost in a fresh build. For the Nancy Drew games that is nothing of the
player's (validation L5, first pass): of five Wine wrapps read, none kept
settings, progress or a CD key in the registry, and their settings files
and saves are in `Documents`, already a volume. What a fresh build loses is
Steam's own state in the prefix (its keys and `local.vdf`), which the shared
sign-in already stands in for. So volumes need no registry kind for now;
one can be added when a program is found that needs it. Only two of the
five had been played from the copy read, so the older games are still to
be played and checked.

**A new major engine version** (Wine 10 to 11) is no different: an update
from `wine: "10"`, if one is written and tested, else a fresh build. Wine 11
doesn't start in today's wrapper yet (A10), so that is packaging work first.

The grammar gains `ELSE`, the `updates`, `updates has <id>` and
`previous.*` conditions, and `previous` and `base` as stage names.

## Building

1. **Load** the bundle and the modules it uses, and settle the edition
   (detected for a brought source, picked for a chosen one), the variant
   and the other choices. Move in any former bundle ids' folders
   ([Volumes](#volumes)).
2. **Validate** the manifest against the schema, and the whole Wrappfile
   against the core grammar and each module's schema. Unknown
   instructions, options or mount types fail here, not twenty minutes in.
3. **Resolve** module versions, and the newest release providing each.
4. **Plan what can be planned.** For a rebuild, work out the update chain
   from the old wrapp's lock, or that it must be a fresh build, and say
   whether it needs the disc ([Updating a
   wrapp](#updating-a-wrapp-decided-2026-11-02)); then the stages and
   layers, and every key whose inputs are known. A key that depends on
   something only the run can find — a Steam app's build id, which needs
   Steam signed in; a disc that is asked for only when first needed — is
   worked out when its layer is reached. A rebuild knows more of them up
   front, from the identities its old wrapp's lock records.
5. **Run**, restoring each layer from the cache where its key is there, and
   building it otherwise. An install that went somewhere other than its
   `--into` gets that path linked to where it went.
6. **Assemble** the final stage into the wrapp by cloning, then lay the
   current template's runtime files over it, then write
   runtime settings and the lock, `Info.plist` and the icon, and sign — the
   uncached tail.

The builders become the interpreter: `WrappBuildStrategy` stays as the seam,
but one Wrappfile-running strategy replaces the three per-source builders,
which shrink into their source modules. The bus events stay the contract —
each step and module publishes the same progress the builders do now, so the
UI and integration tests don't change.

### Layers

- **Automatic by default.** Instructions (core and module ones) declare
  whether they are expensive. Each expensive one ends a layer; cheap ones
  join the next expensive one. Boundaries depend on our costs — clone time,
  Wine start-up, load — so they shouldn't be written into every bundle.
- **`LAYER` … `END`** overrides that, grouping steps into one layer. Within
  a group the Wine session stays up: an installer and two patches in one
  group start Wine's desktop once.
- A layer boundary is where Wine is shut down (so the registry is flushed)
  and the stage's filesystem is cloned. **A layer is sealed only after the
  session ended gracefully or with `wineserver -k`**: the registry lives in
  wineserver's memory until it exits, and `-k9` loses it (validation A5),
  so a step that was killed throws its layer away.
- The clone costs ~0.15 s for a whole wrapp; ending and starting the Wine
  session costs 5–9 s idle and far more on a loaded Mac (A1, A2). Install
  and patch steps already end their sessions, so boundaries after them are
  free (J3).
- `sc wrapp build --layer-every-step` makes every step its own layer, for
  finding which step of a group broke.

### Cache keys

A layer's key is a hash of:

- the parent layer's key (chained, as flatpak-builder does);
- the normalised instructions in the group, as they ran, so the branch an
  `IF` took is in it;
- the content hashes of every bundle file they reference (`COPY`, `bind`);
- for each module whose instructions ran, its resolved version and the
  hashes of the files those instructions used, data and build code alike,
  and the core's build code the same way ([Engine
  versions](#engine-versions));
- the values of the choices the group reads, the variant among them;
- the result of any Mac condition (`arch=arm64`), since the Mac building
  decides it;
- the identity of any input it mounts or copies, and the hash of anything
  it `ADD`s or `fetch`es.

Nothing taken from `previous` is keyed or cached, nor any layer after
one that was ([Updating a wrapp](#updating-a-wrapp-decided-2026-11-02)).

**What the wrapp runs is never in a layer** (decided 2026-11-02, after the
review). `FROM scratch` today would clone the whole `WrappTemplate.app`:
its launcher, the in-process helpers and the rest of its runtime code. So
either every edit to launch code would miss every cached install, or a
cache hit would hand out an old launcher. Layers hold only what the build
made — the engine, the prefix, the program — and `scratch` is keyed on the
engine and the prefix set-up alone. The current template's runtime files
are laid over the final stage at assemble, every time, as `sc wrapp
update` already does today, and the same goes for an update built `FROM
previous`, so a launch fix reaches every rebuilt and updated wrapp.

**A skipped step has a key of its own** (decided 2026-11-02, after the
review). A step skipped with `--on-failure` keys its layer as skipped, not
as done, so the layers after it are reused only by a build that skips it
too. Every build tries a skipped step again, even when that skipped layer
is in the cache, since the point is to fix it; the skipped layer is kept
only as the parent of the cached layers after it, never as a result. If
the step now succeeds, the layers after it are built afresh on top.

Inputs, never outputs: what Wine writes isn't deterministic, and doesn't
need to be.

Identities that avoid reading big things:

- **Downloads with a declared hash** (`ADD --checksum=sha256:… <url>`) are keyed by that
  hash (Nix's fixed-output steps). Nothing is fetched to compute the key;
  the download happens only on a miss and is checked afterwards.
- **Steam** is keyed by the app's build id from Steam's app info, a small
  query, but one that needs Steam signed in, so a Steam layer's key isn't
  known before the sign-in. **(validate B2: that the build id can be read
  before the app is downloaded.)**
- **A disc** is keyed by a hash of its file listing — every path and
  size — which takes under a second including mounting, and works the same
  for a real disc, an image or a copied folder (validation B1). Hashing the
  start of an image is useless (its first 32 KB are empty).
- **A download with no hash** is keyed by its ETag or Last-Modified where
  the server gives one, otherwise kept until asked to refresh; validation
  warns that it isn't reproducible.

**Every layer stores its key's inputs next to it**, not only the hash, and
`sc wrapp build --explain-cache` says why each layer missed ("`assets/disc.iss`
changed", "`wine`'s `stages/prefix` changed in release 15"). Flatpak and Docker both have
long-running reports of cache misses nobody could explain.

### The layer store

- In `~/Library/Caches/SecondChance/layers/<key>/`, each a directory plus
  `key.json` (the inputs) and `meta.json` (size, created, last used).
- Built by `clonefile(2)` of the parent; a layer is renamed into the store
  whole, never seen half-written (as the prefix cache does now).
- **Same volume only.** Clones need the store and the build on one APFS
  volume; otherwise the build copies, and says so in the log.
- **The final wrapp is a clone too,** so it shares blocks with the layers
  until the game changes them.
- **Always in `~/Library/Caches`, pruned by use** (decided 2026-11-02).
  Every time a build restores a layer, or builds one on top of it, its
  `meta.json` records the date (file access times can't be trusted for
  this). Second Chance and every wrapp prune the store — a wrapp too,
  since someone may play for months without opening Second Chance — at
  most once a day, off the main thread, under the store's lock: a layer
  unused for 30 days goes, and so do the least recently used beyond a size
  limit. A layer that shares blocks with an installed wrapp frees nothing
  when it goes, so sizes shown to anyone, and the size limit, count only
  what a delete would actually free. `Caches` is also what macOS may empty
  itself when the disk is nearly full, and is left out of Time Machine.
  **(validate: sizes, and the pruning ages.)**
- **A layer keeps the events its steps published**, and a cache hit
  publishes them again, so the UI and the integration test see the same
  `installerResolved`, `patchApplied` and `gameExeDetected` whether a layer
  was built or restored, and the cached path is tested too.
- Concurrent builds (the integration tests build side by side) take a lock
  per key, so two builds needing the same layer build it once —
  `WineManager.prefixCreation`'s rule, generalised.
- Today's prefix cache becomes the `USE wine` layer, keyed properly — which
  removes AGENTS.md's "run `sc clean wine-prefixes` after changing prefix
  set-up".

### Developer tools

- `sc wrapp build <slug> --target <stage>` builds one stage and stops, to
  look inside it (Earthly).
- `--explain-cache`, `--layer-every-step`, `--no-cache`, `sc clean layers`.
- `sc bundle check <path>` validates a bundle without building.
- `sc module check <path>` compares a module release with the one before
  it ([Engine versions](#engine-versions)).
- `sc bundle list --where <path>=<value>` filters bundles by any manifest
  field, written as a path into the manifest: `--where
  notes.installer=installshield`, `--where series="Nancy Drew"`, `--where
  editions.source=steam` (any edition). So the notes can answer "which
  games use InstallShield?" and the same flag serves every other field.
- **Later: tools for writing bundles**, such as measuring what each step
  writes to fill in `--needs-space`, recording an InstallShield answer file
  from a run of the wizard, and making needles from a failed run's
  captures ([Testing](#testing)).

### The builder, kept apart

(Decided 2026-11-02.) Second Chance may one day release what turns a bundle
into a wrapp as a command-line tool of its own. That tool isn't part of
this plan, but the plan keeps the code that would make it apart from the
app from the start, since pulling it out of an app later is much harder
than keeping it out now. In short, **the builder is a library the app
uses, not part of the app.**

- **A package of its own** (`Packages/WrappBuilder/`, say), holding
  everything from a bundle to a wrapp on disk: loading and checking
  bundles and modules, the Wrappfile parser, planning (updates included),
  the layer store and cache keys, detection, the modules' build facets and
  the source modules, and assembling and signing the wrapp. This overrides
  D2, which left the build facets in the app target. It is a package rather
  than a target in SecondChanceKit's for the reason `GameCatalog` is one:
  anything depending on the SecondChanceKit package fetches Sentry too.
- **It depends only on what a command-line tool could ship with**, and
  nothing it depends on is Second Chance's (decided 2026-11-02, after the
  review). SecondChanceKit is one target today, holding everything shared;
  at the start of phase 2 it is taken apart, along these lines (names to settle):

  | Package | What moves into it | Used by |
  | --- | --- | --- |
  | `Wine` | the Wine library: `Wine`, `WineCommand`, `WineProcess`, the registry, the server, the desktop, drives, `WineError`, the watchdog | the `wine` module's build and runtime code, `installer`, `steam` |
  | a process package | `Blocking`, `ProcessList`, `ChildProcess`, `SystemLoad`, `DirectorySize`, running and logging subprocesses (`TaggedProcess`, `ProcessLineLogger`, `SubprocessLineClassifier`, `SubprocessWatch`) | everything |
  | a logging package | the swift-log handlers: `LogStore`, the multiplex and OSLog handlers, the JSON-lines sink, `LogContext`, bootstrap | everything |
  | `WindowsFormats` | the readers of Windows programs and MSI files: `WindowsExecutable`, `MSISummary`, `CopyProtection` | `installer` (recognising a family), detection's matchers, the `wine` module's runtime (`GameGraphicsAPI` reads a game's imports) — a package of its own, not inside `installer`, since `wine` would then depend on `installer`, which depends on `wine` |
  | `WrappFormat` | what a wrapp holds: `WrappLayout`, `WrappSettings`, `WrappSource`, the lock | the builder, the wrapp's runtime, WrappPuppeteer |
  | the modules' own packages | Steam's client, session store, caches, VDF reader, logs and watches into `steam`; `GameQuitCheck`, the helpers' variables and report into `wine`; `HerEngineLog` into `nancy-drew` | the builder and the runtime |

  What stays in SecondChanceKit is Second Chance's own: the loading window
  and its stages, the log window and its views, `SteamSignInWindow` (the
  `steam` module asks for a sign-in through the builder's asking protocol,
  and the app shows the window), `NewerRelease`, `AppTranslocation`, crash
  markers and failure summaries. The builder's isolation is decided then
  too: the packages default to the main actor (AGENTS.md), and the
  builder's code says `nonisolated` where it runs off it, an exception
  AGENTS.md records.
- **Everything it needs from the app comes in through its inputs, as
  protocols with a headless implementation beside the app's**:
  - **Asking the person** — a choice, the next disc, which program is the
    game, whether to go ahead with an update that needs the disc. The app
    answers with its windows; the headless one answers from settings or
    environment variables, as `WrappBuildInput` does today, and a later
    command-line tool from its flags.
  - **Progress**: the typed events on the bus the build is given. The
    build events move into the builder package; `AppEvent` wraps them for
    the app.
  - **Failure reports**: the builder says what failed, as a value; the app
    decides whether and how to report it, as runtime facets return a
    `ModuleFailure` for the wrapp's core to report (D2).
  - **Where things are**: the bundle and module search paths, the layer
    store, the download cache, the wrapp template, the engines. The app
    passes its own (its resources, its Application Support folder, its
    caches); nothing in the builder reads `Bundle.main` or names "Second
    Chance"'s folders itself.
  - **Steam's sign-in**: the builder takes one, as a `secret`; signing in,
    which needs a window, stays with the app.
- **No main thread.** The builder never needs the main actor; it runs as
  the app's build does today, off it, and a command-line tool would have
  no run loop to lend it.
- **Two clients from the start, so the seam stays honest**: the app, and
  the builder's own tests, which build wrapps (to a stage, at least) with
  no app at all. `sc wrapp build` keeps running the app for now, since it
  tests what people use; whether it should call the builder directly is
  decided with the tool, not here.
- **What a separate tool would still need** (not done here, written down
  so it isn't forgotten): the wrapp template and engines as things it can
  be pointed at or download, rather than resources inside an app;
  `SecondChanceReporting` in a package of its own, so SecondChanceKit's
  stops fetching Sentry; and its own name for the folders it uses.

### What today's builds do that a plain `RUN` can't

(Checked against today's builders, 2026-11-02.) Nothing today's code does
is out of reach, but these need saying, as the examples above show only
the plain case:

- **Installing as today does takes a module of its own,
  `installer`** (decided 2026-11-02), not a bare `RUN`, and not
  one module per installer family: the families share most of the work,
  and having the Wine module work out the family and hand over would put
  installer plumbing in Wine. `installer` depends on `wine`, has
  Swift (shipped), and owns everything about running a Windows installer:
  recognising its family (InstallShield, Inno Setup, MSI, as today's
  `detectInstallerType` does), each family's silent flags, answer file and
  log, the AutoIt driver for an install that never exits, the stall watch
  and what it tells the person, the check that the install finished
  (`InstallCompletion`), the fallback to the installer's own wizard when
  the unattended install fails and someone is there (never headless or
  under test), and installing where the bundle says (`--into`), with a
  link there if the person chose somewhere else ([What a wrapp
  launches](#what-a-wrapp-launches-decided-2026-11-02)). Its instruction is `installer.RUN`
  (named `installer`, decided 2026-11-02, as `windows-installer` read like
  installing Windows, and a `WIN.` prefix like a module called `windows`):

  ```dockerfile
  USE installer
  USE nancy-drew                  # for the AutoIt script below

  # One option each: --into=${install-dir}, which a real install gives, is
  # left out for brevity

  # The family worked out, with its usual silent flags
  installer.RUN D:/setup.exe

  # The installer found as today's code finds it (setup.exe, install.exe, an .msi)
  installer.RUN D:

  # Most Nancy Drew discs: InstallShield, silent from its answer file
  installer.RUN D:/setup.exe --answer-file=assets/disc.iss

  # A silent install that never exits: AutoIt clicks through it (today's
  # Old Clock, Haunted Carousel, …); the script is a module's asset
  installer.RUN D:/setup.exe --answer-file=assets/disc.iss \
      --mount=type=bind,from=nancy-drew,source=assets/installshield-custom-dialog.au3,target=C:/driver.au3 \
      --driver=C:/driver.au3

  # No answer file (Thornton Hall's disc): the installer's wizard, with the person
  installer.RUN D:/setup.exe --interactive

  # Family-specific options, checked against the family worked out
  installer.RUN D:/game.msi --msi-properties="SOMEPROP=1"   # --into sets an MSI's folder
  installer.RUN D:/Setup.exe --family=installshield --args="/s /sms"

  # A game whose wizard is known to break the install: fail instead of falling back
  installer.RUN D:/setup.exe --answer-file=assets/disc.iss --no-wizard-fallback
  ```

  `--answer-file` means each family's own kind (an `.iss`, an Inno Setup
  `/LOADINF` file, an MSI transform), and an option only one family has is
  named for it (`--msi-properties`); one that doesn't fit the family worked
  out is an error before the build starts where the family can be told from
  the file, at the step otherwise. Every option has the default today's
  code uses, so most Nancy Drew bundles write one line; `nancy-drew` can
  wrap the AutoIt case in a function (`DO nancy-drew.install --installer=D:/setup.exe --stubborn --into=${install-dir}`).
  Today's per-game `GameInfo` flags (`doesNotExitInNonInteractiveMode`, the
  answer file) become these options. A later family (NSIS, Wise) is more of
  this module, and a DOS installer under DOSBox is DOSBox's. A plain `RUN`
  is for an installer that needs none of this. **A step whose outcome
  decides what happens next is always a module instruction**, written in
  Swift, since a Wrappfile has no way to look at a result: the wizard
  fallback, and Her's launcher being unpacked or else run as it is
  (`her-download.INSTALL`).
- **A step can be allowed to fail, with a question** (C1's
  `--on-failure`). Today a patch that fails asks whether to carry on
  without it (`PATCH_FAILURE_POLICY` headless). Any step can say
  `--on-failure=ask`, `continue` or `fail`, the default.
  **Every step can say what it is for, in plain words** (decided
  2026-11-02): `--describe="the fix for the taffy-sorting puzzle"`. That
  text names the step in its progress line and its error, and builds the
  question: "Second Chance couldn't install the fix for the taffy-sorting
  puzzle. The game will still work without it. Carry on?" — the second
  sentence from `--if-skipped="…"`, or left out. A step that needs other
  words entirely gives them with `--ask="…"`. A function fills these from its
  data (`nancy-drew.patch` from the patch's title), so bundles rarely write them; a
  step with none is named by its instruction, as today's log does. Every
  build tries a skipped step again ([Cache keys](#cache-keys)), and the lock
  records what was skipped, for reports and for an update's
  `previous.skipped has <name>` condition to catch up on. **A step is named
  with `--name=<id>`** (decided 2026-11-02), an option any step takes, for
  conditions and reports; a skipped step is recorded by that name, and
  `nancy-drew.patch` names its step `${id}`.
- **An executor may retry a step that failed for a reason outside it.**
  Today a Wine program that couldn't reach a display (`WineError.noDisplay`)
  restarts the Wine session and runs once more. That stays the Wine
  executor's, for any `RUN` or module instruction, logged as a retry; a
  bundle can't ask for retries.
- **Discs are asked for one at a time, when first needed**, since a Mac has
  one drive: the disc source asks for the next disc only once the one
  before is copied, checking its `requires` file. A step can mount only one
  disc that hasn't been copied in. A multi-disc installer that expects every
  disc's files in one folder gets one: `wine.KEEP-DISCS --combined=<path>`
  adds a folder of links to all of them, as today's `disk-combined`.
- **What isn't recognised can't be installed anyway** (decided
  2026-11-02): with no program identified there is no Wrappfile to follow.
  So in phase 12, the last, the question's choices become: choose another disc or download;
  **pick which program it is**, from the bundles with an edition for that
  source, and then the edition if there is more than one; or cancel. A near
  miss is offered first, with a warning in plain words that Second Chance
  can't be sure ("This looks like it might be Last Train to Blue Moon
  Canyon, but Second Chance couldn't confirm it. Building may not work.").
  The build then follows that edition's Wrappfile, its `requires` files
  still checked, and the wrapp records that the program was picked rather
  than detected, for reports. A headless build fails unless
  `EXPECTED_GAME_SLUG` (the expected program id) names the program. A
  folder holding an already installed game rather than an installer is
  turned down before detection, as `GameDetector.isInstalledGame` does, by
  the disc source.
- **Room to build is checked before anything runs, and again as it goes**
  (decided 2026-11-02). First, as today (`notEnoughSpace`), from the
  inputs' sizes (a disc's listing has them), each module's own (an engine,
  a prefix) and the layers the plan has to build rather than restore, so
  the person hears before a long build starts. If evicting cached layers
  would make room, they are asked rather than layers being thrown away. But
  free space changes while a build runs, so every step that writes checks
  again before it starts: a `COPY`, `ADD` or `fetch` knows its size; a
  `RUN` or an install uses `--needs-space=` when the bundle gives it, and
  otherwise an estimate (twice the input it installs from). A bundle can
  carry a measured figure there: the bundle-writing tools planned for later
  can run each step, measure what it wrote and fill it in. And a step that still runs out — `ENOSPC`, or a Wine
  program failing while the disk is nearly full — is told apart from any
  other failure. Either way the build **pauses rather than failing**: it
  says how much more is needed, the person frees space and chooses Try
  Again, and only that step runs again, from the last sealed layer, so
  nothing before it is lost. A headless build fails with the amount
  needed.
- **Debug switches carry over**: `--skip-installer` becomes building with
  install steps skipped (`sc wrapp build --skip <instruction>`),
  `STRICT_INSTALL` turns off `installer.RUN`'s wizard fallback, and
  `EXPECTED_GAME_SLUG` names the program id detection must find. The old
  environment variables keep working until phase 5 is done, so `sc` and the
  integration tests don't all change at once.

Everything after the build — the loading window, the save warning, the
quit check, diagnostics, the in-process helpers, the Steam lock, mode
scaling — is runtime, and moves into the modules' runtime facets as it is
(D1 placed every site).

## Detection

- **Today's matcher is the default** (decided 2026-11-02, after the
  review). Main's `GameDetector.slug(forFingerprint:among:)` is already
  data-driven: it matches a program's title (less a leading "The"), its
  aliases and its capitalised codes against a fingerprint of the disc's
  signals, so a new program is recognised by its title with nothing
  written. That becomes the core's default matcher, built from the
  manifest's `title` and a `detect.aliases` / `detect.codes` list, and a
  bundle writes matchers of its own only for what titles can't tell apart.
  Its tie rule changes deliberately: where two match, the longer match wins
  (Remastered over Secrets Can Kill, as today's "another game's title
  contains its title" does), and a true tie is asked about rather than
  going to whichever game comes first in the catalogue.
- Each bundle's `detect` matchers are compiled into one index at start
  so detection over hundreds of bundles stays fast.
- Core matchers: file exists (glob), string in file (CrossTie), md5 of the
  first N bytes plus size (ScummVM's AdvancedDetector), Windows exe version
  info, MSI summary, volume name. Modules add more (ScummVM's own
  detection; Steam app id).
- **Matchers have no order** (F1). When more than one matches, the most
  specific wins — the longest matching text — which is how Remastered wins
  over Secrets Can Kill, whose title it contains, without a priority
  field; a real tie is asked about. On the 33 discs here no two bundles
  matched at once. The seven case-sensitive disc codes today's chain relies
  on (` SEA `, ` LIE `, …) become a matcher kind of their own, "a word,
  case-sensitive", so it's visible which bundles depend on the riskiest
  kind of pattern.
- **Look before asking.** As Porting Kit does, check mounted discs (and,
  if the person allows, Downloads) for each input's `requires` file before
  showing a file picker. Detection still decides what the file _is_:
  Porting Kit trusts filenames alone, which can't tell the wrong edition.
- **No bundle at all.** A program nothing recognises isn't built: the
  person picks which program it is, or another disc
  ([above](#what-todays-builds-do-that-a-plain-run-cant)). Today's
  `unknownGame` path, which installs as "Other", goes in phase 12 (decided 2026-11-02:
  without a Wrappfile there is nothing to follow). Asking which installed
  program is the game stays, inside `installer.RUN`, for an edition that
  doesn't say (shallowest first, then largest, uninstallers last; done in
  today's code).
- **Near misses are reported**, as ScummVM asks for unknown MD5s, so
  editions not recognised yet show up. A near miss follows the person's
  failure-report setting like any other report (decided 2026-11-02): none
  when reports are off; in a **basic** report, the bundle that almost
  matched and which kinds of signal the source had (`exe-version`,
  `setup.ini`, `msi`) but not their text, which can hold whatever an
  installer put there — and for a hash matcher, the file's name on the
  disc, its size and md5, as ScummVM sends its own team; in a **detailed**
  report, the signals' text too, redacted as the rest of a detailed report
  is (F3, [docs/failure-reports.md](../failure-reports.md)).

## Runtime

### Runtime settings are not layers

The launch, volumes, environment and module runtime options, all from the
manifest, are written
to `AppSettings.plist` in the uncached tail. Changing how a game launches
never invalidates a layer — the fast loop for tuning a game. `WrappSettings`
grows into the image config: the resolved modules with their versions and
releases, the bundle id and its own version, the volumes, module settings by namespace. Old keys keep
being read, so existing wrapps still launch.

### Volumes

What's done ad hoc now — A: and `Documents` pointing at Application Support,
ScummVM's `--savepath` — becomes the manifest's `volumes`. Each module realises a volume its
own way (Wine: a drive or a symlink in the prefix; ScummVM: `--savepath`),
the way Flatpak's `--persist` maps a folder into an app's storage. Because
user files live outside the wrapp, rebuilding with a newer engine is safe, and is
the answer to "Porting Kit wrappers broke when macOS changed".

**User files** are what the person makes and keeps — a game's saves, a
program's documents — as opposed to its settings. "Saves" would make
Second Chance about games; "data" is already a module's data. People are
told about them in the words of the volume they are in
(its `display-name`), so a program with saved games in one volume and
screenshots in another can call each what it is.

**A volume is storage; `in-use-when` says when it holds the person's files**
(decided 2026-11-02). A bundle declares as many volumes as it likes and
keeps whatever it likes in them. A program's own settings aren't user
files, but they are kept the same way, and the program, not the bundle,
decides where each file goes: Her's games write their INI beside their
saves, so the two can't be put in volumes of their own. So each volume
says which of its files are the person's, which is what the variant
choice, the move of old folders and the wording all need — "the folder
isn't empty" would count a game played once as having saves:

- `in-use-when: any-file`, the default: anything in it is the person's.
- `in-use-when: never`: it only ever holds the program's settings.
- `in-use-when: <pattern>`, or a list of them: a folder that mixes the two;
  the files that match are the person's.

(Named 2026-11-02 for what it is, a test of whether the volume holds real
data, and `display-name` for what people are told it holds, as the
manifest's own `display-name` is what they are told the program is
called.)

A pattern may use a value a module recorded at build time in the wrapp's
settings, written as the module's name, a dot and the value
(`${scummvm.game-id}.[0-9]*`: today's wrapps run ScummVM with
`--auto-detect` and record no id, so the ScummVM module's build runs its
detection once and records the id in the wrapp's settings). Such values
are read only by runtime settings, a volume's `in-use-when` among them,
and are never a Wrappfile substitution (decided 2026-11-02). Patterns have
module defaults: the `nancy-drew`
module's `*/*.Hi*Save`, `*/*.SAV` and `*/HICONTINUE.*` (the continue slot
is progress), ScummVM's `${scummvm.game-id}.[0-9]*`, which leaves out its
`timestamps` file. A settings file or log left by one launch never counts:
most Wine games write their INI on first launch (L2).

**The A: drive** belongs to a volume's mount, as a Wine module option on
it (`wine: { drive: "A:" }`). Today it points at the same folder as `Documents`, and
generated Nancy Drew bundles keep that, giving `wine-documents` the
drive.

**Volumes are declared by name and mounted by name, as in Compose**
(decided 2026-11-02). The manifest's top-level `volumes:` is a map keyed
by name, holding what belongs to the volume — `in-use-when`,
`display-name` — and a variant's or edition's `volumes:` list mounts them,
in Compose's long form: `source` (the name), `target` (the path in the
wrapp) and how this engine mounts it (`wine: { drive: "A:" }`). Compose's
short form, `name:path`, isn't used, as `C:/…` and `scummvm:saves` have
colons of their own. A volume's name is unique in the bundle, and it is
the folder its files are kept in.

**A module can declare volumes too**, in the same map in its
`module.yaml`, with a default `target`, and any bundle whose stages use
the module can mount them by name: the ScummVM module declares
`scummvm-saves` once, its `in-use-when` included, so no ScummVM bundle
repeats it and none can drift from it. A bundle's own entry with that name
is merged over the module's, field by field, as Compose merges, so changing
`display-name` is one line; two modules declaring one name is a validation
error. **A module's volume names and targets are permanent**: renaming
one in a new release would leave everyone's files in the old folder, so
`sc module check` treats them as it treats an instruction, kept within a
version.

Variants (and editions) that mount the same volume share it, whatever path
each mounts it at; any that mount different volumes don't. So sharing is
decided per volume, not per variant: a Wine and a DOSBox variant can share
a `settings` volume and keep `wine-saves` and `dosbox-saves` apart. An
edition whose files mustn't mix with the others' (Steam Cloud keeping
them) uses names of its own. A name says what it holds, including the
engine when its files only make sense to one (`wine-documents`). Nothing
checks that two variants sharing a volume can read each other's files:
that is the bundle's say, as any name is. A variant can keep several
volumes (Cave Story's save and its settings file), each its own folder, so
two can't collide over a file name.

**User files have one layout, and existing ones are moved into it**
(decided 2026-11-02, replacing L3's "never move"): special cases for where
a program's files used to be would stay in the code for ever. Each wrapp
keeps everything of its own in its own folder, as a Mac app does, named by
its bundle id, with a folder per volume and Second Chance's settings for
the wrapp beside them:

```text
~/Library/Application Support/<bundle id>/
  volumes/<volume name>/
                       one folder per volume: the person's files and the program's own
                       settings (a game's INI beside its saves); a file or pattern
                       volume's folder holds its files
  wrapp-settings/      Second Chance's settings for this wrapp (the save-warning
                       choice), shared by every variant
```

**Bundles change the bundle id** ([Program ids](#program-ids-and-bundle-ids)):
today's wrapps are `au.gare.callum.SecondChance.nancy-drew.<slug>`, with
their saves loose in that folder (a Wine game's `Documents`, ScummVM's
`--savepath`). A wrapp built from a bundle has a new id, so a new folder,
and the old folder is free to become one link to it.

**Where the old folders are** is in the manifest, not worked out:
`former-bundle-ids` lists every bundle id the program's wrapps have had.
Generated bundles list today's (`au.gare.callum.SecondChance.nancy-drew.<slug>`),
so the move needs nothing from the code that knows how ids used to be made.

**An imported bundle asks before moving anything** (decided 2026-11-02,
after the review): `former-bundle-ids` is free text, so a bundle someone
writes could name another app's folder. Before the first move for a
bundle that didn't ship with Second Chance, the person is shown which
folder, the program it says it belonged to, and what is in it, with a
button that opens it in Finder, and chooses Move or Leave It. Shipped
bundles move without asking. Only shipped modules may declare old places
of their own (the ScummVM settings file, below).

**Every launch checks**, and so does every build: for each former id, an
`Application Support/<former id>` that is a real folder rather than a link
is moved in, as below. It is one `lstat` per former id, so it costs
nothing when there's nothing to do, and it also catches a folder that
reappears later, such as when someone restores an old backup.

- **The old folder becomes a symlink** to the one volume it was:
  `volumes/wine-documents/` for a Wine game (today's folder is its
  `Documents`), `volumes/scummvm-saves/` for ScummVM (its `--savepath`).
  Generated bundles name those volumes. A wrapp built before bundles that
  is still installed carries on finding its saves. Old wrapps never move anything; they only follow the link.
- **Which volume each of the old folder's files belongs to** comes from the
  volumes' `in-use-when` patterns, as the variant policy reads them. Second
  Chance's own settings files (it knows their names) go to
  `wrapp-settings/`; anything else goes to the volume the link points at:
  the one for the engine the program's wrapps used before bundles (its
  `GameInfo` engine). `GameInfo` keeps no history, so the generator reads
  which games were once Wine from `GameInfoProvider`'s git history, and
  gives each of them an `existing-files-only` Wine variant with its
  `wine-documents` volume. Globs match without regard to case, as the
  Mac's disks do. Ghost Dogs'
  old folder holds Wine and ScummVM saves side by side (validation L2): its
  Wine saves move to `volumes/wine-documents/` and the link points at
  `volumes/scummvm-saves/`,
  so a Ghost Dogs wrapp from before its move to ScummVM, if one is still
  installed, no longer sees its Wine saves. That is the one case a link
  can't serve, and a rebuild finds them.
- **Nothing is ever half moved.** A folder whose files all go to one volume is renamed
  whole into place (the same volume, so one atomic rename), its settings
  files moved out, and the link made last. A run cut short between the
  rename and the link finds the new folder and no old one, and only makes
  the link. A folder split between volumes moves file by file, each a rename,
  and is replaced by the link only once empty; a run cut short carries on
  where it stopped. Every step is logged.
- **Never overwrite** (decided 2026-11-02, after the review). A folder
  that reappears (restored from a backup) or a volume that already has
  files is merged, not renamed over: a file whose name is already taken in
  the volume stays, and the incoming one is kept beside it under a dated
  name (`HICONTINUE.SAV (from 2026-03-14).SAV`), logged, and the person told
  once that both are kept.
- **One mover at a time, and never under a running game.** The move takes
  a lock in Application Support, and is skipped, to be tried at the next
  launch or build, while any app with the old or new bundle id is running
  (an old wrapp may be saving through the folder being moved).
- **Builds honour the test folder too.** The builder's move uses the same
  `SECOND_CHANCE_APP_SUPPORT_DIR` as the wrapp, so a build under test
  never moves a developer's real files.
- **Everything else keyed by bundle id** is listed with the move, even
  where nothing moves: the played-in prefix copy in
  `~/Library/Caches/<bundle id>/prefix` for a wrapp that can't write to
  itself (moved with the rest), the Steam lock's holder id (re-taken under
  the new id), and macOS's permission grants (asked again; see below).
- **A later id change works the same way**: the old id's folder moves and
  becomes a link. It is one path through the code, used once for today's
  wrapps, not a special case kept for them.

**Files a module keeps by bundle id move too** (proposed 2026-11-02).
ScummVM's settings are in `~/Library/Preferences/<bundle id>.ini` today,
keyed by the old id. The ScummVM module points ScummVM's `--config` at a
`scummvm-settings` volume instead, and declares the old place
(`~/Library/Preferences/${former-bundle-id}.ini`), so the same check moves
it in and leaves a link. Any module keeping something by bundle id outside
the wrapp declares it the same way, so the move has no special cases in
the core.

**Tests move folders too, in a folder of their own** (decided 2026-11-02).
A test must never touch a player's real files, and the move should be
tested like everything else. So what a test sets names the equivalent of
`~/Library/Application Support`, not one wrapp's folder inside it: the
wrapp makes its `<bundle id>` folder in there and moves any former ids'
folders it finds there, exactly as it would in the real one. That changes
what `SECOND_CHANCE_DATA_DIR` means, so it is renamed
(`SECOND_CHANCE_APP_SUPPORT_DIR`) rather than quietly reused. A test of the
move puts an old layout in that folder before launching; every other test
starts it empty, as WrappPuppeteer does now.

A **folder** volume is a symlink; a **file** volume, or a pattern of
loose files beside the exe, is reconciled instead — a program saving by
renaming a new file over the old replaces a symlink with an ordinary file
(validation G1). When the session ends, and again at the next launch in
case it didn't get to, any ordinary file that has replaced the link moves
out to the volume's folder and the link is restored.

**One bundle id per program**, whatever the edition or variant (validation
K1): one Dock identity, and one set of permission grants (the microphone
prompt Steam raises). macOS ties a grant to the app's code signature as
well as its id, and a wrapp is signed ad hoc, whose signature names the
exact code, so a rebuilt wrapp is probably asked again; one signed with an
identity that stays the same across rebuilds (made once per Mac, say)
would keep its grants. **(validate: whether a rebuilt wrapp is asked
again.)** Two editions installed side by side **run one at a time**, as
today: a wrapp brings forward any running app with its bundle id and quits
(`main.swift`), which is also what keeps two from writing the same volumes
at once.

### The wrapp keeps its recipe

Each wrapp holds a copy of the bundle it was built from and the resolved
lock (module and engine versions, input identities, download hashes), as
Porting Kit keeps `pk_backup.wsi3` in each port. That makes three things
possible: rebuilding a wrapp from the same recipe, rebuilding it with a
newer engine or bundle, and a failure report saying precisely what the
wrapp was made of. (From the same recipe, not into the same wrapp: the
build's code — how `COPY` copies, what an installer instruction does — is
whichever Second Chance runs the rebuild, so a rebuild a year on can come
out differently, by design.)

A rebuild makes a **new** wrapp beside the old one and swaps them only
once it succeeds. Porting Kit re-runs the recipe over the live app, which
risks whatever is inside it; with user files as volumes there's nothing in the
wrapp to lose, and the old one remains until the new one is whole.

### What a wrapp launches (decided 2026-11-02)

There is no single `entrypoint` for a program: what starts depends on the
variant, the edition and the choices. The Wine variant of Blue Moon starts
`Game.exe` where the disc's installer put it, or where Steam put it;
ScummVM starts on the game's folder; a Steam game run
through Steam starts Steam with the app id instead. So a launch is put
together from three parts:

- **The bundle says where the program is installed**: a path it chooses
  and gives the install step, written once as the Wrappfile's global `ARG
  install-dir` (below), and the path a ScummVM variant copies the game
  from, into `/game`.
- **The variant says how it runs**, in its engine module's terms, using
  the edition's values: `launch: { wine: { exe: "${install-dir}/Game.exe" } }`,
  or `launch: { scummvm: { path: "/game" } }` (ScummVM's own
  detection names the game). Each
  module's schema says what its `launch` takes.
- **A choice can change it**, through a `when` on a launch: a Steam game
  with `launch-mode: steam` is started by the Steam module with the app id,
  which replaces the variant's launch. That is the only kind of override,
  so a bundle reads top to bottom as "this, unless that choice".

**A program goes where the bundle says** (decided 2026-11-02, replacing
the manifest's `game-dir` and then a variable the install step set: the
first was game-specific and a guess about something only the build knows,
the second a value appearing from nowhere). As Nix tells a build where to
install (`$out`) rather than asking it afterwards, and Concourse passes
named places rather than values, the install step is told where the
program goes, and Second Chance makes that true:

```dockerfile
ARG install-dir="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"

FROM prefix AS disc-install
ARG install-dir                               # brought into the stage, as Docker requires
USE installer
USE nancy-drew
installer.RUN D:/setup.exe --answer-file=assets/disc.iss --into=${install-dir}
DO nancy-drew.patch --id=blue-moon-taffy-sort --into=${install-dir}
```

- **The path is written once**, as an `ARG` before the first `FROM` — a
  global build argument, exactly as in Docker: a stage that reads it brings
  it in with `ARG install-dir` and no value, so which stages use it is
  plain to see. The manifest's launch reads the same global `ARG`
  (`exe: "${install-dir}/Game.exe"`), so the path is never repeated, and
  `sc bundle check` checks that every `ARG` a launch reads is a global one
  the Wrappfile declares.
- **Unattended installs go where they're told**: Inno Setup by `/DIR=`, MSI
  by `INSTALLDIR`/`TARGETDIR`. An InstallShield answer file already records
  its folder (`szDir`), so `installer.RUN` checks it matches `--into`
  before running and fails, in words for the bundle's author, if not.
- **An install the person steered elsewhere is linked.** When someone is
  running the installer's wizard (no answer file, or the silent install's
  fallback), they may pick another folder. After the install the step finds
  where the program went — Windows' uninstall key if the installer wrote
  one (`InstallLocation`; validation A11 found White Wolf's InstallShield
  writes it and Final Scene's doesn't), then the install's new files,
  looking for `--dir-contains=Game.exe` if given — and makes `--into` a
  link to it, logged. Several candidates are put to the person, likeliest
  first; none fails the build in plain words. Wine follows the link, so
  every later step and the launch work through the declared path, while the
  program's own registry entries keep its real folder.
- **Steam the same way**: `steam.INSTALL game --into=${install-dir}` links
  the path to Steam's folder for the app (`appmanifest_<id>.acf`), and
  when the stage later takes Steam away for a game launched directly
  (`steam.REMOVE`, which takes Steam out of the stage), the game's folder
  is moved to the path first, as today's `moveOutOfSteam` does. `her-download.INSTALL` takes `--into` too.
- **Nothing sets a variable behind the reader's back**: every value in a
  Wrappfile comes from an `ARG` line, global or a choice.

Precedence is the usual one (edition and variant, then the bundle, then
modules), so a launch the same for every edition is written once on the
variant, and an edition whose program differs (a demo's other exe) says
only that.

### Launch

The module named by the variant's `launch` starts the game; others contribute services that
start first (Steam), loading stages, quit checks and helpers. Two modules
claiming the launch is a validation error.

## Testing

- **Needles** (openQA): a reference, tags, and a click point given as a
  fraction of the match — which today's "8% in from the corner" and "half
  its height higher" already are. Three kinds, all in `WrappPuppeteer/Core/`
  today (H1): `screen`, a whole-screen fingerprint (the 36 splash PNGs);
  `region`, a template matched in a search area with a threshold and a
  range of scales (the quit button); and `text`, OCR strings and how they
  match ("Exit Game"). The splash recordings become needles — the
  `splash-any-*` ones in the `nancy-drew` module, the per-game titles in
  each bundle.
- **A scenario is a set of handlers, not a list of steps** (H1), which is
  what `clickExit` is today, written as data. Each handler has an id, the
  tag it waits for and what to do: "when `splash` matches, click its point,
  and again after 2 s if nothing changed"; "when `main-menu` matches, run
  the menu checks once, then click `quit` and expect the program to end";
  "when `her-logo` matches, click once". A scenario adds a goal (the
  program ends) and a timeout, and names tags, never files. The current
  `NancyDrewQuitScenario` becomes the `nancy-drew` module's scenario.
- **What isn't scenario data**: launching and quitting are core;
  dismissing the save warning, the cnc-ddraw first-click check and the
  picture frame check are the Wine module's test support; the menu checks
  are core checks a handler can ask for.
- `WrappPuppeteer/Core/` stays generic, as now; `WrappPuppeteer/NancyDrew/`
  becomes a scenario runner over bundle data.
- **Tests are the same for every edition by default**; an edition changes
  only what differs. In order of preference:
  1. **Needles by tag, nearest first.** A tag is looked up in the edition
     and variant, then the bundle, then its modules; as in openQA a tag may
     have several needles and any one matching counts. An edition with a
     different title screen adds a needle under the same tag and the
     scenario is untouched. Most differences between editions are visual,
     so this covers most of them. Scarlet Hand's
     `appName.contains("Scarlet Hand")` becomes a click point on its
     bundle's `quit` needle.
  2. **Parameters.** Scenarios take values (a wait, a retry) that an
     edition or bundle sets.
  3. **Handlers by id**, which an edition can add, `replace` or `remove`
     (Kustomize-style patches) — a handler that dismisses Steam's overlay,
     say.
  4. **Fragments.** Modules offer named sets of handlers
     (`nancy-drew/skip-splashes`, `quit-from-menu`) that scenarios are
     composed of. This shares between programs rather than editions.

  No `if edition=…` in scenarios: the four above cover it, and conditions
  would spread as they do in recipes.
- **The integration test uses the layer cache by default** (decided
  2026-11-02): a cached layer is used only when nothing it depended on
  changed, code included, and layers replay their events, so a cached run
  tests the same thing faster. **`--no-cache`** (Docker's flag, on `sc test
  integration` and `sc wrapp build`) ignores every cached layer and builds
  from scratch, for when it has to be certain things work with nothing
  cached; what it builds is still stored for the next run.
- The integration matrix becomes program × edition × variant; `--source`
  is the edition part of it today, and a retired variant can be tested
  less often.
- **Making needles from failures**: a command that turns a failed run's
  capture into a needle to edit, so testing a new game is mostly pointing at
  screenshots.
- Each bundle's tests run as `sc test integration <slug>`; detection
  fixtures move into the bundle too.

## Trust

Kept in proportion (decided 2026-11-02): a wrapp isn't sandboxed, and the
Windows programs a bundle runs can do nearly anything the person can.
What's worth doing is making sure a bundle's _own_ instructions do no more
than they say, and that where a bundle came from is clear — not trying to
contain the programs it runs.

- **A program in a wrapp can reach everything the person can** (I1, A4):
  Z: is the whole Mac, and Wine lets programs make Unix calls. So an added
  bundle is exactly as trustworthy as the installer it runs, and importing
  one says so, once, in plain words: "Only add games from people you trust.
  Like anything you install, a game can reach your files."
- **A bundle's own instructions stay inside the build.** A bundle is data:
  it runs programs only inside an engine, never on the Mac, and can't bring
  code into Second Chance (`native` is Second Chance's alone, and a function
  can only say what a Wrappfile could). The core checks what is cheap to
  check: paths in `COPY`, `MOVE`, `REMOVE` and `EDIT` stay inside the stage
  (no `..` out of it, no Mac paths, no following a link out); mounts name
  only the edition's inputs and the bundle's or a module's files; a volume
  is always a folder inside the wrapp's own in Application Support; and a
  download is only ever accepted with the hash the bundle gives.
- **Where it came from is shown.** Shipped bundles are signed with Second
  Chance; added bundles and modules are marked as added in the app and in
  failure reports, and an added bundle overriding a shipped one is logged.
- **No Mac drives unless a bundle asks for them** (decided 2026-11-02).
  This is for safety, not security: it keeps a broken program — an
  uninstaller that deletes too much, a game writing to the wrong drive —
  from reaching the person's files by accident. The Wine module gives a
  prefix only its own drives: C:, A: and the bundle's volumes, and the
  discs a Wrappfile mounts. Every other letter is blocked, as today, and Z:,
  which today shows the whole Mac, is gone too. A bundle whose program needs
  a Mac folder (a file picker that should reach the person's Documents)
  opts in, naming the folder and the letter, as a Wine module option on
  the variant — for the build or at launch, never by default. Anything
  Second Chance itself hands a Wine program is a path inside the prefix,
  never a Mac path (bundle assets included), so nothing of ours needs Z:
  either. Today's prefixes lose Z: in phase 5, when the builder first
  makes them, after an integration run of every game without it.
- **Not done, deliberately**: blocking Unix calls, which only a program
  written to make them uses, and reviewing or signing bundles people
  write.

## Phases (provisional)

Each phase leaves everything working, ends with the integration test
passing for every game, and updates the docs its change makes wrong (J2
lists which). Nothing a player notices changes until phase 12, the last; moving
their files into the new layout isn't something they notice, so long as no
saved game is lost.

1. **Bundle format and loading.** Define the manifest — editions with
   their inputs, variants, updates — and its JSON Schema, which a unit test
   checks every bundle against and `sc bundle check` checks one against.
   Generate one bundle per game from `GameInfoProvider` (J1's prototype),
   with an edition per source it supports today, Her's downloads as Her
   ever sold them ([below](#hers-downloads-for-phase-1)). `GameCatalog`
   stays Foundation-only, so `sc`, the wrapp and WrappPuppeteer needn't read
   YAML: its Swift table is generated from the bundles by `sc bundle
   catalog` and checked in, with a test that fails when it is stale (not a
   build plugin, decided 2026-11-02), and only the builder's package, which
   phase 1 starts with bundle loading, parses bundles. Fields with no reader (`failedInstallInfo`) or never set
   (`installInstructions`) are dropped or kept deliberately. Behaviour
   unchanged.
   **Done 2026-11-02**, with these interim choices, each to be revisited by
   the phase that gives the fact a proper home: `series-order` keeps the
   catalogue's order (detection ties and lists depend on it); a Steam input
   carries `common-folder` and `exe`, Steam's own folder under
   `steamapps/common/` and the program it starts, until the steam module
   reads them from the app's info (B2); `installer: { stubborn: true }` on
   an edition stands for `doesNotExitInNonInteractiveMode` until phase 4
   writes it as an `installer.RUN` option; the launch `exe` is a full `C:/`
   path until phase 4's `ARG install-dir`; patches stay in
   `GamePatchCatalog` until phase 3 moves them into the `nancy-drew`
   module, so there is one list of them. ajv's script is embedded as a
   Swift string rather than a package resource, whose accessor is
   main-actor-only under the packages' settings. Bundles live in
   `Bundles/`, the builder's package is `Packages/WrappBuilder/`.
2. **Module protocol, behind the current code.** First take
   SecondChanceKit apart into the packages [The builder, kept
   apart](#the-builder-kept-apart) lists, leaving only Second Chance's own
   (its AppKit windows among them) in it. Then create the builder's
   package, with the build facets in it rather than the app; define the
   three facets; move Wine, ScummVM and Steam behind them; replace the engine branch
   sites D1 placed with calls through them. Settle the `engine` telemetry
   tag and event payload first (D1). Behaviour unchanged.
3. **Module data and releases, and the `nancy-drew` module.** Give each
   native module its data folder, a release number and the versions it
   provides, and move into it what is data today (winetricks verbs,
   `ddraw.ini`, routine errors); `sc module check` compares a release with
   the one before. Move the Nancy Drew-wide knowledge (AutoIt dialog
   script, patch wizards and manifest, INI rewrite, clean-exit log, splash
   needles, quit scenario) into the data-only `nancy-drew` module, the
   patches as data today's patch code reads (they become functions over `fetch` mounts and `ADD`
   in phase 5, when there is something to run them), with the shipped
   download cache replacing `setup-game-patches.sh`'s staging.
4. **Wrappfile parser and validator**, in the builder package, and
   `sc bundle check` over it. Write every
   game's Wrappfile to match what its builder does today; a test compares
   the steps each produces with what the builders log.
5. **The Wrappfile builder**, uncached and in the builder package, with
   asking the person, progress and reporting behind its protocols: one
   strategy runs the edition's
   target; the per-source builders shrink into source modules and their
   default stages; installs go where `--into` says, linked if the person chose otherwise; the
   Steam launch mode becomes a choice, and the variant one with its
   worked-out default; the wrapp records its lock. The new bundle ids come
   in here, and with them the move of user files to the new layout, links
   left behind, tested through `SECOND_CHANCE_APP_SUPPORT_DIR` — including
   a wrapp from today's release meeting a Second Chance that has every
   phase, since people will jump straight from one to the other. Prefixes
   lose Z:. `installer` replaces the installer code. Same events.
6. **The layer cache**, starting with the `USE wine` layer that replaces
   the prefix cache, then every layer, keyed on module and core build code
   by target; `--explain-cache`, `--target`. First tests: A8 (two builds,
   one layer) and session boundaries under load (A2).
   **Done 2026-11-03 in part**: the store and keys, the prefix layer, and
   one install layer per disc or Her Windows build (everything the plan's
   stages do, as one layer, until the Wrappfile interpreter can split it);
   a miss is explained in the log on every build rather than behind
   `--explain-cache`; A8 is a unit test. Left for later: Steam and Her Mac
   layers, `--target` and `--layer-every-step` (need the interpreter),
   pruning from wrapps, sizes that count only what a delete frees, and A2.
   Under test only the prefix is cached (`SECOND_CHANCE_LAYER_CACHE`), so
   integration runs still install for real.
7. **Updating wrapps**: picking an existing wrapp to update, through the
   disc source for now ("a disc, or the game's app you already have";
   phase 12's rebranding makes it a disc / file / existing app source of
   its own); the manifest's `updates`, the chain worked out from the old
   wrapp's lock (made up for a wrapp from before bundles), `previous` and the update conditions, the
   Wine and Steam modules' default updates, and telling the owners of
   wrapps built with a fixed bug what updating needs.
   **Done 2026-11-03 in part**: the manifest's and modules' `updates`,
   `UpdatePlanner` (the chain from the old lock or one made up, `previous`,
   `when-changed` for a module's default), the wine module's `wine-prefix`
   and the steam module's `steam` (a fresh build), and `UpdateWrappBuilder`
   reached by choosing a game's app as disc 1: the old prefix carried into
   this template with the person's files left out, Wine moved within a major
   version, updates' stages run (patches, .ini settings). Left: telling
   owners of wrapps with a fixed bug (phase 12, as it is seen), routing a
   Steam wrapp's fresh build to Steam, update stages that install, and
   `sc bundle check`'s checks on updates.
8. **Detection from bundles**, today's matcher as the default, with
   near-miss reports; the unrecognised-program question keeps today's three
   choices, as changing it is visible (phase 12). First test: every bundle's matchers over
   `GameDetectorTests`' cases and every installer, comparing slugs with
   `GameDetector`'s (F1).
9. **Tests from bundles**: needles of three kinds found by tag, scenarios
   as handlers, and parameters; handler patches and fragments when a game
   first needs them. First test: H3.
   **Done 2026-11-03**: needles of three kinds (a YAML beside each image, or
   a folder's `defaults.yaml`), the bundle's `tests/needles` over the
   module's by id, the nancy-drew module's `quit-from-menu` scenario as
   handlers, parameters from the bundle's `tests`, read by WrappBuilder's
   `Testing/` and run by WrappPuppeteer; H3 passed. Left for when a game
   needs them: handler patches, fragments, edition-level needles, needles
   from failures, `--no-cache`.
10. **The download source, hidden** (decided 2026-11-02): with the first
    free editions — zips and bare exes first, disc images once downloads
    resume (K3). It is a fourth source on the welcome screen that only
    appears after a double-click on the Second Chance icon at the top left
    of the main window, and lists every program whose bundle has an
    edition it can download. Nobody who doesn't know to look sees it.
    **Done 2026-11-03**, with SkiFree (`freeware/skifree`) as the first
    edition, a bare exe: `Downloader` (hash decides, cached, polite,
    resumes), `DownloadWrappBuilder`, the plain-words notice per licence
    and `Licence.txt` in the wrapp, `sc wrapp build --from download`, and
    `sc test integration --source download`. Zips are unpacked but none is
    shipped yet; installers, rar and disc images wait for editions.
11. **Programs beyond Nancy Drew, hidden** — a few other games, one on a
    third engine if there is a good candidate — to prove the design
    generic. They build through the disc source, pointed at their discs or
    folders as any disc is (detection finds them like any bundle), or
    through the hidden download source; nothing on screen mentions them
    yet, as updating an existing wrapp through the disc source doesn't
    either (phase 7).
    **Done 2026-11-03 in part**: SkiFree (Wine) and Lure of the
    Temptress (ScummVM, a zip), both download editions, each with a
    `starts-and-quits` test; programs carry their own bundle id and app
    name through the catalogue. Left: a third engine (DOSBox, for the DOS
    candidates), which is packaging work of its own.
12. **User-facing, last**: wording that isn't Nancy Drew's (the inventory
    lists every string), the welcome screen's options per source — "Disc
    or a file you downloaded", "Steam", "Free from the internet", and the
    game's app you already have, each now shown — lists for chosen
    sources, the unrecognised-program question asking which program it is
    in place of "install anyway", importing bundles and modules (with
    Settings' control to open their folders), renaming `nancy-drew-installer`, per-program icons,
    and dropping `.local/AGENTS.md`'s note against mentioning disc images,
    which only fits a project about Nancy Drew alone.

Phases 1–3 move data and code without changing what runs; 4–7 change how
builds run; 8–9 change detection and tests; 10–11 add what's generic
behind the scenes; 12 changes what people see.

### Her's downloads, for phase 1

`GameInfo` doesn't record which games Her Interactive sells as downloads,
so J1's generated bundles claimed both formats for every game. From each
game's page in Her's store (herinteractive.com/shop-games, read
2026-11-02):

- **A Windows download**: every game from Stay Tuned for Danger (2) to Sea
  of Darkness (32), and Secrets Can Kill Remastered. The original Secrets
  Can Kill's page offers one but lists it as sold out, pointing to
  Remastered. It still gets a Her-download edition, as editions are what
  Her ever sold, not what it sells now: someone who bought it then can
  build it today, and must still be able to (decided 2026-11-02, after the
  review). (Ransom of the Seven
  Ships has no price on the store's list, but its page sells the download
  and a disc.)
- **A Mac download as well**: Secrets Can Kill Remastered, and every game
  from Trail of the Twister (22) to Sea of Darkness (32), and none before.
  Every one carries the same compatibility warning: Intel Macs only, macOS
  10.13 High Sierra or earlier, "Will NOT run on Mojave … or higher". All
  alike, from a 2010 game to a 2015 one, they look like one family of
  builds, the 32-bit Cider kind Twister's is, which Second Chance can take
  apart. Only Twister's has been looked inside, so the rest stay marked
  unverified — accepted as today, not refused — until a sample of each has
  been
  ([docs/her-download.md](../her-download.md) refuses one that
  isn't Cider).

## Fixes to today's code, independent of the phases

Found while validating; each can be done whenever, and none waits on
bundles:

- **ScummVM wrapps keep a whole Wine prefix** they never use, and their
  discs are made Wine CD drives just before Wine is removed.
- The four ScummVM disc answer files are copied in and never read.
- The INI rewrite looks one folder above a ScummVM game's data.
- The clean-exit log check (`HerEngineLog`) applies to every Wine game,
  not only Nancy Drew's (C1).
- The A: placeholder's folder is a random temporary path, so two builds
  that should be the same differ (B4).
- **Z: is the whole Mac** in every prefix, so a Wine program can reach any
  of the person's files ([Trust](#trust)). Removing it needs every path
  Second Chance hands Wine to be inside the prefix first (AutoIt's was
  not), then an integration run of every game, as winetricks verbs,
  installers and Steam may rely on it.
- Disc 2 is never checked to be disc 2.
- "Nancy Drew" is hard-coded in Steam's direct-launch path and the A:
  placeholder's name.

Not fixable: only Scarlet Hand's Windows download has an answer file,
because answer files can only be recorded from copies we own. Other
downloads install with their wizard, so a headless build of one fails, and
that stays so until someone with a copy records one.

Done 2026-11-02, on a branch waiting for the release after this one:
`winemenubuilder` off; the game's program asked about when several are
likely (main had meanwhile made the pick deterministic, the largest that
isn't an uninstaller; the two are combined); why disc copies stay,
commented; AutoIt given the installer's C: path rather than a Mac one, and
no longer the game's title. Main had already stopped writing the unread
`game-engine` file.

## Still to validate

Left after the first pass, each with what it needs:

| Item | What's open | What it needs |
| --- | --- | --- |
| J3 | Which Wine games play with their disc copies removed | First pass 2026-11-02 (disc copy deleted, drive left as an empty CD drive, launched to the main menu only): Haunted Carousel, Deception Island, Shadow Ranch, Old Clock and Danger by Design **fail at launch**, showing at once a small "Nancy Drew" dialog (very likely an insert-disc message; not yet confirmed against a with-disc run in the same session); White Wolf, Crystal Skull, Sea of Darkness and Secrets Can Kill Remastered reach the menu, which is **not verified**. Still needed: the with-disc control for the failures, then each remaining game with its disc copy removed, a new game started and played to the first scene the player controls, on the test Mac. Until a game is verified that way it keeps its disc copy, so editions need discs that are kept for play (`wine.KEEP-DISCS`) |
| H3 | Sharing tests between a game's disc and Steam editions | Both editions of three games built and played through WrappPuppeteer on the test Mac; or phase 9's first test; not run on 2026-11-02 (the run lost its shell) |
| A2 under load | What a Wine session boundary costs with every core busy, for each installer family | A3's prototype run again under load on the test Mac; or phase 6 |
| A8 | Two builds needing one layer build it once | The layer cache: phase 6's first test |
| B2 | Whether Steam's build id can be read before an app is downloaded | A signed-in Steam in a wrapp, asked for one app's info |
| A10, rest | Moving a prefix across a major Wine version (10 to 11) | A wrapper template that starts Wine 11: packaging work first |
| A11, rest | Where Inno Setup and MSI installs record their folder (InstallShield, Steam and Her downloads seen) | A Wine wrapp built from each, its registry read |
| L5, rest | Whether the older games (Blackmoor Manor, Shadow Ranch, …) write to the registry while played; Twister and White Wolf don't | Each played past its first scene on the test Mac, then its registry read |
| Permissions | Whether a rebuilt wrapp is asked again for what it was granted | A Steam wrapp rebuilt on the test Mac, then launched |
| Her's Mac downloads | Whether all eleven after Trail of the Twister, and Remastered's, are Cider builds, as their shared store warning suggests | A download of each, opened |
| YAML 1.2 | That Yams with a YAML 1.2 core-schema resolver reads every bundle as the editor does | J1's pitfall cases through both |
| Core code hashes | That keying layers on the core's build code per target works as decided | B4's prototype, extended to the core's targets |
| Layer store sizes and pruning | Whether 30 days and the size limit suit | Layer sizes measured over a full integration run |

## Where the knowledge is today

From an inventory of the code (2026-11-02):

- **No production code branches on a game's slug.** Per-game knowledge is
  in five places: the `GameInfoProvider` table; `GameDetector`'s
  `getGameSlugFromFingerprint`, a 33-branch chain of title substrings whose
  order matters; files named by slug (17 `.iss` answer files plus one for
  the Her download, `game-patches.json`'s 23 patches over 16 games, 18
  per-game splash PNGs); Her-wide heuristics applied to every game
  (`configureGameINI`, `HerEngineLog`); and one title check in WrappPuppeteer
  (`appName.contains("Scarlet Hand")`).
- **Engine branching: about 45 sites**, 11 of them `switch gameEngine`.
- **Dead or unused:** `failedInstallInfo` (never read), `installInstructions`
  (never set), `ScummVMService` (never called).
- **No per-game icons yet**, and no ScummVM game ids: ScummVM runs with
  `--auto-detect`.
- **Patches are downloaded when Second Chance is built** and staged in its
  bundle (`setup-game-patches.sh`). They become `ADD --checksum=sha256:… <url>` in the
  `nancy-drew` module, and the staging becomes the shipped download cache
  `ADD` looks in first, so builds still work offline (B3; [The download
  source](#the-download-source)).
- Strings people see that name Nancy Drew or Her Interactive: about 15,
  listed in the inventory, for phase 12.

## Syntax by example

Every piece of syntax this draft names, in one place: a manifest, a
Wrappfile, a module, a function, a needle and a scenario. Where the draft
names an idea without saying how it is written, the form here is a
proposal, marked _(proposed)_; everything else is as described above.

### A manifest

```yaml
# yaml-language-server: $schema=../../manifest.schema.json
format: 1                                    # a newer format than this app reads is refused
id: "nancy-drew/blue-moon"                   # namespace/name
version: 4                                   # the bundle's own version, which updates bring wrapps to
title: "Last Train to Blue Moon Canyon"
series: "Nancy Drew"
display-name: "{series}: {title}"            # only to change the default "{series} - {title}"
former-bundle-ids: ["au.gare.callum.SecondChance.nancy-drew.blue-moon"]
setup: "prefix-setup"                        # the Wrappfile function default stages run first

runtime:                                     # every edition and variant, unless one overrides it
  aspect: "4:3"
  save-warning: true                         # a core setting; the Wine module's default _(proposed name)_
  environment: { WINEDEBUG: "-all" }         # _(proposed name)_
  wine:                                      # the Wine module's options, checked by its schema
    exit-code-meaningless: true
    clean-exit-log: { file: "Documents/*/Debug.LOG", marker: "ExitInstance(), good exit" }
    mac-folders:                             # opting in to a Mac folder, never by default _(proposed)_
      - { folder: "~/Documents", drive: "M:", when: "launch" }
  when:                                      # decided at launch, by the Mac the game runs on _(proposed)_
    - mac: { arch: "x86_64" }                # Mac conditions as IF has them: arch, macos
      wine: { mode-scaling: false }

volumes:                                     # by name; what belongs to each volume
  wine-documents:
    in-use-when: ["*/*.Hi*Save", "*/*.SAV", "*/HICONTINUE.*"]   # any-file (default) | never | patterns
    display-name: "saved games"
  settings:
    in-use-when: never                       # only the program's settings
  scummvm-saves:                             # the scummvm module's; only what differs is written
    display-name: "saved cases"
    convert-from:                            # bring another volume's files across _(proposed)_
      volume: "wine-documents"
      with: "scummvm.IMPORT-SAVES"           # a module instruction or function

variants:
  - id: "scummvm"
    editions: ["cd", "steam"]                # leave out: every edition
    build: { target: "scummvm" }
    available: "yes"                         # "yes" | "existing-files-only" | "no"
    preference: 1                            # the lowest is preferred for a first build
    volumes:
      - source: "scummvm-saves"              # the module's volume, at the module's target
    launch: { scummvm: { path: "/game" } }   # where its stage copies the game

  - id: "wine"
    available: "existing-files-only"         # retired: only for someone with files in its volumes
    preference: 2
    volumes:                                 # mounts: Compose's long form
      - source: "wine-documents"
        target: "C:/users/crossover/Documents"
        wine: { drive: "A:" }                # how this engine mounts it
      - source: "settings"                   # a file volume
        target: "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.ini"
    launch:
      wine: { exe: "${install-dir}/Game.exe", args: ["-nointro"] }
      when:                                  # a choice replacing the launch
        - choice: { launch-mode: "steam" }
          steam: { app-id: "${inputs.game.app-id}" }

  - id: "dosbox"
    available: "no"
    reason: "This version of the game can't be run yet."   # shown to people

editions:
  - id: "cd"
    source: "disc"                           # brought: detection finds it
    inputs:
      - { id: "disc-1", requires: "Setup.exe", prompt: "Insert the game's first disc" }
      - { id: "disc-2", requires: "Disk2.id", prompt: "Insert the game's second disc" }
    build: { target: "disc", base: "disc-install" }
    patches: ["blue-moon-taffy-sort"]        # the nancy-drew module applies them
    detect:
      aliases: ["Blue Moon Canyon"]          # for today's title matcher
      codes: ["TRN"]                         # a word, case-sensitive
      matchers:
        - { matcher: "exe-version", file: "setup.exe", product-name: { contains: "Blue Moon Canyon" } }
        - { matcher: "file-hash", file: "Data/game.dat", bytes: 5000, md5: "…", size: 123456, language: "en" }
        - { matcher: "msi-summary", file: "*.msi", subject: { contains: "Blue Moon" } }
        - { matcher: "volume-name", is: "BLUEMOON" }
        - { matcher: "file-exists", glob: "Data/*.cif" }
        - { matcher: "string-in-file", file: "autorun.inf", contains: "Blue Moon" }
    tests:                                   # the edition's own, over the bundle's
      parameters: { splash-wait: 10 }

  - id: "her-windows"
    source: "her-download"
    inputs: [ { id: "installer", format: "windows" } ]
    patches: ["blue-moon-taffy-sort"]

  - id: "steam"
    source: "steam"                          # chosen: listed if the account owns it
    inputs:
      - { id: "game", app-id: 31810 }
    build: { target: "steam-install" }
    drm: "launch-when-steam-running"         # left out: not known
    choices:
      launch-mode:
        options: ["direct", "steam"]
        default: "direct"                    # pre-selected; what a headless build takes
        prompt: "How should the game start?"
    runtime: { save-warning: false }         # an edition overriding the shared runtime

  - id: "freeware"                           # a download edition, from another bundle
    source: "download"
    licence: "free-release"                  # freeware-licensed | free-release | shareware | abandonware
    licence-from: "the author's website"
    inputs:
      - id: "game"
        urls: ["https://example.org/game.zip", "https://web.archive.org/web/2007…id_/https://example.org/game.zip"]
        sha256: "…"
        size: 5242880
        unpack: "zip"                        # none | zip | rar | "zip:<member>"
        install: "setup.exe /s"              # or "none"
        disc-image: "game.iso"               # an archive holding a disc image

updates:
  - id: "taffy-patch"
    from: { bundle: "<4" }
    to: { bundle: 4 }
    build: { target: "add-taffy-patch" }
  - id: "from-wine-9"
    from: { wine: "9" }
    to: { wine: "10.0_8" }                   # stop short of this build's, for a later update
    build: { target: "wine-9-to-10" }
  - id: "new-installer"
    from: { bundle: "<3" }
    fresh-build: true                        # no way forward from these: build from the source
  - id: "refresh"                            # no from: any old wrapp; no build: the edition's target

tests:
  scenario: "nancy-drew/quit-from-menu"
  parameters: { splash-retry: 2 }

notes:                                       # for people only; nothing reads these
  installer: "installshield"
  graphics: "ddraw"
  quirks: ["Disc 2 holds the second half's videos."]
```

### A Wrappfile

```dockerfile
# A global build argument: the install folder, written once
ARG install-dir="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"

# Set-up every edition shares: steps, run wherever DO names them
FUNCTION prefix-setup
  wine.WINETRICKS cnc_ddraw
  wine.REGISTRY --set "HKCU/Software/Wine/Direct3D:renderer" "gl"
  IF arch=arm64
    wine.REGISTRY --set "HKCU/Software/Wine/Mac Driver:RetinaMode" "n"
  ELSE IF macos>=26
    wine.REGISTRY --remove "HKCU/Software/Wine/Mac Driver:RetinaMode"
  ELSE
    # nothing on an Intel Mac before macOS 26
  END
END

FROM scratch AS prefix                       # the bare wrapp template
USE wine@10                                  # a module, with a version constraint
DO prefix-setup

# The disc edition's install (its manifest says build.base: "disc-install")
FROM prefix AS disc-install
ARG install-dir                              # the global one, brought into this stage
USE installer
USE nancy-drew AS nd                         # its functions are then DO nd.<name>
wine.KEEP-DISCS --combined=C:/discs/combined/   # every disc copied in and given a drive
LAYER                                        # these steps as one layer, one Wine session
  installer.RUN D:/setup.exe --answer-file=assets/disc.iss \
      --mount=type=bind,from=nd,source=assets/installshield-custom-dialog.au3,target=C:/driver.au3 \
      --driver=C:/driver.au3 --into=${install-dir} --dir-contains=Game.exe \
      --no-wizard-fallback --needs-space=1.4GB \
      --describe="the game"
  DO nd.patch --id=blue-moon-taffy-sort --into=${install-dir}
END
COPY assets/game.ini "${install-dir}/"
EDIT "${install-dir}/Game.ini" --ini=Display.WindowMode=2
MOVE "${install-dir}/Readme.txt" "${install-dir}/Docs/Readme.txt"
REMOVE "C:/discs/combined/autorun.inf"

# A disc needed only to install: mounted for one step, never copied
FROM prefix AS other-install
RUN --mount=type=source,id=disc-1,wine.drive=D: \
    --creates="C:/Program Files (x86)/Example/Game.exe" \
    D:/setup.exe /s /f1${assets/disc.iss}    # ${assets/…}: a bind mount at a path the executor picks

# A disc kept for play by hand, as wine.KEEP-DISCS does for each
FROM prefix AS by-hand
USE installer
COPY --from=disc-1 . C:/discs/disc-1/        # an input, as Docker copies a named build context
wine.MOUNT C:/discs/disc-1/ D: --cdrom
# One option each: --into=${install-dir}, which a real install gives, is left out for brevity
installer.RUN D:                             # the installer and its family worked out
installer.RUN D:/game.msi --msi-properties="SOMEPROP=1"   # --into sets an MSI's folder
installer.RUN D:/expansion.exe --into="C:/Games/Example/Expansion"
installer.RUN D:/Setup.exe --family=installshield --args="/s /sms"
installer.RUN D:/setup.exe --interactive     # the wizard, with the person

# More mount types (source above, volume below; steam.INSTALL mounts a
# secret itself), and a step allowed to fail
FROM prefix AS mounts
USE nancy-drew
RUN --mount=type=cache,target=C:/users/crossover/AppData/Local/cache,rw \
    --mount=type=bind,source=assets/setup.inf,target=C:/setup.inf \
    --mount=type=bind,from=nancy-drew,source=assets/patch-wizard.au3,target=C:/wizard.au3 \
    --mount=type=fetch,url=https://example.org/fix.exe,sha256=…,target=C:/fix.exe \
    --on-failure=ask --describe="the fix for the taffy-sorting puzzle" \
    --if-skipped="The game will still work without it." \
    C:/fix.exe /quiet
RUN --with=wine --on-failure=continue C:/tools/optional.exe
RUN --on-failure=ask --ask="Second Chance couldn't add the extra music. Carry on without it?" C:/music.exe
ADD --checksum=sha256:… https://example.org/runtime.exe C:/runtimes/   # a supporting file, never the program

# Steam: a module's stage, with a constraint, and a choice
FROM steam@2/client AS steam-install         # Steam installed and signed in, before the game was chosen
ARG install-dir
ARG launch-mode                              # a choice
DO prefix-setup                              # the same set-up, on Steam's prefix
steam.INSTALL game --into=${install-dir}     # the input; the sign-in is mounted as a secret
IF launch-mode=direct
  steam.REMOVE                               # the game moved to --into first, then Steam taken away
END
EXPORT ${install-dir}                        # where this stage left the game

# Her's download: a module's default stage, and its own instruction
FROM her-download/windows AS her-install
ARG install-dir
her-download.INSTALL installer --into=${install-dir}

# A ScummVM variant: a fresh start, taking the game from an edition's export
FROM scratch AS scummvm
ARG install-dir
USE scummvm
COPY --from=steam-install ${install-dir} /game

# The edition's target: on a fresh build `base` is disc-install; on an update,
# the update chain's result
FROM base AS disc
USE nancy-drew AS nd                         # again: on an update, base is the chain's result
ARG install-dir
DO nd.install --installer=D:/setup.exe --stubborn --into=${install-dir}   # a function, here only as an example
IF updates has from-wine-9
  wine.REGISTRY --remove "HKCU/Software/Wine/DllOverrides:ddraw"
ELSE IF previous.skipped has blue-moon-taffy-sort   # the patch function names its step --name=${id}
  DO nd.patch --id=blue-moon-taffy-sort --into=${install-dir}
END

# Updates' own stages
FROM previous AS add-taffy-patch
ARG install-dir
USE nancy-drew
IF previous.bundle<4
  DO nancy-drew.patch --id=blue-moon-taffy-sort --into=${install-dir}
END

FROM previous AS repair-saves
USE wine
RUN --mount=type=volume,source=wine-documents \
    --describe="the repair to your saved games" C:/tools/fixsaves.exe

FROM scratch AS download                     # another bundle's (SkiFree's): its edition's input is game
ARG install-dir
USE wine
IF updates
  COPY --from=previous ${install-dir}/ ${install-dir}/
ELSE
  COPY --from=game . ${install-dir}/         # a download input, never ADD
END
```

Substitutions: `${name}`, `${name:-default}`, `${path:dir}` and
`${path:file}`, a global or a choice's `ARG` (`${install-dir}`, `${launch-mode}`), `${inputs.<id>.<field>}` _(proposed form)_,
`${assets/<file>}`, and in a function its parameters (`${id}`) and its
module's data (`${data.<table>.<key>.<field>}`).

### A module

```yaml
# modules/nancy-drew/module.yaml
id: "nancy-drew"                             # a shipped module; an added one is namespaced
release: 3                                   # counts up; never written in a Wrappfile
versions:                                    # what this release provides
  - { version: "1" }
  - { version: "2", preview: true }          # used only where a constraint names it
depends-on: ["wine@10", "installer"]         # installed automatically; typed access to them
installs-after: ["steam"]                    # ordering only
options-schema: "options.schema.json"        # what `runtime.nancy-drew:` and USE options may say
functions: ["functions/patch", "functions/configure-ini", "functions/install"]   # DO nancy-drew.<name>
data: ["patches.yaml"]                       # tables its functions read as ${data.patches.<id>.<field>}
assemble: ["DO nancy-drew.configure-ini --into=${install-dir}"]   # after every final stage that USEs it; install-dir is the bundle's global ARG
runtime: { aspect: "4:3" }                   # defaults for the stages that use it
volumes:                                     # bundles mount these by name; names are permanent
  wine-documents:
    target: "C:/users/crossover/Documents"   # the default where a mount gives none
    in-use-when: ["*/*.Hi*Save", "*/*.SAV", "*/HICONTINUE.*"]
    display-name: "saved games"
updates:                                     # a module's own, after the bundle's
  - id: "nancy-drew-ini-fix"
    from: { nancy-drew: { release: "<3" } }   # a release; a version is the plain value
    build: { target: "nancy-drew/reapply-ini" }
invalidates: { versions: ["1"], from: "install" }   # rare: force a miss the hashes can't see
```

```yaml
# modules/wine/module.yaml — a module with Swift
id: "wine"
release: 14
native: "wine"                               # Swift compiled into Second Chance
versions:
  - { version: "10.0_8" }
  - { version: "10.0_6" }
  - { version: "10.0_2", withdrawn: true, replaced-by: "10.0_3" }
stages: ["stages/prefix.Wrappfile"]           # default stages: FROM wine/prefix
runtime: { save-warning: true }              # defaults for the stages that use it
old-places:                                  # shipped modules only: moved in with former ids _(proposed)_
  - "~/Library/Preferences/${former-bundle-id}.ini"
```

A namespaced module someone writes is `someone/directx9`. It can have no
Swift, so no instructions of its own; its functions run as `DO
directx9.install`, or under whatever name the stage's `USE … AS` gives it.

### A function

```dockerfile
# modules/nancy-drew/functions/patch — a module's function, run as DO nancy-drew.patch
FUNCTION patch
  ARG id                                     # parameters are ARGs, passed as --id=…
  ARG into                                   # no default: every call says where the program is
  IF ${data.patches.${id}.action}=installer  # a module's data table, looked up by a parameter _(proposed)_
    RUN --mount=type=fetch,url=${data.patches.${id}.url},sha256=${data.patches.${id}.sha256},target=C:/patch.exe \
        --name=${id} --on-failure=ask --describe="${data.patches.${id}.title}" C:/patch.exe /s
  ELSE IF ${data.patches.${id}.action}=wizard
    RUN --mount=type=fetch,url=${data.patches.${id}.url},sha256=${data.patches.${id}.sha256},target=C:/patch.exe \
        --mount=type=bind,source=assets/her-update-wizard.au3,target=C:/wizard.au3 \
        --mount=type=bind,from=wine,source=autoit/AutoIt3.exe,target=C:/autoit/AutoIt3.exe \
        --name=${id} --on-failure=ask --describe="${data.patches.${id}.title}" C:/autoit/AutoIt3.exe C:/wizard.au3 C:/patch.exe
  ELSE
    ADD --name=${id} --checksum=sha256:${data.patches.${id}.sha256} ${data.patches.${id}.url} ${into}/
  END
END
```

```dockerfile
# In a bundle's Wrappfile: its own function, and a module's
FUNCTION prefix-setup
  wine.WINETRICKS cnc_ddraw
END

FROM scratch AS prefix
USE wine@10
USE nancy-drew@1 AS nd                       # the version, once
DO prefix-setup                              # the bundle's own: a bare name
DO nd.patch --id=blue-moon-taffy-sort --into=C:/Game   # a module's, through the stage's name for it
```

### A needle and a scenario

```yaml
# tests/needles/title-screen.yaml (beside title-screen.png)
kind: "screen"                               # screen | region | text
tags: ["title", "main-menu"]
click: { x: 0.08, y: 0.08 }                  # a fraction of the match
# region: { search: { x: 0.6, y: 0.8, width: 0.4, height: 0.2 }, threshold: 0.85, scales: [0.5, 2] }
# text: { strings: ["Exit Game", "Quit"], case-sensitive: false, match: "whole-word" }
```

```yaml
# modules/nancy-drew/scenarios/quit-from-menu.yaml
goal: "program-ends"
timeout: 300
parameters: { splash-retry: 2 }
include: ["nancy-drew/skip-splashes"]        # a fragment: a set of handlers
handlers:
  - id: "splash"
    when: "splash"                           # a needle tag
    do: ["click", { retry-after: "${splash-retry}s" }]
  - id: "main-menu"
    when: "main-menu"
    do: [{ check: "menu" }, { click: "quit" }, "expect-end"]
  - id: "her-logo"
    when: "her-logo"
    do: ["click"]
---
# an edition's changes to the handlers, by id (in its bundle's tests)
handlers:
  add:     [{ id: "steam-overlay", when: "steam-overlay", do: [{ key: "shift-tab" }] }]
  replace: [{ id: "her-logo", when: "her-logo", do: [] }]
  remove:  ["splash"]
```

Handler patches and fragments are for when a game first needs them
(phase 9).

## Reference: what other projects do

Everything this design learned from other projects, in one place. Each
entry says what the project is, what we took (and where it landed in this
draft), and what we deliberately didn't. **How well it's known** is marked:
_read_ means its code or files were examined; _docs_ means its
documentation; _memory_ means from general knowledge, not looked up for
this draft, so check before relying on a detail.

### At a glance

| Idea in this design | Taken from |
| --- | --- |
| A Dockerfile-like recipe in stages, building cached layers | Docker |
| Inputs declared up front by id; a file that proves which disc is in | Lutris (`files:`, `insert-disc`), CrossTie CD profiles |
| Editions: one program, several ways of getting it | Lutris (several installers per game page), CrossTie (several application profiles over one install profile) |
| Data-only modules for shared components (`USE directx`) | Bottles dependencies, CrossTie "component" ties, Porting Kit `installDependency` |
| Module options schema, `depends-on` vs `installs-after`, loose versions | Dev Container Features |
| Keys chained from the parent's; the key's inputs stored beside each layer; explaining a miss | flatpak-builder (and its unexplained misses) |
| Downloads keyed by their expected hash, never by URL | Nix fixed-output derivations |
| `source`, `cache` and `secret` mounts | Docker BuildKit `RUN --mount` |
| `--target` to build one stage | Earthly, Docker multi-stage |
| Per-step conditions on the Mac (chip, macOS) | Porting Kit step `conditions`, Bottles `for: win64` |
| `RUN --creates=` as a post-condition | Porting Kit `neededFileOnClose` |
| The recipe kept inside each wrapp | Porting Kit `pk_backup.wsi3` |
| A table of withdrawn engine versions | Porting Kit `engineReplacements` |
| A format version that refuses newer recipes | Porting Kit `wsiVersion` |
| Looking on mounted volumes before a file picker | Porting Kit |
| Asking which program is the game when several remain | Porting Kit's main-exe heuristic |
| Different settings while installing and while running | CrossTie (separate Windows versions) |
| Volumes: a folder in the app really kept outside it | Flatpak `--persist`, Docker volumes |
| Detection tables of prefix hashes; engines detecting their own games; near-miss reports | ScummVM AdvancedDetector and `--detect` |
| Tests as needles with tags and explicit click points | openQA; Haystack for making them |
| A manifest with a JSON Schema the editor knows | yaml-language-server, JSON Schema |

### Programs that do what Second Chance does

**Porting Kit** (_read_: v7.0.2's app bundle taken apart, without running
it). The nearest relative: a Mac app that builds a standalone Wineskin
wrapper per game from a recipe in its catalogue.

- **How it works.** Recipes ("WSI3") are JSON: identity, `source`
  (`CD`, `GOG`, `Steam`, `Other`), `type` (`wine`, `dosbox`), bits, and an
  ordered list of typed steps — `setEngine`, `download`, `run` (with
  silent-install `flags`), `setRegistryEntry` (DLL overrides are just
  registry steps), `installWinetrick`, `installDependency` (named bundles
  of steps kept on its server), `setMainApplication`, `setProperties`
  (esync, msync, CPU modes), file operations, `addDrive`. Each step can have
  `conditions` (GPU, CPU, macOS range). It imports Lutris installers.
  Recipes, engine lists, compatibility rules and an `engineReplacements`
  table (`from → to`) come from its server. A user's installer is found by
  filename, first on mounted volumes, else by a file picker. Launch settings
  live in the wrapper's `Info.plist`; user folders in the prefix are
  symlinked to the real `~/Documents`, Desktop and so on. Each port keeps the
  recipe that built it. Updating reruns the whole server recipe over the
  existing app. No automated tests: compatibility is free text, plus
  analytics events for failures.
- **Taken:** per-step conditions; `--creates` from `neededFileOnClose`
  (check a file exists after an installer, retry once, then fail); the
  recipe kept in the wrapp; the withdrawn-version table; a format version
  that refuses newer recipes; looking on mounted volumes first; asking which
  program is the game when its heuristic leaves several (it drops names
  containing `unins`, `setup`, `config`, then asks); downloading engine
  versions other than the shipped one on demand, checked against a hash.
- **Not taken:** identifying the person's files by filename alone (the
  wrong disc or edition isn't caught); running installers through a
  temporary `.bat` with no progress; updating by rerunning the recipe over
  the live app; engine choice by server-side rules, so a build can change
  without anything local changing; a cache shared with another tool
  (`~/Library/Application Support/Wineskin`); `Info.plist` as mutable
  settings; a full template copy and a fresh prefix for every port; no
  tests. Linking the prefix's `Documents` to the real `~/Documents` is
  simple but mixes every game's files into the person's own folder, where
  volumes keep each wrapp's apart.

**Wineskin, Kegworks, Sikarugir** (_read_: their wrapper layout, as cached
by Porting Kit and as Second Chance bundles today). The wrapper template
and engine builds Porting Kit and Second Chance both use: an app bundle
with `Contents/SharedSupport/wine` (the engine) beside
`Contents/SharedSupport/prefix`. **Taken:** that the engine and the prefix
are separate folders, which is what lets a new Wine be put into an existing
install (which `USE wine` relies on when it finds a prefix another Wine
made, under "A prefix follows its Wine").
**Lesson from their history:** wrappers that baked in an engine broke when
macOS dropped 32-bit apps and when Apple Silicon arrived; rebuilding with a
newer engine has to be a normal, safe operation, which is why user files
live in volumes.

**Lutris** (_docs_). A Linux game manager with a large catalogue of
community YAML installers. An installer has a `files:` section declaring
every input with an id (`N/A:Select the game's setup file` means "ask the
person"), an ordered `installer:` list of tasks (`insert-disc` with a
`requires:` file, `wineexec`, `winetricks`, `set_regedit`, `dosexec` for
DOSBox), a `game:` section for launching, a section per runner for engine
settings, and `requires`/`extends` for add-ons that build on a base game. A
game page lists several installers (a CD one, a GOG one).

- **Taken:** inputs declared by id, so the app knows every question before
  step one and multi-disc games fall out of the list; a `requires` file per
  disc; editions (several installers for one game); runners as evidence
  that engine modules work at scale; `extends` as the model for expansions,
  when we come to them.
- **Not taken:** no caching and no tests, so many installers quietly rot;
  and its step list grew control flow (`input_menu`, conditions) — a
  programming language made badly out of YAML. Our functions have no loops for
  that reason.

**Bottles** (_docs_). A Linux Wine manager keeping two catalogues of YAML:
dependencies (shared components such as Visual C++ runtimes, each a list of
steps, downloads carrying a checksum) and programs (installers naming the
dependencies they need). Steps can be limited to one architecture
(`for: win64`). **Taken:** shared components as data-only modules, brought
in with `USE` like any other; per-step architecture conditions.

**CrossOver's CrossTies** (_docs_). CodeWeavers' install recipes, in three
parts: an application profile (identity, "is it installed?" checks by
registry and file globs, dependencies on other ties), an install profile
(installer globs, silent options, DLL overrides, the Windows version to
install under, registry entries and files before install, dependencies
before and after), and a CD profile (a file glob on the disc and a string
that must be in that file). Components such as .NET are ties with a
"component" flag. Several application profiles can share one install
profile.

- **Taken:** detection as data (globs and patterns, not code), fast over
  hundreds of bundles; components as the same kind of thing as programs;
  editions (several profiles over one install); install-time settings
  separate from run-time ones (an installer may need another Windows
  version than the program).
- **Missing from it, so ours to add:** launching and testing. Ties stop
  once the program is installed, yet much of what we know about each game
  is about running it — graphics API, cursor lock, Steam launch mode,
  routine errors, splash screens.

### Build systems and caching

**Docker and BuildKit** (_memory_, with Docker's documented behaviour).
The shape of the whole design: a recipe of instructions builds an image in
layers, each cached by what made it; multi-stage builds (`FROM … AS`);
`ARG`; `VOLUME`; `ENTRYPOINT`. BuildKit adds `RUN --mount`: `type=cache`
(a folder kept between builds but never in a layer or its key — winetricks'
and Steam's download caches) and `type=secret` (available to one step,
never written to a layer or a key — the shared Steam sign-in).

- **Taken:** instructions, stages, `ARG` as choices, volumes, the three
  mount types, exec-form `RUN` only.
- **Changed:** a layer per instruction is too dear for us (ending a Wine
  session costs seconds), so layers are grouped, by hand or automatically;
  `\` is special only at the end of a line, since Windows paths are full of
  it (Docker needs `# escape=` for that); no shell form of `RUN`.
- **Its warning:** Docker, like flatpak-builder, is known for cache misses
  nobody can explain.

**flatpak-builder** (_read_: its cache source). Builds an app from a
manifest of modules, each a cached stage whose checksum starts from the
previous one's, so a key covers everything before it; downloaded sources
must carry a sha256; an app declares a runtime with a version branch
(Flatpak's `FROM`). **Taken:** chained keys; hashes required on downloads.
**Its warning, taken to heart:** developers report cache misses they never
managed to explain. So each layer keeps its key's inputs beside it
(`key.json`, per file), and `--explain-cache` says what changed (validation
B5 named a changed winetricks verb, Wine version or source file exactly).

**Nix** (_memory_). Separates fixed-output steps, such as a download,
keyed by the hash of what they produce rather than how they got it, and
records what a build resolved in a lockfile. **Taken:** `ADD --checksum=sha256:… <url>`
keyed by the hash, so a moved URL rebuilds nothing and nothing is fetched to
compute a key (a Steam download is keyed by its build id instead, a disc by
its listing hash); the wrapp's lock of what it resolved.

**Dev Container Features** (_docs_). Reusable pieces added to a dev
container: an id and semver version published under floating tags (`:1`,
`:1.2`), an `options` schema checked before a build, `dependsOn` (installed
automatically) and `installsAfter` (ordering only). **Taken:** loose engine
and module versions; module options checked against the module's schema;
the difference between depending on a module and only coming after it.

**Earthly** (_docs_). Dockerfile crossed with Makefile, able to build any
named target alone. **Taken:** `--target` to stop after one stage and look
inside it.

### Detection

**ScummVM** (_docs_ for its detector; _read_ by running the bundled
2026.3.0). Its AdvancedDetector identifies games from tables: a file name,
the md5 of the first N bytes (often 5000) and a size, each naming the
variant (language, platform, demo). Hashing a prefix keeps it fast over
thousands of games; its known weakness is two versions that share their
first bytes. When files nearly match, ScummVM prints an unknown-variant
report (files, md5s, near ids) and asks for it to be sent in.
`scummvm --detect --path=…` identified Nancy Drew discs and Wine-installed
games in well under a few seconds (validation F2).

- **Taken:** prefix-hash matchers as a core matcher type; an engine module
  detecting its own games (the ScummVM module asks ScummVM, so bundles
  carry no tables for it); near-miss reports, for which ScummVM's own
  report is ready made.
- **Not taken:** a prefix hash for whole disc images, whose first bytes
  are zeros (validation found it useless); a disc's identity is a hash of
  its file listing instead.
- **Also from it:** variants are real — its `nancy` engine runs games we
  build with Wine, and it can't read their original saves (validation L1),
  which is why variants carry their own volumes.

**Redump** (_memory_). Databases of verified disc image hashes, the
reference for identifying a whole disc should we ever need one.

### Testing

**openQA** (_docs_). SUSE's whole-system test tool, driven by needles: a
reference screenshot, match areas, tags and an optional click point. Tests
name tags, never image files; `assert_and_click` waits for a tag and clicks
its needle's point. It learnt the hard way that explicit click points beat
clicking the middle of a match. **Taken:** needles with tags and click
points as a bundle's test data; tests that name tags, so an edition can
override one needle without touching the scenario; WrappPuppeteer's
splash recordings becoming needles.

**Haystack** (_docs_). Makes openQA needles from a failed run's
screenshot. **Taken:** the idea of a command that turns a failed run's
capture into a new needle, so writing tests for a new program is mostly
pointing and clicking.

### Running and keeping files

**Flatpak** (_docs_). `--persist=DIR` maps a folder inside the sandbox
onto storage kept for that app, so an app sees its files where it expects
while they live outside it. **Taken:** volumes, realised per engine (a
symlink in a Wine prefix, ScummVM's save path) and, for files a program
replaces by renaming, reconciled rather than linked (validation G1).

**Wine itself** (_read_: the bundled build). Brings an older prefix up to
date in place when a newer Wine first runs in it (`wineboot -u`), which
`USE wine` relies on when it finds a prefix another Wine made ([A prefix
follows its Wine](#a-prefix-follows-its-wine); validation A10: it works
within a major version). Its `winemenubuilder`
writes Linux menu files outside the prefix, so the Wine module turns it off
(done).

### Where downloads come from

**The Internet Archive and the Wayback Machine** (_read_: queried for 14
games, validation K3). Publishers' links mostly die. Wayback's raw (`id_`)
copies are byte-identical to the originals and its index gives each
capture's SHA-1, so a bundle author can check one without downloading it;
but it is slow (seconds to first byte, about 0.4 MB/s) and its index
refuses heavy use. FTP-era shareware survives only as archive.org uploads,
often repackaged. **Taken:** mirrors in order — the publisher, a Wayback
`id_` copy with its timestamp pinned, an archive.org item — with the sha256 deciding,
and every lookup done when writing a bundle, never in the app. Archive.org
is used as any other source, a download happening only at the person's
request (decided 2026-11-02).

### Formats

**YAML with JSON Schema, via yaml-language-server and Yams** (_read_:
prototyped in J1). A `# yaml-language-server: $schema=…` line gives
editors completion and checking. Decoding with Yams into Swift types
accepted values other YAML tools read differently (`no`, `off`, `10.10`)
and ignored mistyped keys; the schema caught them all. **Taken:** YAML
for comments and easy editing, the schema for checking, validation from the
raw YAML rather than the decoded types. **Watch:** Yams reads YAML 1.1 by
default and the editor 1.2, so Second Chance gives Yams a YAML 1.2 resolver.

### Sources

- Porting Kit: its v7.0.2 app bundle (read locally); <https://www.portingkit.com>
- Wineskin: <https://github.com/vitor251093/wineskin>
- Lutris installers: <https://github.com/lutris/lutris/blob/master/docs/installers.rst>
- Bottles dependencies: <https://github.com/Nocifer/dependencies>;
  architecture filter: <https://github.com/bottlesdevs/Bottles/pull/3101>
- CrossTie editor options: <https://support.codeweavers.com/an-intermediate-guide-on-what-the-crosstie-editor-options-mean>
- flatpak-builder cache: <https://git.stg.centos.org/source-git/flatpak-builder/blob/c487f7f6b15d3fa3d06b4adec9e8df0a214838bd/f/src/builder-cache.c>;
  unexplained misses: <https://blogs.gnome.org/alatiera/?p=94>
- ScummVM Advanced Detector: <https://wiki.scummvm.org/index.php/Advanced_Detector>;
  unknown MD5s: <https://wiki.scummvm.org/index.php/Reporting_unknown_MD5_checksums>
- openQA test API: <https://open.qa/api/testapi/>; click points:
  <https://progress.opensuse.org/issues/31198>
- Haystack: <https://flathub.org/apps/app.drey.Haystack>

## Open questions

- Can bundles be updated separately from Second Chance (a catalogue fetched
  from a server, like Porting Kit's and Lutris's), or only with it?
- An importer for Lutris installers (Porting Kit has one,
  `wsi3FromLutrisJson`) could seed bundles for many games at once. Worth it,
  or would every import need hand-checking anyway?
- Does any program need two engines at run time (a Windows launcher handing
  off to DOSBox)? If so, the "one launcher" rule needs room for it.
