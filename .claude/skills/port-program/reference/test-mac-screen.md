# Keeping a screen you hold clean

A screen you hold is a claimed test account's, or a console screen you agreed and
leased (AGENTS.md, "Where to run what takes the screen"). A test account's screen
is its own, so prompts there disturb nobody else, but they still break your
captures and input.

**What clutters it, and what that breaks.** A port's checks and the integration
tests capture the screen and send input to the program, so anything else on it
gets in the way:

- **macOS notifications.** For example "App Background Activity: Software from
  'OpenClaw Foundation' can run in the background", which appears when a login item
  is added and stays up, even over a fullscreen game.
- **Permission prompts.** "… would like to access the Microphone", "… find devices
  on local networks".
- **Verifying panels.** "Verifying 'wine-prefix'…" is Gatekeeper's first-run check.
- **Windows left open.** System Settings after a grant, Activity Monitor, a
  Terminal.

They take the focus, so input meant for the game goes astray. They cover the game,
so a click or OCR hits them instead. And they end up in pictures: noise for the
agent, and a tainted needle or recording for a test.

**What the user allows** (2026-11-05): while you hold the screen (your lease, or a
run you started), you may:

- dismiss or answer notifications, alerts and prompts;
- hide, minimise or move windows that are in the way;
- change settings for as long as you're working (Do Not Disturb, an app's
  notifications, the Dock's auto-hide);
- quit an app you started yourself.

Two conditions:

1. **Put every change back when you finish.** Note each one in the porting log
   ("Screen changes") as you make it, so it gets undone even if the session ends
   early.
2. **Leave everything alone during someone else's lease.** Message them instead:
   they may be relying on the state you'd change.

**Answering permission prompts:**

- **Don't Allow,** unless what you're doing needs it. That's what an app bundle
  gets anyway: "sc" wanting the microphone, a test wrapp wanting the local network.
- **Allow,** when the task needs it, such as a tool you're setting up. Say so in
  the log.
- **Ask the user first** before granting a privacy permission (Screen Recording,
  Accessibility, Full Disk Access) in System Settings.

## Finding what's in the way

Without a lease (it's only looking):

- **A screenshot:** `./sc session screenshot [<user>] --on <host> --out <png>`, through
  that account's Peekaboo, which needs its Screen Recording grant: `sc session setup
  --task peekaboo <user> --on <host>` gives it, the person flipping the switch, once per
  account. Shrink it before reading (`sips -Z 1200`). A program's own windows need no
  grant: `sc puppet`'s captures see them.
- **Every window, with its owner and layer.** `peekaboo window list --json` through
  the bridge host, in an account where Peekaboo.app runs and is granted (which one, on this
  setup: `.local/AGENTS.md`):

  ```sh
  ssh <host> 'PEEKABOO_BRIDGE_SOCKET="$HOME/Library/Application Support/Peekaboo/bridge.sock" peekaboo window list --json'
  ```

  Windows of `NotificationCenter`, `UserNotificationCenter`, `SecurityAgent` and
  `CoreServicesUIAgent` (the Gatekeeper panels) are the usual intruders.
- **System alerts and permission prompts:** `peekaboo dialog list`. It's
  background and read-only, and finds alerts owned by `UserNotificationCenter` and
  `SecurityAgent`.

## Clearing it

These need the screen to be yours.

- **System alerts and permission prompts:**
  `peekaboo dialog click --button "Don't Allow"` (or the button you mean). It
  presses through Accessibility in the background, never taking the focus, and
  checks the alert went.
- **Notification banners:** their close button, through Peekaboo, with
  `see --app NotificationCenter --json`, then `click --on <elem>` on the
  "Close" or "Clear" element. *Not yet verified, 2026-11-05: verify on the next
  clean screen, and correct this line.* The fallback is Do Not Disturb (below),
  which stops new ones.
- **Do Not Disturb while you work.** It stops new banners covering the game.
  - **Ways to switch it on:** Control Center's Focus menu, driven with Peekaboo
    (`menubar`); or a Shortcuts shortcut run with `shortcuts run "<name>"`, if the
    user makes one.
  - **Note in the log whether it was on before,** and put it back.
  - *Not yet verified: write down the exact command that works on the test Mac's macOS 26
    when it's first done.*
- **An app's notifications.** In System Settings → Notifications, switch an app
  that keeps interrupting (a login item's "background activity" notice, say) to
  "None". Note it, and switch it back.
- **Windows in the way.** Hide the app (`peekaboo app hide --app <name>`), or
  minimise the window. Don't quit the user's apps; hide them.
- **The Dock and the menu bar.** Over a fullscreen game they're hidden already.
  For a windowed one, captures from the in-process helper are of the game window
  alone, so they don't matter there.

## Checking it's clean, and putting it back

- **Before a capture that matters** (a needle, a reference shot, a recording), look
  once: `window list` shows only the program and the expected system windows.
- **When you finish:**
  - undo every change in the log's "Screen changes", in reverse;
  - check with a screenshot that the screen is as you found it, apart from what you
    were asked to leave;
  - release the lease.
