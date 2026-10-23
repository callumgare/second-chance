# Releasing

`./sc release` prepares a release; `./sc release --dry-run` shows what one
would contain without writing anything. The version comes from the
conventional commits since the last tag — see
[AGENTS.md](../AGENTS.md#releasing) for the commit-message rules that decide
it.

## Lint first

Straight after its preflight checks, before it works out the version or has
Claude Code rewrite the notes, `sc release` runs the linters, as `sc lint`
does ([dev-cli.md](dev-cli.md#lint)). If they find anything it shows what, and
asks whether to release anyway, defaulting to no; a run that can't ask stops.
A dry run only reports what they found.

Then, before the long part of the run, it asks whether to publish the release
as soon as it's built rather than stop for you to check the build first,
defaulting to no ([Publishing](#publishing)). The tests, build and symbol
upload take a while, so answering yes lets you leave it to finish. The notes
still stop for review before any of that starts.

## What it writes

- **The version.** `MARKETING_VERSION` goes into the `SecondChance` and
  `WrappTemplate` targets only; `WrappPuppeteer` and `SecondChanceTests` are
  never shipped and stay at 1.0. `CURRENT_PROJECT_VERSION` is set to the commit
  count, which matters beyond bookkeeping: `WineManager` keys its prefix cache
  on the bundle version, so a release that didn't change it would hand users a
  stale Wine prefix.
- **`CHANGELOG.md`.** Each release's section holds its release notes
  ([below](#release-notes)) and goes above the previous one. Don't edit it by
  hand: edit the notes when `sc release` pauses for them, or let it regenerate
  them. When a section for the version already exists
  — usually left by an earlier attempt — it asks whether to replace it, and
  keeps it when there's no terminal to ask.
- **`build/release/RELEASE_NOTES.md`** and **`build/release/SecondChance.zip`**,
  after running the unit tests and a Release build (`--notes-only` stops before
  those, `--skip-tests` skips the tests).
- **A check that the build has a Sentry DSN.** It comes from `SENTRY_DSN` in
  `.env`. Without it the release would send no failure reports, so the
  release stops ([failure-reports.md](failure-reports.md#the-dsn)).
- **`build/release/dSYMs.zip`**, the Release build's debug symbols, which
  are also uploaded to Sentry with `sentry-cli`, so that crash reports from
  this version show function names
  ([failure-reports.md](failure-reports.md#symbolication)). `--build-only`
  skips this step. A failed upload stops the release before anything is
  committed or published, because a release whose crashes can't be read is
  worth fixing first. The upload needs:
  - `sentry-cli` (`brew install getsentry/tools/sentry-cli`; `sc setup`
    lists it);
  - `SENTRY_ORG` and `SENTRY_PROJECT` in `.env` (see `.env.example`);
  - an auth token with the `project:releases` scope in the login keychain:
    `security add-generic-password -s sentry-auth-token -a "$USER" -w <token>`.
- **`build/release/appcast.xml`**, the feed installed copies check for updates.
  It is signed with the Sparkle key in the login keychain, and the release
  stops if that key isn't the one the app trusts. A release can't be made
  without the key. [updates.md](updates.md) covers the feed and the key.

## Release notes

[cocogitto](https://docs.cocogitto.io) generates the notes from the commit
messages since the last tag, with `.cog/release-notes.tera`. Those are written
for developers, so when Claude Code is installed (`claude` on the `PATH`),
`sc release` has it rewrite them for players. It runs `claude -p` with the
instructions in `.cog/release-notes-prompt.md`, the generated notes and the
full commit messages since the last tag. Where a message doesn't make a change
clear, the prompt has it look at the change itself. It may only read: `git
show`, `git log` and `git diff`, and the repo's files, with no MCP servers, and
`--permission-mode dontAsk` refuses anything else rather than asking. It answers in a fixed JSON
shape and `sc` lays out the Markdown (`ReleaseNotes` in `Tools/sc`):

- Changes a player would notice, in plain language under **New**,
  **Improved** and **Fixed**.
- Everything else — `sc`, tests, docs, refactors, diagnostics — in a
  collapsed `<details>` section headed **Behind the scenes**. Since it costs
  the reader nothing until opened, these say what changed and why rather than
  only naming the change.

Nearly all of its time goes on thinking before it writes, not on looking
at commits, so it runs with `--model sonnet --effort low` unless
`--notes-model` or `--notes-effort` says otherwise (`default` for either
leaves it to Claude Code). Low took about 30 s on a 34-commit release where
Claude Code's defaults took nearly three minutes, and medium about 90 s, with
notes no better. Its output is
streamed (`--output-format stream-json`), so the step's spinner says what it
is doing — which commit it is reading, a file, writing the notes — and how
long it has taken, and the whole session is kept in
`DerivedData/sc-logs/<time>-release-notes.log`, which `sc release` names once
the step ends.

To change how the notes read, edit the prompt. Without Claude Code, with
`--plain-notes`, or when the rewrite fails, the generated notes are used as
they are; a release never stops for want of nicer notes. `--dry-run` runs the
rewrite too and prints the result.

Then `sc release` writes the notes into the version's section of
`CHANGELOG.md`, prints them and pauses so you can edit them there. That is the
committed copy, so it's the one to edit. When you continue, it reads the
section back, and what it says then goes into `build/release/RELEASE_NOTES.md`
(the GitHub release's notes) and the appcast. Answering no stops the release. Run with no terminal to ask, it
doesn't pause. The appcast gets the notes without their `<details>` sections,
since Sparkle's update window renders Markdown but not HTML.

If it fails or is interrupted partway, it takes its own changes back out of
the project file, `CHANGELOG.md` and the release notes, so the tree is clean for
the next attempt. Only its own changes: anything else in those files — edited
before the run or while it was building — is kept. A file that changed after
the release wrote it is put back with a three-way merge (`git merge-file`), and
when the other change touched the same lines the file is left alone and named,
for you to sort out by hand.

`--build-only` builds what the next release would be without changing the
repo: it writes the version into the project file for the build, builds and
zips the app without running the tests (it implies `--skip-tests`) and skips the appcast, then takes
its version change back out of the project file, as above. It writes no changelog or notes and doesn't commit, tag or push,
so it works on a dirty tree, building whatever is uncommitted.

## Publishing

Once the build is packaged it commits the project file and `CHANGELOG.md` as
`chore(release): vX.Y.Z` and tags the commit `vX.Y.Z`, both locally — the
rollback above takes them back out if either fails. Unless you said at the
start to publish once built, it then asks whether to push the branch and tag to `origin` and create the GitHub release with `gh`,
with the zip and `appcast.xml` attached. Publishing the release is what offers
the update to installed copies, since their feed is the latest release's
appcast.
Answering no, or running with no terminal to ask, prints those commands
instead. A failed push or `gh release create` leaves the commit and tag in
place and names what is left to run.

So that last step can't be the first to find out the account is wrong, the
preflight checks that the account `gh` is signed in as can write to the repo,
and stops before anything is written if not. GitHub answers a release created
without that access with a 404, which `gh` blames on a missing `workflow`
scope — the check names the account and its permission instead.

`gh` has one active account, not one per repo, so `sc release` runs it as the
account named after the repo's GitHub owner when `gh` is signed in to one
(`gh auth token --user <owner>`), and as the active account otherwise. A
`GH_TOKEN` already set wins over both.

The app it produces is **signed with an Apple Development certificate
and not notarized** (only a Developer ID certificate can be) — on macOS 15+
users have to approve it under System Settings → Privacy & Security, as the
Control-click bypass no longer works. That approval is needed only once:
updates installed through the app skip it ([updates.md](updates.md)).
