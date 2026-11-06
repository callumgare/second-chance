# Where others have already worked it out

Checked 2026-11-04. `scripts/refs.py` queries the ones marked ✓; the rest
are by hand. Write each one's verdict in the porting log, including
"nothing found".

**`refs.py draft crossover:<id>`, `draft pk:<id>` (or `pk:<file.wsi3>`)**
turns a CrossTie or a Porting Kit recipe into candidate Wrappfile lines:
its Windows version, components and winetricks verbs as `WINE.WINETRICKS`,
registry values and DLL overrides as `WINE.REGISTRY` (less the overrides
its own verbs set), `cnc_ddraw` as `DO wine.cnc-ddraw` with the launch's
cursor lock, the installer as `INSTALLER.RUN`, and the program it starts
as `LAUNCH`. Each line's comment says which recipe step it came from, and
a list at the end says what it couldn't map and why (Flash, DXVK, a
virtual desktop, a DWORD value, the install notes, a Steam or Big Fish
client). It's shaped as a whole Wrappfile, so it passes `wrapp-builder
check` in a scratch bundle, but it's a list of things to try one at a time
(step 6), never a Wrappfile to commit: keep only what the program needs.
It carries over identifiers (a verb, a DLL, a key), never their text. The
mapping is `scripts/draft-map.json`: add to it when a draft lists
something it should know (a CrossOver component's id, a Porting Kit verb
or property), and `refs.py draft --check-map` checks every verb is one
our winetricks has and every component id is CrossOver's.

| Source | Good for | How | Notes |
| --- | --- | --- | --- |
| ✓ **CrossOver CrossTies** | Mac-specific: what CodeWeavers installs for a program (dependencies by name, winetricks-like components), its Windows version (`bottletemplate`: win98, winxp, win7…), registry and DLL-override tweaks, install notes, CD globs, and how well it ran on Mac by CrossOver version (medals: gold … `knownnottowork`) | `refs.py search`, `refs.py show crossover:<id>`, `refs.py draft crossover:<id>` | Read from the CrossOver app or the copy it keeps updated in `~/Library/Application Support/CrossOver/tie/` (~5,300 programs). Proprietary: reference only. A `knownnottowork` from a recent version is worth taking seriously |
| ✓ **Porting Kit** | Mac Wine ports (~1,500): the engine, renderer, winetricks, registry and launch steps that made each work | `refs.py search`, `refs.py show pk:<id>` (description from its public API); recipe from a `.wsi3` on this Mac (`refs.py wsi <file>`, `refs.py draft pk:<id>`) | Recipes aren't served openly. Get one by saving it from Porting Kit, or from `pk_backup.wsi3` inside a port it installed. Don't probe its server for them. `ddr=gdi`, `cnc_ddraw` and `win98`/`winxp` steps are the common fixes |
| ✓ **Lutris** | Install scripts: runner (wine/dosbox/scummvm), files, extraction steps, winetricks, DLL overrides, disc handling | `refs.py lutris <name>` (`lutris.net/api/games?search=`, `/api/installers/<slug>`) | Linux paths, but the steps carry over |
| ✓ **PCGamingWiki** | Fixes, windowed/widescreen hacks, no-CD status, DRM, middleware, where it's sold now, Lutris/MobyGames/AppDB ids; where a game keeps its config and saves (`Game data`) | `refs.py pcgw <name>` (search + page wikitext; anonymous Cargo queries are closed) | Its search misses very short titles ("Iji"): try the page URL by hand. `/api/appid.php?appid=<steam>`, `/api/gog.php?page=<id>` redirect to a page |
| **The program's own files** | Its README, manual and FAQ say what it needs and what goes wrong ("close the Print Spooler", "can't save from inside the zip"), and its licence file says what may be shared | `grep -i` them; a manual may be ISO-8859-1 or UTF-16 (`iconv`) | Free programs often ship their source: read it for save locations and switches |
| **ScummVM** | Whether an engine reimplementation runs it, on any platform's data | `scummvm --detect --path=<dir> [--recursive]` with a scratch `HOME`; `--md5mac` for Mac files; scummvm.org/compatibility for how well | The answer that beats all the others when it's yes |
| **WineHQ AppDB** | Per-version test reports and workarounds | appdb.winehq.org; no API: `objectManager.php?sClass=application&iId=<id>` | Mostly Linux, many old. Behind an anti-bot challenge for browser-like agents |
| **ProtonDB** | Steam games: Proton tier and tweaks | `protondb.com/api/v1/reports/summaries/<steam appid>.json`; dumps at github.com/bdefore/protondb-data (ODbL) | Proton has DXVK; Mac Wine mostly doesn't |
| **Bottles dependencies** | How to install a component (`index.yml` + one YAML per dependency) | github.com/bottlesdevs/dependencies | |
| **winetricks** | What a verb does, exactly | `winetricks list-all`; read `w_metadata` and the verb's function in the script | The bundled winetricks is the one that runs |
| **GOG's releases** | Known-good DOSBox `.conf` (cycles, mounts, `[autoexec]`) and `scummvm.ini` | `innoextract` an installer you own | |
| **eXoDOS / eXoWin3x** | Tuned DOSBox configs for ~7,600 DOS and ~1,100 Win3.x games | Configs inside its (huge) sets | Configs are portable; the games aren't ours to use |
| **Macintosh Garden / Macintosh Repository** | Classic Mac programs: requirements, which emulator and OS version commenters got it running in | macintoshgarden.org, macintoshrepository.org (HTML) | Downloads there are mostly abandonware: not a source for a bundle |
| **E-Maculation** | Setting up Basilisk II, SheepShaver, QEMU (q800, mac99); current Mac builds on its forum | emaculation.com | |
| **Infinite Mac** | Which OS × emulator combinations boot | infinite.mac | Browser only |
| **MobyGames** | Release dates, platforms, versions, requirements | mobygames.com (API paid since 2024) | |
| **osgameclones.com, Wikipedia "List of game engine recreations"** | A source port or reimplementation | | Check before porting a well-known game |
| **Internet Archive** | Original download URLs (Wayback `id_` copies), manuals, patches | `web.archive.org/cdx/search/cdx?url=<url>&output=json` (its `digest` is the file's SHA-1) | For download editions: the makers' URL archived, never a fan mirror. **At most one request every 4 seconds** to any archive.org host (search, metadata, downloads, Wayback): its requested limit for scripts; `refs.py` keeps to it |

## Operating the program: manuals, walkthroughs and reference pictures

A port has to be *played*: to reach a scene to test, to check a puzzle works, to know
a save point, to tell a bug from the game's design. These sources say how a program
is meant to be used, and what it's meant to look like. They are best fetched by a
`porting-researcher` subagent with a narrow question ("the steps from a new game to
the first save"; "what the main menu looks like"). Its notes go in the porting log's
"How to play it", so nobody looks them up twice.

| Source | Good for | How | Notes |
| --- | --- | --- | --- |
| **The program's own files** | Its manual, help file, on-disc walkthrough or hints, keyboard shortcuts | `find <game> -iname '*help*' -o -iname '*manual*' -o -iname '*walk*' -o -iname '*.pdf' -o -iname '*.hlp' -o -iname '*.chm'`; `pdftotext`, `7z x` on a `.chm` | First stop. Bioscopia ships `Help.pdf`, and a review says its disc has a (partial) walkthrough |
| **Adventure-game walkthrough sites**: GameBoomers, Just Adventure, UHS (Universal Hint System) | Step-by-step solutions of point-and-click and puzzle games; UHS gives graded hints | gameboomers.com/wtcheats/…, justadventure.com, uhs-hints.com | GameBoomers had Bioscopia's opening (2026-11-05); its forum has per-puzzle threads |
| **GameFAQs** | Text walkthroughs, FAQs, cheat codes for most games | gamefaqs.gamespot.com | Fetch single pages only; it blocks crawlers |
| **StrategyWiki, game Fandom wikis** (e.g. the Nancy Drew wiki) | Structured walkthroughs, item and location lists, controls | MediaWiki API: `api.php?action=parse&page=<page>&prop=wikitext&format=json` | Wikitext is far smaller than HTML |
| **ReplacementDocs, the Internet Archive** (manuals and scans) | The original manual: controls, the menu's options, system requirements | replacementdocs.com; archive.org search `<title> manual` | archive.org: at most one request every 4 s |
| **MobyGames screenshots** | What each screen should look like, per platform: a reference against which to judge colours, scaling and missing graphics | mobygames.com/game/<id>/<slug>/screenshots | Compare with our capture, side by side, before calling something a bug |
| **Longplays** (World of Longplays, YouTube "longplay"/"walkthrough") | The whole game played; how a cutscene, transition or puzzle should behave, and how long it takes | Find the moment, then take one frame (or a few with `sheet`-style sampling); never watch long stretches | Video is the dearest source: use it to settle a specific question |
| **Reviews of the time** | Known bugs, what the "limited activation area" or other quirks were, whether a problem was in the original | justadventure.com, adventuregamers.com, mysterymanor.net | Separates our bugs from the game's design |
