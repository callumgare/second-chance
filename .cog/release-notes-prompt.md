You are writing the release notes for a new version of Second Chance, a free
Mac app that lets people play the classic Nancy Drew PC games on modern Macs.
Someone points it at their game (an old CD, a download from Her Interactive,
or their Steam library) and it builds a Mac app for that game that they can
open like any other.

The people reading these notes are Nancy Drew fans, not developers. Most of
them know nothing about Wine, Steam's internals or how the app is built. They
read the notes in the app's update window and on the GitHub release page.

Below are the notes generated from this release's commit messages, followed by
the full commit messages, which explain what each change was for. Review
every item in the generated notes and decide who would care about it.

**User-facing changes** are ones a player would notice: something new they
can do, something that works better or looks different, or a problem they may
have hit that is now fixed. Rewrite each one so a non-technical player
understands what changed for them and why it matters.

- Write plain, friendly sentences about what the player sees or can do. Leave
  out how it was done.
- Avoid jargon. Say "the game" or "your game's app", never "wrapp". Don't
  mention Wine, prefixes, cnc-ddraw, AutoIt, ScummVM, event buses, logs or
  file names unless a player has to act on them.
- For a fix, describe the problem the player would have seen ("Some games
  showed a black screen on start-up"), not the cause.
- Merge items that are parts of the same change into one bullet. Never invent
  a change, a game title or a detail the commits don't support.
- Keep each bullet short, usually one sentence. Say what changed for the
  player, then weigh each further detail by two tests and leave it out if
  either applies:
  - **They already know it by convention.** Some details come with any
    familiar feature. An app that updates itself almost always has a Check
    for Updates… menu item, so mentioning that one tells them nothing. A menu
    item or setting that isn't what they'd expect is worth mentioning.
  - **They wouldn't care.** Players care that an update is offered when one
    comes out, not how often the app checks. How often something happens,
    or how it's arranged behind the scenes, only matters when it changes
    what they experience.

  Details that pass both tests stay, such as a new setting they'd want to
  know about, a step they have to take, or a limit that would surprise
  them. For example, write "Second Chance now updates itself when a new
  version comes out", not "It checks once a day and offers to install it,
  and there's a Check for Updates… item in the app menu".
- Put each bullet under exactly one heading: `New` for something they
  couldn't do before, `Improved` for something that works better, `Fixed` for
  a problem that is gone.

**Internal changes** are ones no player would notice: the developer's
command-line tool (`sc`, scope `sc-cli`), tests, documentation, refactors,
build and release tooling, and logging or diagnostics that only a developer
reads. These go in a section that is collapsed until someone opens it, so
they cost the casual reader nothing: describe each one fully enough that a
curious reader understands what changed and why, in plain language, a
sentence or a few. Technical terms are fine here when they're the clearest
way to say it.

Each commit message starts with `commit <hash>`. If a message doesn't make
clear what changed for players, or leaves out something that would change how
you'd describe it (which games it affects, what the player actually saw
before, whether it's visible at all), look at the change itself: `git show
<hash>` shows its diff, and you can read files in the repository for more
context. You can only read, not change anything. Don't dig into changes whose
messages already make them clear.

If a change is partly user-facing, describe the user-facing part and leave
the rest out. When unsure whether players would notice something, treat it as
internal.
