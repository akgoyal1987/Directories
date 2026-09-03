#!/bin/bash
# Build Arbor.app. Pass --install to place it in /Applications and launch it.
#
# The icon is generated from tools/make-icon.swift on every build, so it is kept
# as source rather than as a checked-in binary.
set -euo pipefail

NAME="Arbor"
BUNDLE_ID="com.ankitgoyal.arbor"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/build/${NAME}.app"
ICONSET="${HERE}/build/${NAME}.iconset"

rm -rf "${OUT}" "${ICONSET}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"

echo "Generating icon..."
swift "${HERE}/tools/make-icon.swift" "${ICONSET}" >/dev/null
iconutil --convert icns "${ICONSET}" --output "${OUT}/Contents/Resources/AppIcon.icns"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
swiftc -O -parse-as-library "${HERE}/Sources/${NAME}/${NAME}.swift" \
    -o "${OUT}/Contents/MacOS/${NAME}"

# Ad-hoc signature. Replace with a Developer ID for distribution off this Mac.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${OUT}"
echo "Built ${OUT}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -f "${NAME}.app/Contents/MacOS/${NAME}" 2>/dev/null || true
    rm -rf "/Applications/${NAME}.app"
    cp -R "${OUT}" "/Applications/${NAME}.app"
    codesign --force --sign - --identifier "${BUNDLE_ID}" "/Applications/${NAME}.app"
    # Nudge Launch Services so the new icon shows immediately.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "/Applications/${NAME}.app" 2>/dev/null || true
    echo "Installed to /Applications/${NAME}.app"
    open "/Applications/${NAME}.app"
fi
