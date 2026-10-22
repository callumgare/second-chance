# Updates

Second Chance checks for new releases and offers to install them through
[Sparkle](https://sparkle-project.org). Wrapps don't update: each is a finished
game, and a newer Second Chance only changes the wrapps it builds from then on.

## In the app

`AppUpdater` (`SecondChance/Services/AppUpdater.swift`) starts Sparkle's
standard updater at launch and puts **Check for Updates…** in the app menu.
Sparkle checks once a day without asking first (`SUEnableAutomaticChecks`).
When it finds a newer build it shows the release notes and offers to install
it, skip it or remind later. Installing replaces the app and relaunches it.

The updater is off in Debug builds, in headless runs (`NON_INTERACTIVE`) and
inside the test host. A Debug build would otherwise offer to replace itself with
the latest release. `SECOND_CHANCE_UPDATES=1` turns it on anyway and `0` turns
it off. Use the first to try the update flow from a build made with
`sc release --build-only`.

Sparkle compares `CFBundleVersion`, which `sc release` sets to the commit count
([releasing.md](releasing.md)), so every release is newer than the last.

Sparkle takes the quarantine attribute off the update it installs. An update
therefore doesn't need approving in Privacy & Security the way a downloaded
copy does.

## The feed

`SecondChance/Info.plist` holds Sparkle's settings. The rest of the app's
Info.plist is generated from `INFOPLIST_KEY_` build settings, which can't carry
Sparkle's keys. The file is excluded from the target's synchronized folder,
since it isn't a resource.

- **`SUFeedURL`** is
  `https://github.com/callumgare/second-chance/releases/latest/download/appcast.xml`.
  GitHub redirects it to the `appcast.xml` attached to the newest release that
  isn't a draft or prerelease, so the feed is always the latest release's.
- **`SUPublicEDKey`** is the public half of the EdDSA key that updates are
  signed with. Sparkle refuses an update whose signature doesn't match it.

`sc release` writes `build/release/appcast.xml` after packaging and attaches it
to the GitHub release with the zip. It runs Sparkle's `generate_appcast`, which
signs the zip with the private key from the login keychain and embeds the
release notes as Markdown. Each appcast lists only its own release, which is
all an installed copy needs. Sparkle's tools come with the package, in
`DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`.

Before it signs, `sc release` checks that the keychain's key is the one in the
built app's Info.plist. If it isn't, the release stops. A release signed with
another key would publish fine, and then every installed copy would refuse it.

## The signing key

The private key lives only in the login keychain of the Mac that releases.
**Losing it means installed copies can't be updated.** They would have to be
replaced by hand with a build that carries a new public key. Keep an exported
copy somewhere safe.

```fish
set bin DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
$bin/generate_keys            # create the key (once ever), print the public half
$bin/generate_keys -p         # print the public half of the key in the keychain
$bin/generate_keys -x key.txt # export the private key, to back it up
$bin/generate_keys -f key.txt # import it on another Mac that will release
```

Put the public half in `SUPublicEDKey`. Change it only together with a plan
for the copies already installed, since they keep trusting the old key.

### Why the key can't live in iCloud Keychain

Sparkle's tools only look in the file-based login keychain. They save and
look up the key as a plain generic password, never as a synced item, so a
key moved into iCloud Keychain is invisible to them. Keychain Access can show
the iCloud keychain because it is an Apple app with the entitlement for it.
The `security` CLI has no such access and only lists file-based keychains.

A tool of our own could only read a synced item if it were a signed app with
a provisioning profile, and the item would have to be one that tool created.
Keychain Access and Passwords save items under Apple's access groups. Running
that tool would also take a Development profile for each releasing Mac. That
is far more to maintain than importing the key once on each Mac, so the
login keychain stays where the key is read from.

### Backing it up through iCloud

The exported key is one line of base64, so it fits in an ordinary password
entry in Passwords, which syncs through iCloud Keychain. Export it straight
to the clipboard (fish, from the repo root):

```fish
# A directory, not `mktemp`'s file: -x won't write over an existing file.
set dir (mktemp -d)
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x $dir/key
pbcopy < $dir/key; rm -r $dir
```

In Passwords, add a new password: a label such as
`Sparkle signing key — Second Chance`, the key pasted as the password, and
the public half (`SUPublicEDKey`) in its notes so the entry can be checked.
Then clear the clipboard with `echo -n | pbcopy`.

To release from another Mac, build once so the tools exist, copy the password
from the entry and import it:

```fish
set key (mktemp)
pbpaste > $key
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f $key
rm $key; echo -n | pbcopy
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p  # must match SUPublicEDKey
```

## Moving to Applications

When macOS runs Second Chance translocated, the app offers to move itself
into Applications (`AppMover`, called from `applicationDidFinishLaunching`,
never in a headless run or under test). Translocation happens to a
downloaded app that is opened where it was unpacked instead of being moved
by Finder first. macOS runs a hidden read-only copy of it from a new random
path each time, and Sparkle can't install updates there.

`AppMover` asks Security.framework where the original is, then moves it to
`/Applications`, or to `~/Applications` when `/Applications` can't be
written to. It goes in under the app's own name, so a `Second Chance 2.app`
from a second download replaces the older copy, which goes to the Bin. Then
`AppMover` takes the quarantine attribute off the bundle and reopens it from
there. Gatekeeper has already passed this copy, since it is running, so
taking the quarantine off grants nothing new. Without the quarantine, macOS
runs the app where it is from then on. An original that can't be moved, for
example on a disk image, is copied instead. "Not Now" leaves the app as it
is, and the question comes back at the next start.
