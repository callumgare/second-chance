# A way back to the Mac a command was typed on

Proposed 2026-11-06. **Not planned yet: build it when a second remote run
needs something from the Mac it was typed on in the middle of the run** (the
first case below is enough for the outbox alone). Nothing today is blocked
without it: each case below has a workaround. But each workaround is a
special case of its own, and they add up.

It builds on `--on` as it is now ([dev-cli.md](../dev-cli.md#gui-session-and-remote-macs)):
the runtime copy synced to the other Mac, one `ssh` running `./sc` there with
`SC_LEASE_HOLDER` (and `SC_AGENT_SESSIONS`) on its command line, the re-run in
the GUI session as a LaunchAgent that outlives the connection, and
`sc attach`, which follows that run again. If `--on` changes before this is
taken up, this plan changes with it.

## Why

A command run with `--on <host>` can't reach back to the Mac it was typed on,
the _origin_. What it needs from there is sent before it starts, and what it
makes stays where it ran. Several things work around that today:

- **Pictures and recordings from `sc puppet`.** `shot`, `sheet`, `record`
  and needle cutting save on the test Mac and print an `scp` line
  (`PuppetShotCommand.fetchLine`), so every picture an agent looks at costs it
  a second command.
- **A run's results.** The step logs in `DerivedData/sc-logs/`, test reports
  and the diagnostics bundles a bad launch leaves stay on the test Mac, where
  nobody looks for them.
- **Work that needs a window where the person is.** `session setup` is split:
  the screensaver and signing steps can run on the test Mac, but Peekaboo's
  and the audio device's need a window on the origin. So the origin's `sc`
  runs those itself, once the remote part has finished, after reading which
  users `session add` made from the test Mac's `just-added` file
  (`Remote.followUp`, `Remote.runsHere`, `SessionSetupCommand.addedLast`).
  Anything like that is possible only before or after a remote command, never
  during one, and each needs its own hand-off file.
- **Guessing what to send.** `--on` decides from the command's arguments
  which local files (`Remote.localPaths`) and which installers
  (`Remote.readsInstallers`) to send up front. A wrong guess fails the run,
  and a cautious one sends what isn't needed.
- **Facts only the origin knows.** Agent sessions' names and titles are read
  from the origin's Claude Code files, so `--on` sends a snapshot of every
  running session with each command (`AgentSessionInfo.snapshot`), in case a
  lease needs naming.

These are two kinds of need. Files a run made only need to reach the origin
in the end. Questions, actions and on-demand fetches need an answer while
the run waits.

## Part 1: the outbox (files back)

A remote run writes what's meant for the origin into an outbox in the run's
checkout (`<checkout>/.sc-outbox/<run id>/`), keeping the folder layout it
should have on the origin (`puppet/<name>/shots/…`, `sc-logs/…`). When the
`ssh` ends, and when `sc attach` follows a run, the origin's `sc` pulls the
outbox back with `rsync --remove-source-files` into the same places in its
own checkout, and says where each item landed.

- A dropped connection only delays delivery: the next `attach`, or the next
  `--on` command to that checkout, pulls what's waiting.
- `fetchLine`'s `scp` hint goes. Output gives the path the file will have on
  the origin, marked as pending until the pull.
- A command whose output an agent looks at at once (`puppet shot`) needs the
  file within the same command. That's either the pull at its end, or Part 2's
  `deliver` while it runs.
- Nothing listens and nothing new is opened: it's the rsync `--on` already
  depends on, in the other direction.

## Part 2: the live channel (while it runs)

### Transport

The origin's `sc` listens on a Unix socket in a private temp folder (mode
0700) for as long as the command runs, and `ssh` forwards it to the test
Mac:

```sh
ssh -R /tmp/sc-origin-<random>.sock:<local socket> -o StreamLocalBindUnlink=yes \
    -o ExitOnForwardFailure=no <host> …
```

The remote command gets `SC_ORIGIN_SOCKET=/tmp/sc-origin-<random>.sock`.
OpenSSH has forwarded Unix sockets since 6.7, as long as the test Mac's
`sshd` allows it (`AllowStreamLocalForwarding`, on by default). A forward
that fails leaves the variable unset, and the run carries on as it does
today.

The GUI-session re-run inherits the variable as it does `SC_LEASE_HOLDER`.
It's the same user, so it can open the socket.

### Protocol

One JSON object per line each way, a request id echoed in the reply, as
`sc puppet`'s control socket already does. Only a fixed set of requests
exists, each answered by the origin's `sc` in Swift. Nothing is ever run as a
shell command:

| Request                        | Answer                                                                                                                       |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `agentSession {id}`            | The session's name and title now (replaces the always-sent snapshot)                                                         |
| `fetch {path}`                 | A file from the origin's checkout or installers store, streamed (replaces the guessing in `localPaths` and `readsInstallers`) |
| `deliver {kind, name, bytes}`  | Writes into the outbox's place on the origin now, rather than at the pull                                                    |
| `run {step}`                   | Runs one of a fixed set of origin-side steps (`session setup`'s Peekaboo and audio steps, opening Screen Sharing)             |
| `ask {question, choices}`      | Asks the person at the origin's terminal and waits for the answer                                                            |
| `notify {text}`                | A line on the origin's terminal, or a notification when the run is followed by `attach`                                      |

### What it may touch

Anything running as the test user on the test Mac can open that socket while
the command runs, so the origin trusts it no further than the test Mac:

- `fetch` reads only below the checkout and the installers store, with paths
  resolved and checked after symlinks (`HostPaths`' rule for `allow-paths`).
- `deliver` writes only into the outbox's places in the origin's checkout,
  under names it picks, never a path it's given.
- `run` takes a step's name from the fixed list, never a command line.
- No request reads the origin's environment, keychain or Claude Code token.
  `agentSession` returns names and titles only, as the snapshot does.

### When it's gone

The channel lasts only as long as the `ssh`. A run that outlives a dropped
connection, or one followed by `attach` from another terminal, finds it
closed. So every request needs a fallback:

- `agentSession` → the name and title the lease recorded.
- `fetch` → fails the step with a hint to run it again, as a missing file does
  today.
- `deliver` → the outbox, pulled at the next `attach`.
- `run` and `ask` → wait for an `attach`, which opens a new channel (the
  origin of the `attach` becomes the origin), and say so in the run's output.
- `notify` → the run's output only.

Each request also has a timeout (a second for lookups, longer for transfers),
so a stalled origin never wedges a run.

## What it would replace

- `fetchLine` and its `scp` hints (Part 1).
- `Remote.followUp`, `Remote.runsHere` and the `just-added` hand-off, once
  `session setup`'s origin-side steps are `run` requests (Part 2).
- `SC_AGENT_SESSIONS` and `AgentSessionInfo.snapshot` (Part 2's
  `agentSession`). Not before: the snapshot takes a few milliseconds and needs
  no connection.
- Some of the up-front sync guessing, though not all of it: a build still
  wants its inputs sent before it starts, and `fetch` suits only the
  occasional file.

## Rough phases

1. The outbox and the pull-back, with `puppet`'s pictures and `sc-logs` as
   the first users. This is worth doing on its own.
2. The socket, the forward, `agentSession` and `notify`, which have the
   simplest fallbacks.
3. `run`, and `session setup` moved onto it. That's where the special cases
   go.
4. `fetch`, `deliver` and `ask`, as they're needed.

## Open questions

- Should `attach` take over the channel when the original `ssh` is still
  alive, or open a second one? Two origins answering one run would need an
  order.
- Nested `--on` (a run on one Mac that itself runs `--on` another) should
  probably pass the outermost origin through rather than chain. Is there a
  case for chaining?
- The re-run in the GUI session is started by `launchctl`: does the forwarded
  socket's path stay valid there across macOS versions? A quick test settles
  it.
