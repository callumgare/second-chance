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

Second Chance copies the wrapper from inside itself for each game and installs the game into the copy. Code both apps
use is in local Swift packages: what any program that builds or runs wrapps needs (logging, running processes and Wine,
reading Windows programs) in `Packages/WrappKit/`, and Second Chance's own (driving Steam, its windows, failure reports)
in `Packages/SecondChanceKit/`, which has two modules: `SecondChanceKit`, and `SecondChanceReporting`, which holds
everything that uses Sentry. WrappPuppeteer, the tool the
integration tests drive games with, uses `SecondChanceKit` too. Each game Second Chance knows is described by a program bundle in `Bundles/`
([docs/program-bundles.md](docs/program-bundles.md)), and the list made from them is a package of its own,
`Packages/GameCatalog/`, which the developer CLI uses as well.
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

- **Xcode 26** or later, which provides `xcodebuild`, Swift and the macOS SDK. The packages need Swift 6.2's tools
  (`swift-tools-version: 6.2`, default actor isolation), which Xcode 26 is the first to have.
- **Homebrew** packages:

  ```bash
  brew install xcbeautify xctesthtmlreport cocogitto swiftlint node
  ```

  `xcbeautify` tidies build and test output, `xctesthtmlreport` makes HTML test reports, `cocogitto` checks
  commit messages and works out release versions, and `swiftlint` and `node` (for markdownlint, through `npx`) run
  `./sc lint`. `./sc setup` checks for each of them and says what's missing.

Then, once per clone:

```bash
./sc setup
```

`./sc` is the developer CLI for building, running, testing and releasing. `sc setup` checks for the tools above,
installs the commit-message hook (see [Commit messages](#commit-messages)) and, if you use VS Code, links in
Wrappfile highlighting ([docs/wrappfile.md](docs/wrappfile.md#highlighting-in-vs-code)). `./sc --help` lists every command, and
[docs/dev-cli.md](docs/dev-cli.md) explains them. The first run also builds `sc` itself (a Swift package in
`Tools/sc/`), which takes half a minute.

Everything else — Wine, ScummVM, AutoIt and the game patches — is downloaded and cached in
`~/Library/Caches/SecondChance/` during the build, so you don't need to install it yourself. Each download is pinned
to a version and checked against its SHA-256 (`WrappTemplate/download-verified.sh`), so updating one means changing
its hash in the setup script (or the patch manifest) too. winetricks is committed, in `SecondChance/Resources/`.

## Building and running

```bash
./sc app build                 # Build Second Chance.app
./sc app run                   # Build it and launch it, with its log in this terminal
./sc wrapp build <game-slug>   # Build a game's wrapp without the GUI, from installers/<game-slug>/
./sc wrapp run <game-slug>     # Launch that wrapp
```

The app lands in `DerivedData/Build/Products/Debug/Second Chance.app` and wrapps in `built-apps/`. Game slugs are the
folder names in [Bundles/nancy-drew/](Bundles/nancy-drew/), such as `scarlet-hand`.

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
keeps bringing a full-screen game to the front, so name the games rather than running them all.
[docs/testing.md](docs/testing.md) covers it all.

### Running integration tests without losing your Mac

An integration test plays each game full-screen, so a long run takes over your screen, and anything you click can fail
it. Run long tests in a **test account** instead: a second user on the Mac, logged in in the background with a screen
of its own. The games play there at full quality while you keep using yours. It can be the Mac you're on, or another
Mac you can reach over SSH.

**Setting it up**, once per Mac, as an admin who uses that Mac's display:

```bash
./sc session add                    # on this Mac: one test account, second-chance-testing-1
./sc session add --count 3          # or three: second-chance-testing-1, -2 and -3
./sc --on <host> session add        # on another Mac, from a terminal here
```

It asks for your password twice: once for `sudo`, to make the account, and once (over SSH) to unlock your keychain,
where it keeps the account's password. It also:

- lets the account in over SSH and Screen Sharing with your SSH keys, so `sc` can reach it;
- moves your checkout's `installers/` into `/Users/Shared/second-chance/installers`, where every account on the Mac
  shares one copy, and leaves a link in its place;
- starts the **keep-alive**.

**Why the keep-alive.** macOS only keeps drawing a background account's screen while someone is watching it through
Screen Sharing; with nobody watching, it locks the account within moments and games there stop drawing. So your own
account, the one at the display, runs `sc session keep-alive`: a small background job that connects to each test
account as Screen Sharing would, logs it in when it isn't, unlocks it when it locks, and draws nothing. It costs about
20 MB and no noticeable CPU, and starts again at every login. Its log is
`~/Library/Logs/SecondChance/session-keep-alive.log`; `./sc session keep-alive --uninstall` removes it. Because it runs
in your account, a test account only stays usable while you're logged in at that Mac.

**Running tests there.** See the accounts, claim one, and run in it with `--on`:

```bash
./sc session                                                     # each account: logged in, locked, free or claimed
./sc session claim --purpose "scarlet-hand integration"          # gives you a free one, say second-chance-testing-1
./sc --on second-chance-testing-1@localhost:~/second-chance test integration scarlet-hand
./sc session release
```

For another Mac, put its name in place of `localhost` and add `--on <host>` to `claim` and `release`. `--on` copies
your checkout into the account and runs the command there, building whatever it needs. The first run in an account
takes a few minutes longer, while it builds `sc` and the app there and fetches the game engines into the account's
cache. A run carries on if your connection drops; `./sc --on second-chance-testing-1@localhost:~/second-chance attach` picks it up.

Each account is a separate user, so it has its own build, its own copies of game apps, and its own `.env`: copy yours
in (`scp .env second-chance-testing-1@localhost:second-chance/`) if the tests need its settings, such as the Big Fish test account.
A game in a test account still uses the Mac's processor, so a run there slows down anything heavy on the same Mac.
[docs/dev-cli.md](docs/dev-cli.md#test-sessions) has how it all works.

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
