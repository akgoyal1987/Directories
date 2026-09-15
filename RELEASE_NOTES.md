# v0.4.0

Context menus filled out to match Explorer, Recycle Bin actions, and a
permanent delete that asks first.

## Recycle Bin actions

- **Empty Recycle Bin**, from the bin's own background menu or from any row in
  it. It says how many items will go and defaults to Cancel.
- **Delete Permanently** on a selection inside the bin. Inside the bin the items
  are already deleted, so there is nowhere left to move them to and the only
  delete that means anything is the permanent one.

## Compress to ZIP

On any selection, as Explorer's "Compress to ZIP file" does. One item goes
through `ditto`, which keeps symlinks, resource forks and the code signature --
a zipped `.app` made any other way often will not launch. Several items go
through `zip`. The archive never overwrites: a name already taken becomes
"x copy", the same rule every other transfer here follows, and Undo puts the new
archive in the Trash.

## Shift-Delete

Cmd Shift Delete deletes without going through the Trash, which is Windows'
Shift+Delete. Command is added because Delete alone is a text key on a Mac and
Cmd Delete is already Move to Trash. It always asks first: it is the one gesture
in the app that cannot be undone, and it sits one modifier away from the one
that can.

## Fuller menus

- **The tree** gains Get Info, Rename and Move to Trash, which Explorer's
  navigation pane has had all along.
- **The folder background** gains Undo Last File Operation.
- The bin's background menu drops New and Paste, which mean nothing there.

## A note on "no hard delete"

Earlier versions said there was no hard delete anywhere in the app, and that was
true. It is not any more: a Recycle Bin you cannot empty is half a bin. The
principle it was protecting is intact -- Delete still means Trash, Undo still
puts copies in the Trash rather than unlinking them, and nothing is ever
overwritten. Permanent deletion now exists in exactly two places, both asking
first. The README says so rather than keeping a claim that had stopped being
true.

## Installing

`Directories-0.4.0-macos-arm64.zip`, macOS 14 or later, Apple silicon only.
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
