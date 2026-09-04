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

**Viewing**

- **List or icon grid**, switchable per view.
- **Eight optional columns** -- Size, Kind, Date Modified, Date Created, Date
  Added, Extension, Owner, Permissions. Right-click the header to choose which
  ones show; drag to resize. The layout persists.
- **Sort by any visible column**, ascending or descending, Cmd 1 through Cmd 9.
- **Live filter** as you type, and Cmd Shift `.` for hidden files.

**Files**

- Cut, Copy, Paste, Duplicate, Rename, New Folder, Move to Trash.
- **Undo Last File Operation** (Cmd Z), one level.
- Drag and drop, within the app and to and from the Finder.
- Quick Look on Space, Get Info on Cmd I, Open With using the system's own
  association list, Open in Terminal, Copy Path and Copy Name.

## Every file operation is recoverable

This is the constraint the file code is written to, and it is worth stating
because it rules things out:

- **Nothing is ever overwritten.** A name collision becomes "x copy". There is
  no "Replace?" dialog because there is no path that replaces anything.
- **Long transfers do not block the app** and can be cancelled. Copies and
  moves run off the main thread behind a progress sheet.
- **Undo does not unlink.** It puts things back by moving the new copies to the
  Trash, so a mistaken undo is itself recoverable.
- **Delete means Trash.** There is no hard delete anywhere in the app.

## Build

Requires the Xcode command line tools (`xcode-select --install`) and macOS 14
or later.

```bash
./build.sh --install
```

`--install` places the bundle in `/Applications`. Without it, the bundle is left
in `build/`. There is no Xcode project and no package manager -- `build.sh`
generates the icon, compiles the single source file, writes the `Info.plist` and
signs the bundle.

## Permissions

None to run. macOS will prompt the first time the app reads a protected
location -- Desktop, Documents, Downloads, or an external volume -- which is the
normal per-folder consent every app gets, not a global grant.

## Not there yet

- **Keyboard navigation is thin.** Arrow keys do not move the selection through
  the list, and there is no type-to-select. This is the biggest gap.
- **No shift-click range selection.**
- **No recursive search.** Filtering matches the current folder only; a
  Spotlight-backed search across a subtree is not wired up.

## Licence

MIT, as with the rest of this repository.
