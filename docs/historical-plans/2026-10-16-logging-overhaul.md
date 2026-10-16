# Logging overhaul (2026-10-16)

A frozen record of why the logs were reworked and what was decided. Current
behaviour is in [docs/logging.md](../logging.md); this is not updated as the
code moves on.

## How the problems were found

Two games were built and run on a second test Mac: Secrets Can Kill
Remastered (Wine, Inno Setup installer) and Secrets Can Kill (ScummVM, two
discs). Each was then broken on purpose, fourteen ways, and the logs were read
for whether the line naming the real cause was there, findable and near the
end:

- truncated and random-bytes ISOs, another game's ISO, a missing path;
- the installer killed partway (with and without `STRICT_INSTALL`);
- a build over plain SSH, outside the GUI session;
- a read-only output folder, a corrupted cached prefix;
- a wrapp missing its game exe, with a truncated game DLL, with its game
  killed mid-play, and a ScummVM wrapp with no game data.

In only two of the fourteen did the last log line name the cause, and four
reported success after a failure.

## What was wrong

**The decisive line was suppressed, buffered, mislevelled or never written.**

- `WINEDEBUG=-all` hid Wine's `err:` class, which names the cause of most
  Wine failures: `nodrv_CreateWindow … no driver could be loaded` outside the
  GUI session, `Loading library Ndui.dll … failed` for a broken DLL.
- `runWine` buffered a run's output until exit and logged it as one entry cut
  at 4 KB, so a hung installer printed nothing for as long as it hung, and
  waited on EOF from a pipe Wine's services held open.
- A signal was reported as an exit code (SIGKILL as "exit code 9"), and a
  wrapp's game "exit code" was `ps -p`'s exit status, 1 whenever the process
  had gone.
- Subprocess stderr was logged at error wholesale. A healthy Wine launch
  logged 176 error lines and no errors; 157 were MoltenVK's info listing.
- Warnings used `.error`, so "unusual" and "failed" looked the same.

**Routine output buried the rest.** The wrapp's process monitor logged six
lines every three seconds for the whole session; msiexec's per-file lines
were 97% of a many-game integration log; under xcodebuild every line
appeared twice, in two formats, torn where the writers met.

**Context and structure were missing.** No header said which build, which
machine, whether Rosetta or a GUI session was involved. Metadata was dropped
by both handlers. Failures ended on `localizedDescription` alone, far from
the line that caused them. A wrapp opened from Finder kept no log file, and
its crash left nothing in the log.

**And the logs had been hiding real bugs**, each fixed alongside:

- the Secrets Can Kill flower-puzzle patch was run by a Unix-looking path
  Wine couldn't find, its exit code discarded, and logged as applied (it is a
  16-bit installer this Wine can't run, which is now reported as a failed
  patch);
- the engine file lists never reached the template, so every wrapp shipped
  both engines;
- a killed installer could exit 0 with half the game installed, and the
  build succeeded;
- a disc of the wrong game built that game, and sc reported the one asked for;
- a headless build fell back to an interactive installer and waited for ever;
- a wrapp crashed (SIGILL) closing its info window off the main thread when
  the game exited early;
- an interrupted `sc --on` aborted on its terminal write and left Wine
  running.

## What was decided

In rough order of how many failures each would have explained:

1. Default `WINEDEBUG` to `-all,err+all`; it costs one line on a healthy
   launch, which is classified as debug.
2. Stream every Wine run, with `▶`/`■` start and end lines (pid, exit code or
   signal, duration), a heartbeat after 30 s of silence, and timeouts.
3. End failed runs with a `FAILURE SUMMARY` block: the stage, the full error,
   the stage's first error, the last engine output, where the evidence is.
4. Give levels a meaning (`.warning` adopted), and classify subprocess lines
   by content (`SubprocessLineClassifier`), not by pipe.
5. Move repetitive output to debug, with a summary at notice, and filter only
   the terminal copy (`SECOND_CHANCE_LOG_LEVEL`), so nothing is lost.
6. Open every log with a context header and a run ID shared with children.
7. Keep a log file per wrapp launch, and widen diagnostics-bundle triggers.
8. Keep metadata and stage on entries, with a JSON-lines sink for agents.
9. Record fatal signals and report the previous crash at the next start.

Rejected or deferred: per-game expected install sizes beyond the one game
measured (the check is there; the numbers need real installs), and moving the
bracketed `[Game Monitor]`-style prefixes into categories, which would touch
most of the wrapp for little gain once levels were right.
