# Program images

`ProgramImages` (`Packages/WrappKit/Sources/ProgramImages/`) finds every image in a program,
its installer, its disc or its wrapp: icons, bitmaps, pictures, a video's first frames. It
records where each was found, folds duplicates and sizes of the same art together, and ranks
them by how likely each is to be the program's own icon. `icon-extract` is its command-line
tool. Icon Lab, which designs a Mac icon for an old program, calls the library in its own
process (`ProgramImageExtractor.extract`, whose crawl stops when its task is cancelled, or
when `ExtractionOptions.isCancelled` says so; with `keepWhatWasFoundWhenCancelled` it still
ranks and writes what it found before stopping, and its summary says `stoppedEarly`) and
reads the same records and events.

It builds on `WindowsFormats` (PE and NE resources, icon groups, `.ico`, shortcuts,
`autorun.inf`, MSI streams) and `ClassicMacFormats` (resource forks, MacBinary, AppleSingle
and AppleDouble, BinHex, HFS volumes, Apple partition maps, Disk Copy 4.2). Both are in
the same package.

## icon-extract

```bash
swift build -c release --package-path Packages/WrappKit --product icon-extract
Packages/WrappKit/.build/release/icon-extract <input> --out <folder> [options]
```

The input is an installer (a disc image, `.exe`, `.msi`, an InstallShield set, `.sit`,
`.hqx` and so on), an installed program's folder, or a wrapp. The options are:

| Option | What it does |
| --- | --- |
| `--out <folder>` | Where `<sha256>.png` and `records.jsonl` go |
| `--work <folder>` | Where tools unpack to. The default is a fresh temporary folder, removed afterwards |
| `--max-depth <n>` | How many containers deep to go (default 8) |
| `--budget-mb <n>` | The most the tools may unpack in all (default: 4 × the input, at least 2 GB) |
| `--tool-timeout <s>` | Seconds a tool may run (default 120; a whole disc gets 600) |
| `--no-tools` | Read only what Swift reads natively |
| `--no-carve` | Don't look for images by their signatures |
| `--no-video` | Don't take frames from videos |
| `--filters <file>` | A filter table in place of the shipped one |
| `--verbose` | Log debug lines |

Progress goes to stdout as JSON lines. Logs go to stderr (swift-log's stream handler, at
notice and above).

The library's entry point is `ProgramImageExtractor.extract(_:options:events:)`. It runs
the crawl off the calling thread (`Blocking.run`) and calls `events` with each
`ExtractionEvent`. `extractSynchronously` does the same on the calling thread.

## Output

### records.jsonl

One object per line for each distinct image, best first:

| Key | What it is |
| --- | --- |
| `sha256` | SHA-256 of the decoded pixels (size, then RGBA, with fully transparent pixels' colour cleared) |
| `file` | `<sha256>.png`, beside `records.jsonl`: always 8-bit RGBA |
| `width`, `height` | In pixels |
| `bitDepth` | The source's bits per pixel (1 for a black-and-white icon, 4, 8, 24, 32); 0 if it didn't say |
| `hasAlpha` | Any pixel not fully opaque |
| `familyId` | The `sha256` of the family's representative. Sizes and depths of the same art share it |
| `isFamilyRepresentative` | The family's best member: the largest, then the deepest, then the best scored |
| `familySize` | How many images are in the family |
| `provenance` | Up to 50 of the places it was found, each `{"steps": [...], "display": "..."}` |
| `sources` | How many places it was found, all of them counted |
| `roles` | Why it might be, or not be, the icon (below) |
| `score`, `scoreReasons` | How likely it is to make a good icon, and each part of that as `"+45 a shortcut's icon"` |
| `dHash` | The 64-bit difference hash used to group families, in hex |

A step is `{"kind": ..., "name": ..., "detail": ...}`. The `kind` is one of `file` (the
input, or a file in an input folder), `entry` (a file in a container), `volume`,
`resource`, `fork`, `overlay`, `carved`, `frame` or `image` (always last: size and depth).
`detail` is optional and says what unpacked an entry (`"via innoextract"`).

The display joins the names with ` › `:

```text
disc.iso › SETUP.EXE › data1.cab › Game.exe › RT_GROUP_ICON 101 › 48×48 32-bit
```

The roles are:

| Role | Meaning |
| --- | --- |
| `main-program-icon` | The first icon group of the main program. For a wrapp that is the program its launch names (`AppSettings.plist`'s `Launch.program`). Otherwise it is a program a shortcut opens, or a Mac application a disc's root alias opens |
| `likely-main-program-icon` | Nothing named the main program, so it was guessed: the shallowest, then the largest, windowed program with an icon that isn't a setup, uninstaller or tool |
| `shortcut-icon` | The icon a `.lnk` shows (its `IconLocation`, or its target's) |
| `autorun-icon` | `autorun.inf`'s `icon=` |
| `volume-icon` | A Mac volume's own icon (the root's `Icon\r`) |
| `msi-icon` | An MSI's `Icon` table |
| `mac-app-icon` | A classic Mac application's own icon family, through its `BNDL` and `FREF` |
| `custom-icon` | A classic Mac file's custom icon (ID -16455, or an alias's) |
| `app-bundle-icon`, `wrapp-icon` | A Mac app's `CFBundleIconFile`. For a wrapp, Second Chance made it |
| `first-icon-group` | From any program's first icon group, the one Explorer shows |
| `icon` | From any icon group, icon file or Mac icon resource |
| `installer-own-icon` | From a setup's or uninstaller's own resources |
| `installer-art` | From an MSI's `Binary` table (wizard and banner bitmaps) |
| `title-like-name` | A name with logo, title, splash, opening, intro, box, cover and the like |
| `ui-like-name` | A name with button, cursor, font, mask, tile and the like, or a Delphi VCL glyph (`BBOK`) |
| `runtime-library` | Under a path the filter table demotes (runtime DLLs, system folders) |
| `cursor`, `bitmap-resource`, `picture`, `video-frame`, `carved` | What kind of source it came from |

How a score is made is in `Results/Ranking.swift`. Where an image came from counts most,
then its shape (size, aspect ratio, strips), then its content (one colour, and solid
black; a dark picture with detail in it isn't marked down, as it can be an icon's background).
A family's representative takes its best member's score. Icon Lab's analysis ranks the
content further; the extractor only supplies the signals.

### Events (stdout)

Each line is an object with `event` set to one of these:

| Event | Fields |
| --- | --- |
| `node` | `id`, `parent` (absent for the input), `name`, `kind` (the identifier's `FileKind`: `pe`, `iso`, `hfs-volume`…), `size`, `depth`, `display`, `installer` (`inno`, `nsis`, `installshield`…, if any), `macType` (`type/creator`, for a classic Mac file) |
| `image` | `sha256`, `node`, `width`, `height`, `bitDepth`, `display`, `new` (false for one already found elsewhere) |
| `skip` | `node` (if it had one), `name`, `reason`: a filtered path, a tool that isn't installed, a deferred format, a limit reached |
| `progress` | `nodes`, `images`, `queued`, `bytesExtracted`, at most every half second |
| `done` | `nodes`, `images`, `families`, `skipped`, `records` (the path of `records.jsonl`), `seconds` |

The `node` events' `id` and `parent` make the scan's tree. The PNG named in an `image`
event is on disk when the event is sent.

## How the crawl works

1. **Crawl.** Starting at the input, nodes are taken one at a time, depth first, in order,
   so the output is the same every run. A node is a file on the Mac, an entry in a container,
   a partition or a resource. Native readers hand on ranges of their parent (an ISO extent, a
   resource, a mapped file), so most of the crawl never writes to disk.
2. **Filter.** Each path is checked against `Resources/filters.json` before anything is read:
   text, sound, fonts, installers' own parts, Wine's own Windows, a wrapp's engines and
   frameworks, the classic Finder's desktop database. `keep` rules win over the rest, `skip`
   rules leave a path alone, and `demote` rules read it but rank its images down. Patterns
   are lower-cased globs: `**` matches any number of folders, `*` matches within a name,
   and a pattern without a `/` matches the name alone. Folders are skipped whole, and links
   aren't followed (a prefix's `dosdevices/z:` is `/`).
   When the input is a wrapp (it has `Contents/Resources/AppSettings.plist`), the `wrapp`
   rules apply too. A wrapp's program is all in `Contents/SharedSupport`. Everything in
   `Contents/Resources` is the wrapp's own: its engines' data, such as ScummVM's
   `gui-icons.dat` with the icons of every other ScummVM game. So all of it is skipped
   except the wrapp's icon (`CFBundleIconFile`, role `wrapp-icon`), and that only if it
   isn't Second Chance's generic one. A Mac app that isn't a wrapp keeps its resources.
3. **Identify.** `FileIdentifier` decides from magic bytes first and the name only to break
   a tie. It reads only the head, the tail and a program's overlay. Its tables are the porting
   skill's `identify.py`'s, including the installer markers it finds in a program.
4. **Handle.** `HandlerRegistry` lists the handlers in order, native first. A handler finds
   images, finds nodes inside its node, or both. If a native handler declines, an outside
   tool is the fallback. A file nothing reads is carved for images.
5. **Dedupe, group, rank.** Each image is hashed by its pixels. A second sighting adds its
   place and roles to the first, and its PNG is written once. At the end, images found as one
   icon form a family (a group's sizes, a Mac icon family). So do images whose difference
   hashes are within 6 bits and whose shapes match. Flat images are left out of that
   matching, as they all hash alike. Then hints from the wrapp, shortcuts, `autorun.inf` and
   aliases are matched against the end of each icon's path, and everything is scored.

### What is read natively

| Input | What comes out |
| --- | --- |
| PE and NE programs | Every `RT_GROUP_ICON`'s images (one family), loose `RT_ICON`s, cursors, `RT_BITMAP`s. Other resources become images or containers, or are carved (a Delphi form's `TImage`, IExpress's `CABINET`). The overlay: an archive at its start is queued, otherwise it is carved |
| `.ico`, `.cur`, `.ani` | Each image; DIB icons decoded with their AND mask, PNG entries by ImageIO |
| `.lnk`, `autorun.inf` | Hints at the program and icon (see the roles) |
| MSI (and any OLE file) | The `Icon` table's icons, the `Binary` table's bitmaps, embedded cabinets (to 7-Zip), image streams |
| ISO 9660 / Joliet, raw 2352-byte-sector images (BIN, most MDF and IMG) | Every file, read in place. On a hybrid disc an associated file is its namesake's resource fork |
| Apple partition maps, classic HFS, Disk Copy 4.2 | Every file with its resource fork and Finder info. HFS sits behind a partition map or at 1024 bytes beside an ISO |
| Resource forks (HFS, a Mac file's extended attribute, AppleDouble `._x`, a bare `.rsrc`) | Each icon family (`icns`, `icl8`, `icl4`, `ICN#`, `ics8`, `ics4`, `ics#`, `cicn`, `ICON`, `SICN`, masked by the family's `ICN#`/`ics#`, in the Mac's 4- and 8-bit palettes); the bundle's application family; custom icons; `PICT`s |
| MacBinary, AppleSingle/Double, BinHex 4 | The file inside, both forks |
| PNG, JPEG, GIF (first frame), BMP, TIFF, TGA, ICNS, PICT | ImageIO |
| PCX | 1-, 2-, 4- and 8-bit, planar EGA and 24-bit |
| Anything else | Carving: PNG, JPEG, GIF and BMP found by their signatures and followed to their ends by their own structure (up to 768 MB a file) |

### What the tools read

Tools are found on `PATH` and in Homebrew's folders. A tool that is missing is logged once,
and what needed it gets a `skip` event; the rest of the crawl goes on.

| Tool | For |
| --- | --- |
| `7zz` | CAB, NSIS installers, ZIP, 7z, RAR, gzip, bzip2, xz, tar, LZH, ARJ, CHM, MS-DOS `COMPRESS` (SZDD, KWAJ), `.Z`, DMG (UDIF), HFS+, UDF, and as a fallback for discs |
| `innoextract` | Inno Setup installers, with their `setup-N.bin` parts |
| `unshield` | InstallShield 5+ cabinets, from `data1.cab` with its `.hdr` and other parts |
| `unar` | StuffIt and Compact Pro; it keeps resource forks, which are read back from their attributes |
| `deark` | ILBM, MacPaint, WinHelp `.hlp` and its SHG/MRB bitmaps, InstallShield 3 `.Z`, and any image ImageIO and the native readers can't decode |
| `ffmpeg` | Smacker, Bink 1, FLIC, AVI and QuickTime: the first frame, then one every 2.5 s of the first 15 s |
| `upx` | A UPX-packed program is unpacked (`upx -d` on a copy), then read again; only its first icon group is readable packed |

Installers that nothing unpacks without running them (Wise, Setup Factory, Ghost,
Clickteam, InstallAware, Gentee, Smart Install Maker) give their stub's resources and
whatever their overlay carves. For those, point it at the installed program or the wrapp.

### Deferred

These get a `skip` event and are not read yet: Director movies and casts, Flash, Her
Interactive's CIF archives and AVF videos, DOS and DOS-extender programs, and SCUMM, SCI
and other engines' archives beyond carving.

## Safety

Every input is untrusted.

- **Nothing from the input runs, and nothing is mounted.** There is no Wine and no
  `hdiutil attach`; discs and volumes are read in user space.
- **Outside tools run sandboxed** (`Tools/ExternalTool.swift`). `sandbox-exec` runs with a
  profile that denies by default. It allows running `/bin/sh` and the tool, and reading the
  system's libraries, Homebrew's, the tool's own folder and the input's folder. It allows
  writing only to a fresh output folder, and denies the network. `/` itself must be readable,
  or the shell aborts before starting. Paths in the profile go through `realpath(3)`, since
  the kernel checks `/private/var/…`.
  - A shell sets `ulimit -f` (no file larger than the budget left allows) and `ulimit -t`
    before `exec`ing the tool.
  - The tool runs in its own process group, killed whole when it overruns its time.
  - Afterwards, links (symbolic or hard) and special files it wrote are deleted, and
    permissions are reset.
- **Limits** (`ExtractionOptions`):
  - 8 containers deep;
  - a byte budget for everything tools unpack;
  - 200:1 expansion for a tool's output beyond 64 MB;
  - 100 000 nodes and 20 000 images;
  - time limits per tool;
  - images no larger than 16 384 px a side or 64 MP, checked before decoding.
- **Native readers are bounds-checked.** A damaged file gives nil or less, never a crash or
  a hang. The tests feed every reader truncated and bit-flipped copies of its fixtures.

`sandbox-exec` is deprecated. If macOS drops it, an XPC service with App Sandbox is the
replacement, and the tests that use it are disabled by a trait where it is missing.
