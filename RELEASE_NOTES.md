# v0.2.1

A folder menu, files you can create, a listing that keeps up with the disk, and
the folders macOS manages are no longer yours to rename.

**v0.2.0 is withdrawn: its binary only ran on the macOS version that built it.**
`swiftc` was invoked without `-target`, so it took the deployment target from
the build machine and stamped the binary minos 26.0 while the Info.plist claimed
14.0. Launch Services believed the plist and started it; dyld then refused it on
every Mac older than macOS 26. The build now pins the target, and the two agree.
No other code changed between 0.2.0 and 0.2.1.

## New

- **A folder menu on empty space.** Right-click anywhere that is not a row and
  you get Explorer's background menu: New, Paste, Select All, Open in Terminal,
  Show in Finder, Copy Path, Sort By, View As, Columns, Show Hidden Files and
  Refresh. An empty folder was unusable before this, since there was no row to
  aim at.
- **New files, not only new folders.** Text, Markdown, shell script (created
  executable), JSON and CSV, from the folder menu, the tree's own menu and the
  File menu. A new item arrives selected with its name ready to type.
- **The listing notices changes it did not make.** A download landing, a
  `git checkout`, a file written by another app: both panes update on their own,
  with no navigating away and back and no collapsing a tree node to force it.
  One FSEvents stream covers the folders on screen, filtered to those exact
  paths and coalesced, so a folder receiving five hundred files causes one
  reload rather than five hundred. A reload arriving while a rename field is
  open, or during a copy, is deferred and replayed rather than dropped, and the
  selection survives it. Cmd R forces one.
- **Shift-click range selection.** The range measures from the last row clicked
  without Shift, so shift-clicking a nearer row shrinks it rather than growing
  it a row at a time; Cmd with Shift adds a second run. It runs over the rows on
  screen, so it follows the current sort and filter.
- **Click the name of a selected item to rename it**, as Explorer and the Finder
  do. The gesture is on the name itself, so the icon and the rest of the row
  still only select.
- **Open in Terminal uses the terminal you have** -- iTerm2, Ghostty, Warp,
  kitty, WezTerm, Alacritty, Hyper, then Terminal.app. Pin one with
  `defaults write com.ankitgoyal.directories terminalBundleID <bundle id>`.

## Fixed

- **Escape did nothing during a rename.** AppKit's field editor treats Escape as
  its own cancel and consumed the event before the handler ever saw it.
- **The row menu acted on one item however many were selected.** Every entry
  reset the selection to the row under the cursor first, so Move to Trash on
  five selected files trashed one and left the other four looking as though they
  had gone. Quick Look and Rename did the same silently. The menu now follows
  the selection and says what it will touch -- "Copy 3 Items", "Move 3 Items to
  Trash" -- and anything that shows exactly one thing, or applies only to
  folders, appears only when it fits what is selected.
- **Open on several folders opened only the last one.** Opening a folder
  navigates the current tab, so two selected folders navigated the one tab
  twice. Each folder now gets a tab of its own.
- **Command-click missed at random.** Modifier keys were sampled when the
  gesture fired rather than read from the mouse-down event, and SwiftUI holds a
  single tap back for a quarter of a second while it waits to see whether a
  second click follows -- long enough to have let go of the key.

## Behaviour change worth knowing about

**Desktop, Documents, Downloads, Library and the other folders macOS manages can
no longer be renamed, moved or trashed**, along with volume roots, items locked
in Get Info, and anything whose enclosing folder is read-only. Rename, Cut and
Move to Trash are disabled for them and say why in the label and the tooltip.
Their contents stay fully editable; the protection is the folder itself.

Renaming them never risked the operating system, which lives on a sealed volume.
It broke the machine for its owner: applications ask the system for the standard
folder, get a path that no longer exists, and macOS quietly recreates an empty
one, so the files sit safely in the renamed folder while everything saves into
the new empty one.

The protected set is asked of macOS rather than hardcoded, which is the only way
to get it right. Those folders carry no immutable flag, no Finder name-locked
bit and no read-only permission -- measured, they are indistinguishable from an
ordinary folder by every URL resource key there is. What identifies them is the
standard-directory list itself, and deriving it also keeps the app correct in
languages where the name on screen is not the name on disk.

## Still not there

Keyboard navigation through the list, and recursive search. There are no
automated tests.

## Installing

`Directories-0.2.1-macos-arm64.zip`. Unzip and drag `Directories.app` to
`/Applications`.

- **macOS 14 Sonoma or later.** macOS 13 and earlier refuse to load the binary;
  dyld stops it before any of the app's own code runs.
- **Apple silicon.** The released binary is arm64 only. An Intel Mac cannot run
  it, and Rosetta does not help -- it translates Intel code to run on Apple
  silicon, not the other way round. Building from source on an Intel Mac works.

Tested on macOS 26. The 14.0 floor is what the binary declares rather than
something exercised on a 14.0 machine.

The binary is **ad-hoc signed and not notarised** -- there is no certificate in
it at all -- so Gatekeeper blocks the first launch with "cannot be opened
because the developer cannot be verified", or occasionally with "is damaged and
can't be opened", which is the same rejection wearing a worse label.

**macOS 15 and later no longer accept the old right-click-and-Open bypass.**
Open the app once, let it be blocked, then allow it in System Settings >
Privacy & Security > Open Anyway. Or clear the quarantine flag from a terminal,
which works on every version:

```bash
xattr -dr com.apple.quarantine /Applications/Directories.app
```

Nothing short of a paid Apple Developer ID and notarisation removes this. A
self-signed certificate does not help: Gatekeeper trusts it no more than an
ad-hoc signature.

Notarising needs a paid Apple Developer account, which this project does not
have. Building from source avoids it entirely and takes about ten seconds.

Verify the download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Licence

MIT.
