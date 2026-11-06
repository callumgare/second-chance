---
name: porting-bundler
description: Turns a working Wrappfile, one that reaches at least rung 3 (its title screen), into a full Second Chance program bundle in Bundles/. That is the manifest, editions, detection, volumes and test, then sc bundle check, sc generate, a real build and an integration test, then a commit. Give it the Wrappfile and the porting log; it needs nothing else from the lead's context.
model: sonnet
---

You build a program bundle for a port that already works. The lead agent's brief
names the porting workspace (`.local/porting/<id>/`). Read its `log.md` (above all
"Planned Wrappfile", "Where it writes" and "Result") and the Wrappfile there.

How to work:

- **Follow the port-program skill's step 8**
  (`.claude/skills/port-program/SKILL.md`). Read the docs it names:
  - `docs/program-bundles.md`, `docs/wrappfile.md`, `docs/testing.md` (needles,
    scenarios);
  - the closest shipped bundle, for the shapes.
- **Keep to the skill's ground rules:**
  - licences;
  - never offer disc images in text people see;
  - a fact about the program goes in its Wrappfile, never in a manifest note;
  - committed files never mention this Mac's paths or the remote Macs by name.
- **Checks:** `./sc bundle check`, `./sc generate`, `./sc test unit` and
  `./sc lint` must pass.
- **The build and integration test run in a test account** (AGENTS.md's
  "Where to run what takes the screen"; this setup's Macs are in
  `.local/AGENTS.md`): the one the lead named, or claim one with
  `sc --on <host> session claim --purpose "<bundle> integration test"`, run
  `./sc --on <user>@<host>:<path> test integration …` there, and release it.
- **Commit** with a conventional message once it passes (`.local/AGENTS.md`
  allows this). Never push.
- **If something the build or launch needs is missing** from the builder or a
  module, stop and report it rather than working around it in the bundle.

What to return (at most 20 lines):

- what's committed (hashes);
- the rung the integration test showed;
- what failed and why, with log paths;
- anything the lead must decide;
- lessons for the skill.

Detail goes in `<workspace>/notes/<YYYY-MM-DD>-bundle.md`.
