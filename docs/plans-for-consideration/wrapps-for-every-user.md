# Wrapps any user on the Mac can play

Proposed 2026-11-05. **Not planned yet:** build it when someone wants a second
person on the same Mac to play a game the first one built, or installed in
`/Applications` for everyone. Two people playing it at the same moment needn't work:
one at a time is enough.

It builds on what a wrapp keeps per person today. That is the saves and Second
Chance's settings in `~/Library/Application Support/<bundle id>/`
([wrapp-launch.md](../wrapp-launch.md#user-files)), and the bundle's volumes,
recorded in its `WrappLock.json`.

## Why

A Wine wrapp keeps its Wine prefix inside its own bundle,
`Contents/SharedSupport/prefix`. Run by any user but the one who built it, it fails
before the game starts. The launch log says
`wine: '…/Contents/SharedSupport/prefix' is not owned by you`. The wrapp reports
that the game quit unexpectedly.

**That's Wine's own rule, not ours.** `setup_config_dir` (wine-10.0,
`dlls/ntdll/unix/server.c`) refuses a prefix directory whose owner isn't the user
running Wine:

```c
if (st.st_uid != getuid()) fatal_error( "'%s' is not owned by you\n", config_dir );
```

The prefix is also where Wine writes as the game runs: the registry, and files under
`drive_c`. A second user usually couldn't write there anyway. An app in
`/Applications` belongs to whoever installed it.

Seen 2026-11-05, running a SkiFree wrapp as a second user on the test Mac.
ScummVM and DOSBox wrapps don't write into their bundle, as their settings and saves
are already per person, so they're probably fine. To be checked when this is built.

## What it would do

**A prefix per user, made from the bundle's on first launch.** When the bundle's
prefix isn't owned by the person launching it, the wrapp:

1. Clones it to `~/Library/Application Support/<bundle id>/prefix/`. On APFS a clone
   (`clonefile`, or a `cp -c` per file) costs no space until a file changes, so a
   2 GB game's prefix is free until it writes.
2. Starts Wine with `WINEPREFIX` there. Everything after that is as now:
   - the volumes' links into it are made fresh, as at every launch;
   - the wine module's start-up steps run against it.
3. Re-clones it when the bundle's prefix is newer: an update (`UpdateWrappBuilder`)
   or a rebuild changed it. The volumes keep the person's saves through that, as
   they do across updates now.

The owner keeps using the bundle's own prefix, so nothing changes for the common
case of one person.

**One at a time.** A lock beside the bundle, which `WrappLock` could hold, says who
is playing. A second person's launch then says plainly that someone else on this
Mac is playing it. Wine's server, socket and per-user `/tmp/.wine-<uid>` are per
user already, so two at once might work too. It isn't promised, because two
prefixes would race over the same game files only if the game writes to its own
folder, and some do.

## What to decide when building it

- **Where a person's prefix lives:**
  - Application Support is backed up and synced by some people's tools, and
    clones are free only on APFS and on the same volume as the bundle;
  - `~/Library/Caches/` is not backed up, but a cleaner may empty it, which would
    cost only a re-clone.
- **Settings that live in the prefix and should follow the person:** the volumes
  already carry saves. A game that keeps settings in its registry would start
  fresh for each person, which is probably right.
- **Files the person can't read.** A bundle copied in by another user with
  restrictive permissions: the launch should say so plainly rather than fail in
  Wine.
- **Testing it:** the test Mac has a second user for running games in the
  background (the puppet toolkit's experiments), which suits a multi-user test.
