# Releasing

`./sc release` prepares a release; `./sc release --dry-run` shows what one
would contain without writing anything. The version comes from the
conventional commits since the last tag — see
[AGENTS.md](../AGENTS.md#releasing) for the commit-message rules that decide
it.

## What it writes

- **The version.** `MARKETING_VERSION` goes into the `SecondChance` and
  `WrappTemplate` targets only; `WrappPuppeteer` and `SecondChanceTests` are
  never shipped and stay at 1.0. `CURRENT_PROJECT_VERSION` is set to the commit
  count, which matters beyond bookkeeping: `WineManager` keys its prefix cache
  on the bundle version, so a release that didn't change it would hand users a
  stale Wine prefix.
- **`CHANGELOG.md`.** Generated from the commit history by
  [cocogitto](https://docs.cocogitto.io), with each release's section added
  above the previous one. Don't edit it by hand: fix the commit messages, or
  let `sc release` regenerate it. When a section for the version already exists
  — usually left by an earlier attempt — it asks whether to replace it, and
  keeps it when there's no terminal to ask.
- **`build/release/RELEASE_NOTES.md`** and **`build/release/SecondChance.zip`**,
  after running the unit tests and a Release build (`--notes-only` stops before
  those, `--skip-tests` skips the tests).
- **`build/release/appcast.xml`**, the feed installed copies check for updates.
  It is signed with the Sparkle key in the login keychain, and the release
  stops if that key isn't the one the app trusts. A release can't be made
  without the key. [updates.md](updates.md) covers the feed and the key.

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
rollback above takes them back out if either fails. It then asks whether to
push the branch and tag to `origin` and create the GitHub release with `gh`,
with the zip and `appcast.xml` attached. Publishing the release is what offers
the update to installed copies, since their feed is the latest release's
appcast.
Answering no, or running with no terminal to ask, prints those commands
instead. A failed push or `gh release create` leaves the commit and tag in
place and names what is left to run.

The app it produces is **signed with an Apple Development certificate
and not notarized** (only a Developer ID certificate can be) — on macOS 15+
users have to approve it under System Settings → Privacy & Security, as the
Control-click bypass no longer works. That approval is needed only once:
updates installed through the app skip it ([updates.md](updates.md)).
