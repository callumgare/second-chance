# Contributing to Second Chance

Good luck (and also thank you very much for considering helping out).

This is the guide to working on Second Chance's code. If you only want to play the games, the [README](README.md) is
all you need.

## How it fits together

There are two main parts:

- **Second Chance** is the app people open. It takes a game's installer (from a CD, Steam, or a Her Interactive
  download), installs the game, and saves the result as a new app.
- **The game wrapper app** (`WrappTemplate`, a _wrapp_ for short) is the app Second Chance makes. It holds everything
  needed to run one game — Wine or ScummVM, their settings, and the installed game itself.

Second Chance copies the wrapper from inside itself for each game and installs the game into the copy.
[docs/wrapp-build.md](docs/wrapp-build.md) walks through a build step by step, and [AGENTS.md](AGENTS.md) has the
architecture, code conventions, and the gotchas that have caught people out. Read it before making a non-trivial
change — it's written for AI coding agents, but it's just as useful for people.

### A bit of history

Second Chance started as a simple bash script to automate making a Wine wrapper for some of the games. Its scope grew
until it was far bigger than a shell script should be, and quite brittle, so it was ported to a Swift app. I'd never
written Swift before, so the port leaned heavily on Claude, and the focus was on getting it working first. Some of the
code shows that, and I hope to keep cleaning it up over time.

## Getting set up

You'll need:

- **Xcode 16** or later, which provides `xcodebuild`, Swift and the macOS SDK.
- **Homebrew** packages:

  ```bash
  brew install xcbeautify xctesthtmlreport cocogitto
  ```

  `xcbeautify` tidies build and test output, `xctest-html-report` makes HTML test reports, and `cocogitto` checks
  commit messages and works out release versions.

Then, once per clone:

```bash
./sc setup
```

`./sc` is the developer CLI for building, running, testing and releasing. `sc setup` checks for the tools above and
installs the commit-message hook (see [Commit messages](#commit-messages)). `./sc --help` lists every command, and
[docs/dev-cli.md](docs/dev-cli.md) explains them. The first run also builds `sc` itself (a Swift package in
`Tools/sc/`), which takes half a minute.

Everything else — Wine, ScummVM, winetricks, AutoIt, exiftool — is downloaded and cached in
`~/Library/Caches/SecondChance/` during the build, so you don't need to install it yourself.

## Building and running

```bash
./sc app build                 # Build Second Chance.app
./sc app run                   # Build it and launch it, with its log in this terminal
./sc wrapp build <game-slug>   # Build a game's wrapp without the GUI, from installers/<game-slug>/
./sc wrapp run <game-slug>     # Launch that wrapp
```

The app lands in `DerivedData/Build/Products/Debug/Second Chance.app` and wrapps in `built-apps/`. Game slugs are the
`id`s in [GameInfoProvider.swift](SecondChance/Services/GameInfoProvider.swift), such as `scarlet-hand`.

### Building without `sc`

`sc` passes `ONLY_ACTIVE_ARCH=NO` to every build, and the build fails without it. The wrapper app is built for Intel
only (`ARCHS = x86_64`, because Wine is 32-bit), while everything else is universal. A build of only the active
architecture on Apple silicon gives the swift-log package an arm64 slice alone, and the wrapper then fails with
`unable to resolve module dependency: 'Logging'`. Running the build under `arch -x86_64` instead doesn't reliably fix
it. [AGENTS.md](AGENTS.md#build-run-test) has the details.

So if you call `xcodebuild` yourself, pass the flag:

```bash
rm -rf DerivedData    # clear any arm64-only Logging module left behind
xcodebuild -project SecondChance.xcodeproj \
    -scheme SecondChance \
    -configuration Debug \
    -derivedDataPath DerivedData \
    ONLY_ACTIVE_ARCH=NO \
    build
```

In Xcode, set **Build Settings → Build Active Architecture Only → Debug → No**.

## Testing

```bash
./sc test unit                        # Unit tests (seconds) — run these often
./sc test integration scarlet-hand    # Install, launch and quit one game for real
./sc lint                             # SwiftLint and markdownlint, as CI runs them
```

Integration tests need the game's installer in `installers/<game-slug>/`. Running them for every game takes hours and
keeps bringing a full-screen game to the front, so name the suite rather than running a bare `./sc test`.
[docs/testing.md](docs/testing.md) covers it all.

## Writing for players

Second Chance is for people who aren't into computers, so anything it shows
them — windows, alerts, progress steps, error messages — is in plain,
friendly language: "disc" not "disk", "the game's app" not "wrapp", and no
"Wine" or other jargon. [AGENTS.md](AGENTS.md#code-conventions) has the
details. Developer words are fine in code and logs.

## Documentation

`docs/` holds a document for each feature, and the table in [AGENTS.md](AGENTS.md#documentation) says when to read
each. A change that makes a doc wrong includes fixing the doc.

## Commit messages

Commits use [conventional commits](https://www.conventionalcommits.org) — `feat: …`, `fix: …`, `docs: …` and so on.
`./sc release` works out the next version and the changelog from them, so a message that doesn't follow the format
silently drops out of the release notes. The hook `./sc setup` installs rejects one at commit time.
[AGENTS.md](AGENTS.md#releasing) explains which types bump the version.
