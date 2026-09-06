# Changelog

All notable changes to Second Chance. Generated from the commit history by
[cocogitto](https://docs.cocogitto.io); run `./prepare-release.sh` rather than
editing this file by hand.

## 0.3.0 — 2026-09-05

### Bug Fixes

- Caching logic for wine and scummvm
- Don't show cancel error if build not started
- Log to console when run from terminal
- Use native os fullscreen for wine
- Ci tests

### Documentation

- Add more info on wrapp build process
- Update docs after refactor

### Features

- Apply all game patches
- Add setup for applying game patches
- Add export/import from log window
- Improve log window formatting

### Refactoring

- Use one system for test input injection
- Rename GameWrapper to WrappTemplate
- Use the name wrapp
- Extract headless CLI driver from InstallationViewModel
- Inject dependencies into build services
- Replace InstallationContext with unified WrappBuildInput
- Extract GameInstallerRunner and ISOMounter from install services
- Use swift-log for logging

