# Checking that an install finished (2026-10-16)

A frozen record of why a wrapp build asks each installer whether it finished,
rather than measuring what it left. Current behaviour is in
[docs/wrapp-build.md](../wrapp-build.md); this is not updated as the code
moves on.

## The problem

An Inno Setup install of Secrets Can Kill Remastered that was killed partway
exited 0 under Wine, with `Secrets.exe` already unpacked. The build only
looked for the game's exe, so it succeeded with half a game, which quit
seconds after launching.

The first fix was a per-game minimum installed size (`minimumInstalledBytes`
in `GameInfoProvider`). It only works for games someone has measured, which
was one, and needs a full install of every game to fill in.

## What was tried

Each installer family was run by hand on a second test Mac, once left to
finish and once with its processes killed partway, and what each left behind
was compared:

| Installer | Finished | Killed partway |
| --------- | -------- | -------------- |
| Inno Setup (Secrets Can Kill Remastered) | `/LOG` ends `Installation process succeeded.`; an `…_is1` uninstall key with `EstimatedSize` 581 MB | Killing only the worker (`setup.tmp`): **Wine exit 0**, 159 MB of 560 MB, the log stops mid-file, no uninstall key. `unins000.dat` is written at the start, so it proves nothing |
| MSI (The Captive Curse) | Log ends `Action ended …: INSTALL. Return value 1.`; an uninstall key, `EstimatedSize` 0 | Neither |
| InstallShield 6, `setup.iss` (Danger by Design) | `/f2` `setup.log` with `ResultCode=0`; an uninstall key; `setup.ilg` in the install folder | **`setup.log` with `ResultCode=0` 8 s in**, and the same uninstall key, with 96 MB of 944 MB; no `setup.ilg`. Killing `IKernel.exe` left `Setup.exe` hanging, which the install timeout covers |

The AutoIt-driven InstallShield games run the same engine; a built Danger on
Deception Island and Last Train to Blue Moon Canyon both had `setup.ilg`.
The ScummVM games have no installer to check.

## What was decided

- Check the record each family writes only once it has finished: Inno's
  success line, MSI's `INSTALL` result, InstallShield's `setup.ilg`. Fail the
  attempt as `installIncomplete` when it is missing, naming the log's last
  line where there is a log.
- Give Inno installs (and Inno patchers) a `/LOG` and stream it like the MSI
  log.
- Drop `minimumInstalledBytes`: a check that needs a measurement per game
  covers the games nobody measured not at all. The size is still logged.

Rejected: the uninstall registry key (InstallShield writes it before copying
files, and reading it needs wineserver to have flushed the registry), Inno's
`EstimatedSize` (Inno only), and InstallShield's `setup.log` (written early,
saying success).

_Post-implementation note, 2026-10-16 (Claude, during the first all-games
run): InstallShield 7 and later (here InstallShield 12: White Wolf, Crystal
Skull, Phantom of Venice, Lost Queen, Deadly Device) write `setup.ilg` under
`Program Files (x86)\InstallShield Installation Information\{GUID}`, not the
install folder, so the check failed every one of them. A Lost Queen install
killed at 517 MB of 2.2 GB had that folder but no `setup.ilg`, so the check
now looks there too._
