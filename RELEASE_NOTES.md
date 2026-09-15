# v0.3.0

A Recycle Bin in the sidebar, and a fix for a list that could hide every
filename.

## Recycle Bin

`~/.Trash` now appears at the bottom of Locations, as the Recycle Bin does in
Explorer. It is the real Trash, so what shows here is what the Finder shows.

Browsing only: there is deliberately no Empty Trash. Every delete in this app
moves to the Trash precisely so it can be undone, and an Empty command would be
the one place that destroys something for good. The Finder already has it for
anyone who wants it.

macOS guards `~/.Trash` behind Full Disk Access and, unlike Desktop or
Documents, never prompts for it -- the read simply returns nothing. So until
that is granted the folder would read as empty, which is indistinguishable from
an empty bin. The app now tells you which it is, and offers a button straight to
the right settings pane.

## Fixed

- **The list could show no filenames at all.** The name column is the only
  flexible one, so when the chosen columns were together wider than the window,
  SwiftUI took the whole difference out of that one view and squeezed it to
  nothing: a list of icons, sizes, kinds and dates with every name blank, header
  included. It depended on window width, which is why it came and went. The name
  now has a floor and the columns to its right run off the edge instead --
  Explorer's trade, and the right one, because the name is the thing you are
  reading.

## Installing

`Directories-0.3.0-macos-arm64.zip`, macOS 14 or later, Apple silicon only.
Unzip and drag `Directories.app` to `/Applications`.

The binary is **ad-hoc signed and not notarised**, so Gatekeeper refuses the
first launch with "cannot be opened because the developer cannot be verified".
Either right-click the app and choose Open, or clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Directories.app
```

Verify the download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Licence

MIT.
