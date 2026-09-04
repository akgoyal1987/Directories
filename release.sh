#!/bin/bash
# Build Directories and stage the release artifact in dist/.
#
# The binary is not committed: it is large, it changes on every build, and an
# ad-hoc signature is tied to the machine that produced it. It is attached to a
# GitHub Release instead, which is what this script prepares.
set -euo pipefail

NAME="Directories"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${HERE}/dist"

rm -rf "${DIST}"
mkdir -p "${DIST}"

echo "==> building ${NAME}"
"${HERE}/build.sh" >/dev/null

BUNDLE="${HERE}/build/${NAME}.app"
if [[ ! -d "${BUNDLE}" ]]; then
    echo "!! build produced no ${BUNDLE}"
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${BUNDLE}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
ARCHIVE="${DIST}/${NAME}-${VERSION}-macos-arm64.zip"

# ditto rather than zip: it preserves the bundle's symlinks, resource forks and
# code signature, which a plain zip does not.
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE}" "${ARCHIVE}"
( cd "${DIST}" && shasum -a 256 *.zip | tee SHA256SUMS.txt )

cat <<NOTE

Artifacts are in dist/. To publish:

  gh release create v${VERSION} dist/*.zip dist/SHA256SUMS.txt \\
      --title "v${VERSION}" --notes-file RELEASE_NOTES.md

The bundle is ad-hoc signed, so on another Mac Gatekeeper will refuse the first
launch. The release notes tell people how to clear the quarantine flag.
Shipping without that friction needs a paid Apple Developer ID and notarisation.
NOTE
