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

- Start each bullet with the change itself in as few words as possible,
  like a headline: "Add crash reporting.", "Fix black screens on start-up in
  some games." Then, if it helps, one sentence on what it means for the
  player. A bullet is at most two sentences: never add a third to explain
  settings, options or how the feature behaves the first time.
- Write plain, friendly sentences about what the player sees or can do. Leave
  out how it was done.
- Avoid jargon. Say "the game" or "your game's app", never "wrapp". Don't
  mention Wine, prefixes, cnc-ddraw, Direct3D, DirectDraw, AutoIt, ScummVM,
  event buses, logs or file names unless a player has to act on them. That
  holds even to say which games a change affects: write "some games", or
  name the games, never "games that use Direct3D".
- For a fix, describe the problem the player would have seen ("Some games
  showed a black screen on start-up"), not the cause.
- Merge items that are parts of the same change into one bullet. Never invent
  a change, a game title or a detail the commits don't support.
- Leave out every detail a player is unlikely to care about, even a true and
  interesting one. Weigh each detail beyond the headline by two tests and
  drop it if either applies:
  - **They already know it by convention.** Some details come with any
    familiar feature. An app that updates itself almost always has a Check
    for Updates… menu item, so mentioning that one tells them nothing. A menu
    item or setting that isn't what they'd expect is worth mentioning.
  - **They wouldn't care.** Players care that an update is offered when one
    comes out, not how often the app checks. Nobody gets excited about being
    able to add a comment to a crash report, or about which parts of a
    report are left out. How often something happens, the options inside a
    feature, or how it's arranged behind the scenes only matter when they
    change what the player experiences.

  Details that pass both tests stay, such as a step they have to take or a
  limit that would surprise them. For example, write "Add crash reporting. If
  a game fails to build or goes wrong when you play it, or Second Chance
  itself crashes, it now sends a report so the problem can be fixed.", not a
  bullet that goes on to explain the comment box, what the report contains
  and the setting that controls it.
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
messages already make them clear, and when several need a look, run their
`git show` commands together in one turn rather than one after another.

If a change is partly user-facing, describe the user-facing part and leave
the rest out. When unsure whether players would notice something, treat it as
internal.

## How it should sound

Write like a person who made the app telling a friend what's new, not like
marketing copy or an AI assistant. Readers notice the habits of AI-written
text and trust it less, so avoid them, in both sections:

- No em dashes (—) or en dashes used as punctuation. Use a full stop, a
  comma, a colon or brackets instead, or split the sentence.
- No "it's not X, it's Y", "it wasn't X, it was Y" or "not just X, but Y"
  constructions, and no lists of three for rhythm's sake.
- No filler or inflated words: "load-bearing", "seamless", "robust",
  "streamlined", "enhanced", "elevate", "leverage", "delve", "crucial",
  "vital", "key", "powerful", "smooth experience", "under the hood",
  "quietly", "genuine(ly)", "truly", "simply", "effortlessly", "now you can
  finally", "whether you're … or …", "say goodbye to", "no more".
- No editorialising or hype: "it's worth noting", "importantly", "we're
  excited", exclamation marks, or a closing line summing the release up.
- No bold, italics or emoji inside a bullet.
- Prefer short, ordinary words and sentences. If a sentence would still
  say the same with a word removed, remove it.

Before you answer, read each user-facing bullet once more against these
rules: does it start with a short headline, is it two sentences at most, does
it name any technology, and is every detail one a player would care about?
Fix any that fail.
