# Big Fish Games

Big Fish Games sells 30 of the Nancy Drew games, as downloads its own app, the
**Game Manager**, installs. The Big Fish source builds a wrapp from a game the
person owns there: the Game Manager runs in the build's Wine prefix, they sign
in in its own window, pick one of their games, and it downloads, installs and
activates it.

## What Big Fish ships

- **The Game Manager** (version 4.0.1.5 when this was written) comes from
  `bfginstaller35.exe` on Big Fish's CDN, the same file for everyone (a game's
  "free trial" download from the website is a small stub that fetches it). It
  installs into `C:\Program Files (x86)\bfgclient` (about 730 MB) and is a
  Chromium (CEF) app: its whole window is one web page, from
  `C:\ProgramData\Big Fish\Game Manager\resources`.
- **A game** is identified by its SKU, `F<product>T1L<language>`: `F2435T1L1` is
  product 2435 (The White Wolf of Icicle Creek) for Windows (`T1`) in English
  (`L1`); `L2` is German and `L4` French. The catalog keeps each game's product
  number (`GameInfo.bigFishProduct`), so any language's edition maps to it
  (`BigFishSKU`, `GameInfoProvider.game(forBigFish:)`).
- The Game Manager downloads a game's installer (Big Fish's own NSIS wrapping
  tool) and a split 7z archive into `C:\BigFishCache\GameManager\GameDB\<SKU>`,
  and installs it into `C:\Program Files (x86)\Nancy Drew - <Title>`. The folder
  holds:
  - the game itself, its `.exe` wrapped in **Armadillo**, a 2000s DRM wrapper;
  - Big Fish's DRM launcher, also Armadillo-wrapped, with a random name
    (`rvlrkpp.exe`, `wqxgxgg.exe`): what the Game Manager runs to activate and
    start the game;
  - `bfgstate.xml`, which names the SKU, the launcher (`executablePath`) and,
    for a trial, its length;
  - `LaunchGame.bfg`, the message Big Fish's own Play shortcut sends.

  Its installer also runs Microsoft's DirectX web setup, which isn't needed.
- **Activation**: after installing, the Game Manager runs the launcher to
  activate the game for this computer (DRM1, against
  `activation.bigfishgames.com`). A trial's 60 minutes are kept in the prefix.

## Armadillo under Rosetta

Every Armadillo-wrapped program crashed at once under Wine on Apple silicon,
with `virtual_setup_exception stack overflow … addr 0x7ffe4800`. Two things
Rosetta 2 does differently from an Intel CPU running Windows cause it. Both are
fixed in Wine's 32-bit `ntdll.dll`, which the build patches as it bundles the
engine (`setup-wine.sh` → `WrappTemplate/RosettaFaultFix/`, the patcher in
`Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/RosettaFaultFix.swift`).

1. **An `fs:` access with the `0x67` address-size prefix** (16-bit addressing in
   32-bit code). Armadillo removes each of its exception handlers with
   `pop dword fs:[0000]` encoded that way (`64 67 8F 06 00 00`). Rosetta raises
   an access violation for it instead of running it. Armadillo's handler then
   skips over it two bytes at a time, as if it were a fault it caused on
   purpose, so the handler record stays linked; its stack slot is reused, and
   the next deliberate fault calls whatever is there (0x7FFE4800) until the
   stack runs out. Rosetta runs the instruction correctly when it's
   single-stepped, which is how it was found.
2. **The Windows 9x check.** Armadillo's runtime tells Windows 9x from NT by the
   high byte of the code segment selector: 0 on NT (`cs` 0x1B, or 0x23 for a
   32-bit program on 64-bit Windows). Wine on macOS runs 32-bit code in an LDT
   segment, `cs` 0x0107, so Armadillo takes the 9x path and probes for the
   SoftICE debugger with `int 68h`, which faults (Wine reports a read of
   0xFFFFFFFF), and Armadillo gives up with "Access violation at 0x00EEC5D8".
   The selector can't change: Rosetta only runs 32-bit code in such a segment,
   and Wine's Windows version setting doesn't affect it. Without SoftICE,
   `int 68h` does nothing, and that's what the fix makes it do (`int 41h`, the
   other 9x debugger probe, likewise).

The patch replaces `KiUserExceptionDispatcher`'s first two instructions with a
jump to code placed in the unused end of `.text`'s last file page. That code
(`fault_fix.c`) looks at the faulting instruction: for those two cases it does
what Windows would have done and resumes the thread with `NtContinue`; for
anything else it carries on into Wine's dispatcher, so no other program
notices. It runs in every 32-bit Wine program, before vectored and frame-based
handlers alike, which covers Armadillo's second process (it runs the game as a
child under its own debugger) as well as the Game Manager's launcher. The code
is compiled once with MinGW and committed as bytes (`regenerate.sh` rebuilds
them and checks they need no relocations). The patcher refuses an `ntdll.dll`
whose dispatcher doesn't start as expected, so a Wine upgrade that changes it
fails the build rather than shipping unpatched.

Red herrings, for whoever looks next:

- Wine logs "Setting debug registers is not supported under Rosetta, faking
  success" hundreds of times. Armadillo only writes DR7 = 0x155 with DR0–3 = 0
  (an anti-debugger trick); faking it is harmless.
- Wine under Rosetta pushes a single-stepped `call`'s return address 4 bytes
  too low. It only matters to tools that trace with the trap flag; Armadillo's
  own `iret` single-step trick isn't a `call` and works.
