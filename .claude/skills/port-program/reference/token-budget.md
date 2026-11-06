# Token budget: what looking costs, and when it pays

Written 2026-11-05 for Claude Opus 5.5 (the model this skill runs on, through a
Claude subscription). Check [Anthropic's vision docs](https://platform.claude.com/docs/en/build-with-claude/vision)
when the model changes: the numbers below are its "high-resolution" tier.

The commands named below are `sc puppet`'s (`docs/dev-cli.md#puppet-sessions`): `do`
replies with what changed, `wait`, `text` (OCR), `shot`, `log --count`. A whole screen
(a prompt, an installer) is `sc session screenshot [<user>] --on <host>`.

## What a picture costs

An image costs **⌈width ÷ 28⌉ × ⌈height ÷ 28⌉ tokens**. Anything with a long edge
over 2,576 px, or over 4,784 tokens, is scaled down to fit, so 4,784 is the most one
image costs.

| What | Pixels | Tokens |
| --- | --- | --- |
| A crop around a button or a line of text | 300 x 200 | 88 |
| A DOS game's frame | 320 x 200 | 96 (too small to read well: send it at 2x, 640 x 400, for 345) |
| A Windows game at 640 x 480, as the game draws it | 640 x 480 | 414 |
| 800 x 600 | 800 x 600 | 638 |
| 1024 x 768 | 1024 x 768 | 1,036 |
| ScummVM's 2x window, or a Peekaboo window shot of a 2560 x 1440 screen | 1280 x 992 | 1,656 |
| 1080p | 1920 x 1080 | 2,691 |
| A 2560 x 1440 screen, whole | 2560 x 1440 | 4,784 |

For comparison, a line of text is about 10–20 tokens, and an OCR listing of a
dialog or menu is about 100–300.

## A turn costs more than a small picture

Every tool call is a turn, and every turn re-reads the whole context. Most of it
comes from the cache, at a reduced rate, but it still counts. Deep into a long
session that is tens of thousands of tokens a turn. So:

- **One look that answers beats three cheap ones that don't.** A 640x480 frame
  (414 tokens) costs less than the extra turn it saves. Climbing from `state` to
  `text` to `ask` to a picture, one call each, is the expensive way.
- **Ask for everything you'll need in one call.** Chain commands in one shell call,
  and prefer tools whose reply carries the outcome, the change and the text at once.
  Steps that need no judgement between them go in one `do` with `--then`
  (`do <name> key escape --then "key down" --then "key return"`), each step
  still replied to.
- **Text isn't free either.** Tool output stays in the context too. A 30-line
  listing costs about what a game frame does. Ask for what's needed (`--max`,
  `grep`, counts), not everything.

## A picture keeps costing after it's read

- **It stays in the context** for the rest of the session, or until it's
  compacted, and every later turn carries it. Cached reads are cheaper than new
  input but still count toward the subscription's usage. Ten full screenshots early
  in a long session are still being paid for hours later.
- **The context fills, and compaction comes sooner.** Compaction summarises and
  loses detail.
- **Over 20 images in one request,** every image gets a stricter size limit,
  earlier ones included.

So the cost of a look is its tokens times how long the session goes on. That's the
case for doing picture-heavy work (playing through a game, comparing many frames)
in a **subagent**: its pictures die with it, and only its text report comes back.

## When each kind of look pays

Commands are `sc puppet …` (`docs/dev-cli.md#puppet-sessions`), run in a test
account: `sc --on <user>@<host>:<path> puppet <verb> <name> …`.

| Situation | Usually best first | Why |
| --- | --- | --- |
| Did my click/key do anything? | `do`'s reply: `changed N%`, new windows, program ended | A yes/no question; a picture adds nothing |
| Is it still loading / black / playing video? | `wait --still <s>` / `--change`, `log --count` | Measured from thumbnails; the log says why |
| What does this dialog / menu say, and where? | `text` (OCR, with points to click) | Real text and its place; Bioscopia's whole main menu came this way |
| Where's the button labelled X? | `text`, then `do click` at its centre | OCR gives the box |
| Which screen am I on (one seen before)? | `text`; named screens are planned (`screen`, not built) | |
| A screen nothing has described yet | **Look at it** (`shot`; ~285 tokens at 0.4 of 1280x992) | The context of a whole screen is what you need; a summary may mislead |
| A nearly black screen with hidden buttons | One `shot`, brightened here (`magick in.png -level 0%,25% out.png`) | Bioscopia's start button was invisible until brightened |
| Something's wrong and I don't know why | **Look**, plus `log --count` | Understanding beats checking; one picture can save several wrong turns |
| Where are the hotspots in a painted scene? | Look; a hover probe is a candidate (not built) | Local models fail on game art |
| Does it look right (colours, scaling, glitches)? | **Look**, ideally beside a reference picture | A judgement only you can make |
| Many routine steps to reach a point | A **subagent**, or a script of commands | Keeps their pictures out of your context |

**What the tools get wrong:**

- `shot` and `text` never capture above the window's own scale: an OpenGL game's
  surface comes back at its own size in a corner of a bigger picture.
- OCR misreads pixel fonts ("ialo" for "into" in Lure); the boxes are still right.
- `changed 0%` after a click can mean it missed: check with a key you know works
  (ScummVM's Ctrl-F5 opens its menu) before blaming the game. A small change says
  where it was (`changed <1% at 312,240 180x24`): on a menu that's the highlight
  moving. A screen slow to redraw can still read 0% at the default `--wait`
  (Tyrian's submenu took over a second): try `--wait 1.5` before deciding
  nothing happened.

**Rules of thumb:**

- **Look yourself when** being wrong would send you down a path, or when you're
  deciding what to do next on a screen you haven't seen.
- **Use a light tool when** you know what you expect and only need to confirm it.
- **A local model's answer is a hint, not a fact,** unless it says it's confident
  and a second signal (OCR, the outcome, the log) agrees.
- **Crop rather than shrink to read small text.** A shrunken screen loses the text.
  The vision docs advise against cropping out context just to enlarge text, so crop
  to the area, not the word.
- **Under about 200 px**, the vision docs warn of hallucinations. Send small game
  frames at 2x.

## Measuring it

Each porting log notes:

- the pictures read, and roughly their sizes;
- what the light tools answered instead;
- where a light answer misled you, and what looking would have saved.

That's how this file's advice, and the tools, improve.
