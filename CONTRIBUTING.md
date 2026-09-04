# Contributing

Issues and pull requests are welcome. This is a small personal project, so the
process is light -- but there are a few things about how it is built that will
save you time.

## Getting set up

There is nothing to install beyond the Xcode command line tools:

```bash
xcode-select --install
git clone https://github.com/akgoyal1987/Directories.git
cd Directories && ./build.sh
```

No package manager, no Xcode project, no generated files. `build.sh` renders
the icon, runs `swiftc` once, writes the `Info.plist` and ad-hoc signs the
bundle into `build/`.
A build takes about ten seconds.

`build/` and `dist/` are gitignored. Do not commit build output.

## Layout

```
Sources/Directories/Directories.swift   one file, SwiftUI + AppKit
tools/make-icon.swift                  icon generation, run by build.sh
build.sh                               the whole build
```

## Before you open a pull request

There are no automated tests yet. That is a gap, not a decision -- if you are
adding something testable, tests are more welcome than the feature.

Say in the pull request what you did to check the change by hand. For anything
touching the file operations, check the recoverable path specifically: a name
collision becoming "x copy" rather than an overwrite, a cancelled transfer
leaving no half-copied file, and undo putting things back through the Trash.

## Things that have bitten before

Worth knowing before you spend an afternoon on one of these.

- **A SwiftUI `Menu` builds its contents whenever the surrounding body is
  evaluated**, not when it opens. The address bar's chevron menus are a
  directory listing, so as SwiftUI menus they re-read every folder on the path
  on every keystroke in the filter field. They are `NSMenu` with a delegate
  instead, filled in by `menuNeedsUpdate` only when one is about to appear.
  Anything whose menu items cost real work belongs in AppKit for the same
  reason.
- **Launch Services lookups are not free.** `NSWorkspace.icon(forFile:)` was
  being called from every row body on every render, which cost dozens per
  re-render. It is behind `FS.icon`'s cache now. Do not call it directly.
- **Never write `dirtyRect.fill()` in a custom `draw`.** Since macOS 14,
  `NSView.clipsToBounds` defaults to `false`, and `dirtyRect` is the *window's*
  dirty region in your view's coordinates, so filling it paints over the whole
  window. Use `bounds.intersection(dirtyRect).fill()` and set
  `clipsToBounds = true`.
- **Every file operation has to stay recoverable.** Nothing is overwritten, a
  collision becomes "x copy", delete means Trash, and undo moves the new copies
  to the Trash rather than unlinking them. A change that adds a "Replace?"
  dialog is a change to that principle, not an addition to it.

## Style

Match what is already there. Briefly:

- Four spaces, no tabs. Swift API Design Guidelines naming.
- **Comments explain why, not what.** A comment that restates the line below it
  is noise; a comment recording the defect a piece of code exists to prevent is
  the most valuable thing in the file. Most comments here are the second kind,
  and several name the bug they came from.
- **No icons or emoji** anywhere -- source, comments, log messages, commit
  messages, pull request descriptions.
- Commits use [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.

## Releases

`./release.sh` builds the app, zips the bundle into `dist/` as
`Directories-<version>-macos-arm64.zip` and writes `SHA256SUMS.txt`. It prints the
`gh release create` command to run. Binaries are ad-hoc signed and not
notarised, so the release notes must keep the quarantine instructions.

## Licence

By contributing you agree that your contributions are licensed under the MIT
licence, as with the rest of the project.
