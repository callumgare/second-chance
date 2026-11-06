# <Program>: porting report

Written YYYY-MM-DD, at the end of the port. Rung reached: **N** (<what that means for this program>).
Log: `log.md` beside this. Bundle: `Bundles/<namespace>/<name>/` (or "none").

## In short

Three to five sentences: what the program is, how it now runs (engine, platform build, notable settings),
how well, and the one thing someone porting something like it should know first.

## What the program turned out to be

What identification and unpacking showed, and anything that contradicted what it claimed to be or what
others said (an installer family, a protection, an engine version, a disc layout).

## What others knew, and what it was worth

| Source | What it said | Was it right? |
| --- | --- | --- |

## Routes

For each route tried (engine × platform build × settings): what happened, the evidence (log lines, trace
excerpts, screenshot paths in this workspace), and why it was kept or dropped.

## Findings

Each thing learned that isn't obvious from the code: a behaviour of the program, the engine, macOS, or Second
Chance's tooling. One paragraph each, with its evidence, and whether it's checked or a guess. Include the dead
ends and what each cost (time, tokens), so the next port can skip them.

## What changed in Second Chance

Commits, modules or engine settings changed, skill and tooling changes, each with why.

## Suggested improvements

What would have avoided the problems this port ran into, so the next port doesn't hit them: in Second Chance, `sc`
and its tools, a module or engine, the program bundles' format, this skill or its scripts and references. One
entry each:

- **The problem:** what happened, and where (the log's attempt, a quote of the error).
- **What it cost:** time, tokens, wrong turns, a workaround that's still in place.
- **The suggestion:** the change you'd make, and where (a file, a command, a section of the skill), and whether
  you made it (with its commit) or it's for someone to decide.

Include the small ones: a confusing message, a missing option, a limit that was too long, a step the skill
didn't mention. Leave nothing out for being outside the port's own scope.

## Still unknown or not working

What's left, what would settle each, and what the user was asked or still has to decide.
