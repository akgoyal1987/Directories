# v0.1.0

First public release.

A Windows-Explorer-style file navigator for macOS. Folder tree, tabs with
per-tab history, a breadcrumb address bar that turns into an editable path field
when you click into it, eight configurable resizable columns, list and icon
views, cut/copy/paste/duplicate with one level of undo, drag and drop, Quick
Look and Get Info.

Every file operation is recoverable: nothing is ever overwritten, a name
collision becomes "x copy", delete means Trash, and undo puts things back by
moving copies to the Trash rather than unlinking them.

Not there yet: keyboard navigation through the list, shift-click range select,
recursive search. There are no automated tests.

## Installing

`Directories-0.1.0-macos-arm64.zip`, macOS 14 or later, Apple silicon only.
Unzip and drag `Directories.app` to `/Applications`.

The binary is **ad-hoc signed and not notarised**, so Gatekeeper refuses the
first launch with "cannot be opened because the developer cannot be verified".
Either right-click the app and choose Open, or clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Directories.app
```

Notarising needs a paid Apple Developer account, which this project does not
have. Building from source avoids it entirely and takes about ten seconds.

Verify the download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Licence

MIT.
