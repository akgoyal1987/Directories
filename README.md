# Directories

A Windows-Explorer-style file navigator for macOS. SwiftUI and AppKit, one
`swiftc` invocation, no dependencies.

The Finder is column-and-icon shaped. Directories is tree-and-list shaped: a
folder tree pinned on the left that stays put as you navigate, a details list on
the right with the columns you choose, and tabs across the top. If you came from
Explorer and keep reaching for a pane that is not there, this is that pane.

## What it does

**Navigation**

- **Folder tree** on the left, expandable, loaded lazily as you open nodes so
  the filesystem is only read where you look.
- **Tabs**, each with its own history. Back and forward are per-tab, not global.
- **Breadcrumb address bar**, as in Explorer. Unfocused it is a row of path
  components: click one to go there, or click the chevron after it to pick a
  subfolder and step sideways without going up first. Click the empty space to
  its right -- or Go > Open Location (Cmd Shift G) -- and it becomes the path
  field with the path selected, ready to be replaced or copied. Return commits,
  `~` expands, Escape reverts, and clicking away puts the breadcrumbs back.
- **Go menu** for Home, Computer, Applications and Utilities, plus Enclosing
  Folder, Show Location in Finder and Copy Location.
- **Recycle Bin** in Locations, which is the real `~/.Trash`. Browsing only:
  there is deliberately no Empty Trash, because every delete in this app moves
  to the Trash so that it can be undone, and an Empty command would be the one
  place that destroys something for good. macOS guards `~/.Trash` behind Full
  Disk Access and never prompts for it, so until that is granted the folder
  reads as empty -- the app says so rather than showing you an empty bin.

**Viewing**

- **List or icon grid**, switchable per view.
- **Eight optional columns** -- Size, Kind, Date Modified, Date Created, Date
  Added, Extension, Owner, Permissions. Right-click the header to choose which
  ones show; drag to resize. The layout persists.
- **Sort by any visible column**, ascending or descending, Cmd 1 through Cmd 9.
- **Live filter** as you type, and Cmd Shift `.` for hidden files.

**Selecting**

- **Click** selects, **Cmd-click** toggles, **Shift-click** takes the range.
  The range measures from the last row clicked without Shift, so shift-clicking
  a nearer row shrinks it rather than growing it one row at a time. Cmd with
  Shift adds a second run to what is already selected.
- The range runs over what is **on screen**, so it follows the current sort and
  the current filter -- what you clicked between is what you get.
- **Click the name of a selected item to rename it**, as Explorer and the
  Finder do. The gesture is on the name itself, so the icon and the rest of the
  row only ever select and bringing the window forward cannot start a rename by
  accident. Return commits, Escape cancels.

**Files**

- Cut, Copy, Paste, Duplicate, Rename, Move to Trash.
- **Compress to ZIP**, on any selection. One item goes through `ditto`, so a
  zipped `.app` keeps its symlinks, resource forks and signature and still
  launches; several go through `zip`.
- **Recycle Bin actions**: Empty Recycle Bin, and Delete Permanently on a
  selection inside the bin, where there is nowhere left to move things to.
- **New Folder**, and **new files from templates** -- text, Markdown, shell
  script (created executable), JSON, CSV. A new item arrives selected with its
  name ready to type.
- **Right-click empty space for the folder menu**, Explorer's background menu:
  New, Paste, Select All, Open in Terminal, Show in Finder, Copy Path, Sort By,
  View As, Columns, Show Hidden Files and Refresh. It is what makes an empty
  folder usable, since there is no row to aim at.
- **The row menu follows the selection.** Right-clicking inside a selection
  acts on all of it and says so -- "Copy 3 Items", "Move 3 Items to Trash".
  Right-clicking outside one moves the selection to that row first. Anything
  that shows exactly one thing, or applies only to folders, appears only when
  it fits what is selected, so a mixed selection of files and folders is never
  offered a verb that would half apply. Open on several folders gives each one
  a tab of its own.
- **Undo Last File Operation** (Cmd Z), one level.
- Drag and drop, within the app and to and from the Finder.
- Quick Look on Space, Get Info on Cmd I, Open With using the system's own
  association list, Open in Terminal, Copy Path and Copy Name.

## It notices changes it did not make

A download landing, a `git checkout`, a file written by another app: both panes
update on their own. No navigating away and back, no collapsing and re-expanding
a tree node.

One FSEvents stream covers the folders on screen -- the active tab's folder and
every expanded node of the tree. Events are filtered to those exact paths on a
background queue and coalesced, so a folder receiving five hundred files causes
one reload rather than five hundred. A reload that arrives while a rename field
is open, or during a copy, is deferred and replayed rather than dropped, and the
selection survives it for everything still on disk. Cmd R forces one.

## Every file operation is recoverable

This is the constraint the file code is written to, and it is worth stating
because it rules things out:

- **Nothing is ever overwritten.** A name collision becomes "x copy". There is
  no "Replace?" dialog because there is no path that replaces anything.
- **Long transfers do not block the app** and can be cancelled. Copies and
  moves run off the main thread behind a progress sheet.
- **Undo does not unlink.** It puts things back by moving the new copies to the
  Trash, so a mistaken undo is itself recoverable.
- **Delete means Trash**, and that is what Delete does. Permanent deletion
  exists in exactly two places, both deliberate and both asking first: Empty
  Recycle Bin, and Shift-Delete (Cmd Shift Delete), which is Windows' own
  gesture for it. Nothing else in the app can destroy a file.
- **The folders macOS manages cannot be renamed, moved or trashed.** Desktop,
  Documents, Downloads, Library and the rest, plus volume roots, items locked
  in Get Info, and anything whose enclosing folder is read-only. Rename, Cut
  and Move to Trash are disabled for them and say why in the label and the
  tooltip -- "Rename (macOS needs this folder)". Their contents stay fully
  editable: the protection is the folder itself, never what is inside it.

  The set is asked of macOS rather than hardcoded, which is the only way to get
  it right. Those folders carry no immutable flag, no Finder name-locked bit
  and no read-only permission -- measured, they are indistinguishable from an
  ordinary folder by every URL resource key there is. What identifies them is
  the standard-directory list itself, and deriving it also keeps the app
  correct in languages where the name on screen is not the name on disk.

## Requirements

- **macOS 14 Sonoma or later.** The binary is built with a deployment target of
  14.0, so macOS 13 and earlier refuse to load it -- dyld stops it before any of
  the app's own code runs, whatever the Finder shows.
- **Apple silicon.** The released binary is arm64 only. An Intel Mac cannot run
  it and Rosetta does not help: Rosetta translates Intel code so it runs on
  Apple silicon, not the other way round. Building from source on an Intel Mac
  works -- `build.sh` targets whatever machine it is run on.

Tested on macOS 26. The 14.0 floor is what the binary declares rather than
something that has been exercised on a 14.0 machine, so if it misbehaves on an
older release, please open an issue.

## Download

Grab the zip from the [Releases](../../releases) page, unzip it, and drag the
`.app` to `/Applications`.

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
have. If you would rather not take a stranger's binary on trust -- a reasonable
position -- build from source instead. It takes about ten seconds.

Verify a download against `SHA256SUMS.txt` on the release:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Build

Requires the Xcode command line tools (`xcode-select --install`). Builds on
Apple silicon and on Intel, producing a binary for the machine it runs on.

```bash
./build.sh --install
```

`--install` places the bundle in `/Applications`. Without it, the bundle is left
in `build/`. There is no Xcode project and no package manager -- `build.sh`
generates the icon, compiles the single source file, writes the `Info.plist` and
signs the bundle.

## Configuration

Open in Terminal uses the terminal you actually have, checked in order: iTerm2,
Ghostty, Warp, kitty, WezTerm, Alacritty, Hyper, then Terminal.app. To pin one:

```bash
defaults write com.ankitgoyal.directories terminalBundleID com.googlecode.iterm2
```

Everything else -- sort, view mode, visible columns, column widths, hidden files
-- persists on its own.

## Permissions

None to run. macOS will prompt the first time the app reads a protected
location -- Desktop, Documents, Downloads, or an external volume -- which is the
normal per-folder consent every app gets, not a global grant.

## Not there yet

- **Keyboard navigation is thin.** Arrow keys do not move the selection through
  the list, and there is no type-to-select. This is the biggest gap.
- **No recursive search.** Filtering matches the current folder only; a
  Spotlight-backed search across a subtree is not wired up.

## Related

Two sibling projects, same idea and same constraints -- plain Swift, no
dependencies, one shell script to build:

- [PlusPad](https://github.com/akgoyal1987/PlusPad) -- a Notepad++-style
  text editor that never asks you to save
- [DockToggle](https://github.com/akgoyal1987/DockToggle) -- closing an app's
  last window quits it, so unpinned icons leave the Dock

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for
how the code is laid out and what to run before opening one.

## About

I am **Ankit Goyal**, a software engineer working on data platform and
distributed systems.

Directories started because I moved to a Mac and kept reaching for the Explorer
pane that was not there. It turned into an exercise in seeing how far plain
SwiftUI and AppKit go with no dependencies at all -- the answer was further than
I expected.

GitHub: [@akgoyal1987](https://github.com/akgoyal1987)

## Licence

MIT. See [LICENSE](LICENSE).
