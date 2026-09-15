# v0.4.1

The Recycle Bin's menus now offer only what applies to a bin.

Every context menu in the app was written for folders you work in, and the bin
is not one: it is a holding area for things on their way out. Opening, renaming,
cutting, duplicating, compressing, sharing, pasting into it, creating a new file
inside it, or moving it to the Trash are all nonsense there, and all of them
were being offered.

- **A row in the bin** now offers Quick Look, Get Info, Show in Finder, Copy
  Path, Delete Permanently, Empty Recycle Bin and Refresh. Windows offers
  Restore, Cut, Delete and Properties and nothing else.
- **The bin in the sidebar** offers Open in New Tab, Show in Finder, Empty
  Recycle Bin and Refresh. It no longer offers New, Paste Into Folder, Cut,
  Copy, Rename or Move to Trash.
- **The bin's background** keeps the view options -- sorting, columns, hidden
  files -- and drops Open in Terminal.

Restore, which Windows does have, is deliberately absent rather than guessed at:
putting a file back needs its original path, and macOS keeps that in a private
Finder database rather than on the file itself. Dragging an item out of the bin
works in the meantime.

## Installing

`Directories-0.4.1-macos-arm64.zip`, macOS 14 or later, Apple silicon only.
Unzip and drag `Directories.app` to `/Applications`.

Ad-hoc signed and not notarised, so Gatekeeper refuses the first launch. Either
right-click the app and choose Open, or clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Directories.app
```

Verify the download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Licence

MIT.
