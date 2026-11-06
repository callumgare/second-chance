# Working with subagents

A port has a lead agent: the session the user asked. It owns the porting log, the
decisions, the conversation with the user, and which test account each subagent uses. Work
that is self-contained, and can be handed over with a brief and the porting log,
goes to a subagent. That spends fewer of the lead's tokens, keeps the pictures and
long logs out of the lead's context, and lets research run while the lead works.

## The four types

Their definitions are in `.claude/agents/` (a new or changed one is picked up by the next session).

| Type | Model | Give it | Typical jobs |
| --- | --- | --- | --- |
| `porting-researcher` | Sonnet | A question | Step 3's lookups; a walkthrough or manual for a scene; reference screenshots; reading an engine's source for one call |
| `porting-player` | Lead's (Opus) | A goal, how to start the program | Play to a scene; check clicks, video, sound, saves; find where it saves. Picture-heavy, so the pictures stay with it |
| `porting-debugger` | Lead's (Opus) | A symptom, how to reproduce it | One failure's cause, from traces, engine source and experiments |
| `porting-bundler` | Sonnet | The workspace (a Wrappfile at rung 3 or better) | Step 8, the whole program bundle through to a committed, tested bundle |

Sonnet for the jobs that follow written procedures (lookups, the bundle), which spends
less of the subscription; the lead's model where judgement and vision matter most. If a
Sonnet agent comes back unsure or wrong, rerun the job with `model: opus`, and note it
here.

## When to delegate, and when not

- **Delegate:**
  - anything that reads many pages, many log lines or many pictures to produce a
    short answer;
  - anything that follows the skill's procedure once the inputs are settled (the
    bundle);
  - independent lookups, run in parallel (CrossOver, PCGamingWiki and a
    walkthrough at once).
- **Don't delegate:**
  - a step of a few tool calls whose result you need now;
  - deciding between routes;
  - talking to the user;
  - editing the porting log, the skill or the Wrappfile. Subagents report; the
    lead writes, so there's one author and no conflicting edits.
- **Screens:** each screen-taking subagent (player, bundler's integration test,
  or a debugger's on-screen experiment) works in a test account of its own: the
  lead claims one per subagent and names it in the handoff, and the lease
  enforces it. With only one free, they take turns.

## The handoff

**The porting log is the contract.** Before handing over, the lead brings
`log.md` up to date: the planned Wrappfile, the attempts and the rung. The brief
then points at it rather than retelling it.

A brief:

```text
Goal: <one sentence>. Done when: <observable result>.
Workspace: .local/porting/<id>/ (read log.md: <sections>; files: <paths>).
Known / ruled out: <bullets, or "see log.md, Attempts 5–8">.
How to start it (player/debugger): <command or bundle id; the test account, `<user>@<host>`>.
Limits: <time, screen window agreed with peers, budget hints>.
Return: notes in <workspace>/notes/<date>-<topic>.md and a summary of at most 15–20 lines.
```

**Coming back:**

- The subagent's notes go in the workspace's `notes/`.
- The lead links them from `log.md` and records the result in a line or two.
- Lessons it reports go into the skill. The lead writes them.

## Patterns

- **Step 3, in parallel:** one researcher per source family (Mac ports; Wine
  reports; engines; manuals and walkthroughs), while the lead identifies the files.
- **Play tests:** "play from a new game to the first save point; save, quit,
  relaunch, load; report". The player returns rung 4 or 5 evidence, or where it
  stopped.
- **A stuck port:** the lead writes down the symptom and hands it to a debugger,
  and keeps working on the next program (or the bundle of another).
- **From working Wrappfile to bundle:** once rung 3 is reached and logged, a
  bundler takes it from there. The lead reviews its commit.
