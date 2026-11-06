# Ending every engine on quit, and telling the player while it does

Proposed 2026-11-06. **Rough notes, not a plan yet: build it when an engine
other than Wine is seen not to end on quit, or a module needs to tell the
player something the wrapp's windows can't say today.** Nothing has yet,
outside `sc puppet` (below).

It builds on the wrapp's runtime modules (`WrappTemplate/Modules/`,
`RuntimeModule`) and its closing window (`InfoWindowViewModel.QuitStep`,
[wrapp-launch.md](../wrapp-launch.md#closing)). Check both against the code
before taking this up.

## What prompted it

`sc puppet stop` has more than once left a ScummVM wrapp's engine
(`scummvm -f`) running after the wrapp had gone, re-parented to launchd, and
it was killed by hand. Not confirmed, but the likely cause is the same in a
player's wrapp: `GameLauncher.performCleanup` sends the game's process
SIGTERM (`process.terminate()`) and the wrapp then finishes at once. It
neither waits for the process to exit nor kills it if it doesn't. ScummVM
(SDL) turns SIGTERM into a quit event, which it may handle slowly or answer
with a question, so the engine can outlive the app: a game window, and its
sound, with no app to quit it from.

Wine doesn't have this problem because `WineRuntime` is `stopsOnQuit` and its
`finishForQuit` waits on Wine's server, asks it to stop, then makes it,
reporting each step. ScummVM and DOSBox have no `finishForQuit`.

First: confirm it. Quit a ScummVM wrapp (⌘Q, a SIGTERM to the wrapp) while
the game is busy, and with a dialog open, and look for a `scummvm` process
left behind; the same for DOSBox.

## The small part: end the engine

`ScummVMRuntime` and `DOSBoxRuntime` become `stopsOnQuit`, and their
`finishForQuit` waits for the engine's process to exit (a process source,
not a poll), gives it a few seconds, then SIGKILLs it, reporting `closing`,
`stopping` and `forcing` through `onQuitStep` as Wine does. The steps' wait
times follow `GameLauncher.quitPeriods`, longer on a loaded Mac. The closing
window then shows "Closing *Title*…" after 6 s with no other change.

`sc puppet stop` could also, as a backstop, note the wrapp's descendant
processes while a session runs and kill any still alive at the end, by pid,
checking each one's command still matches (pids are reused).

## The bigger part: modules telling the player things

What the closing window can say is a fixed enum in WrappTemplate
(`QuitStep`: closing, closing Steam, stopping, forcing), and its text lives
there. Steam already needed a case of its own. A module someone adds
([module-programs.md](../module-programs.md)) can't add one at all, and
neither can a module's executor for the build's windows.

Ideas, none weighed yet:

- **Modules supply the words.** A step carries its text (localizable, a
  whole sentence, plain words, per AGENTS.md) from the module, not a case
  the window knows. The window keeps its own wording only for the generic
  steps.
- **One status surface for every module.** The loading window's stages
  (`firstStage(gameTitle:)`, `LoadingStage`) and the closing window's steps
  are the same idea: a module saying what it's doing, and when it's slow.
  One way for a module to post "this is happening; it's taking a while; it
  failed, and here's what to do", which the wrapp shows in whichever window
  is up. Whether it should be a module of its own (a `ui` service other
  modules depend on) or part of `RuntimeModule` is open.
- **Through the module protocol.** An added module's program speaks
  `ModuleProtocol`, so the status messages would be one of its messages,
  checked against a vocabulary as `EMIT` strings are
  (`emit-vocabulary.yaml`), so text people see stays reviewable and
  translatable.
- **Signals, not timers.** "Taking a while" comes from the module's own
  signs of progress where it has them, as the launch's do
  ([wrapp-launch.md](../wrapp-launch.md)), with a time bound only where
  there's none.

## Open questions

- Does ScummVM really outlive a wrapp's quit, and DOSBox?
- Should an engine that had to be killed on quit be reported
  (`FailureReporter`)?
- Is a ui module worth it for quitting alone, or does it wait until a
  second need (an added module's first window, a build step that needs to
  say something mid-step)?
