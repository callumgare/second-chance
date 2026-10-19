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

If it fails or is interrupted partway, it puts back the project file,
`CHANGELOG.md` and the release notes it changed, so the tree is clean for the
next attempt.

`--build-only` builds what the next release would be without changing the
repo: it writes the version into the project file for the build, runs the
tests (unless `--skip-tests`), builds and zips the app, then puts the project
file back. It writes no changelog or notes and doesn't commit, tag or push,
so it works on a dirty tree, building whatever is uncommitted.

## Publishing

Once the build is packaged it commits the project file and `CHANGELOG.md` as
`chore(release): vX.Y.Z` and tags the commit `vX.Y.Z`, both locally — the
rollback above takes them back out if either fails. It then asks whether to
push the branch and tag to `origin` and create the GitHub release with `gh`.
Answering no, or running with no terminal to ask, prints those commands
instead. A failed push or `gh release create` leaves the commit and tag in
place and names what is left to run.

The app it produces is **signed with an Apple Development certificate
and not notarized** (only a Developer ID certificate can be) — on macOS 15+
users have to approve it under System Settings → Privacy & Security, as the
Control-click bypass no longer works.
