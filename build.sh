#!/bin/bash
# Build TreeFiles.app. Pass --install to place it in /Applications and launch it.
set -euo pipefail

NAME="TreeFiles"
BUNDLE_ID="local.treefiles"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/build/${NAME}.app"

rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

echo "Compiling..."
swiftc -O -parse-as-library \
    "${HERE}/Sources/${NAME}/${NAME}.swift" \
    -o "${OUT}/Contents/MacOS/${NAME}"

# Ad-hoc signature. Replace with a Developer ID for distribution outside this Mac.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${OUT}"

echo "Built ${OUT}"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/${NAME}.app"
    cp -R "${OUT}" "/Applications/${NAME}.app"
    codesign --force --sign - --identifier "${BUNDLE_ID}" "/Applications/${NAME}.app"
    echo "Installed to /Applications/${NAME}.app"
    open "/Applications/${NAME}.app"
fi
