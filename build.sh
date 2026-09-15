#!/bin/bash
# Build Directories.app. Pass --install to place it in /Applications and launch it.
#
# The icon is generated from tools/make-icon.swift on every build, so it is kept
# as source rather than as a checked-in binary.
set -euo pipefail

NAME="Directories"
MIN_MACOS="14.0"
BUNDLE_ID="com.ankitgoyal.directories"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/build/${NAME}.app"
ICONSET="${HERE}/build/${NAME}.iconset"

rm -rf "${OUT}" "${ICONSET}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"

echo "Generating icon..."
# Icon variant, by number. Run this to see them all before changing it:
#   swift tools/make-icon.swift --preview /tmp/variants.png
# 1 panes  2 magnify  3 stack  4 lamp-lit  5 drawer  6 open-folder
ICON_VARIANT=2
swift "${HERE}/tools/make-icon.swift" "${ICONSET}" "${ICON_VARIANT}" >/dev/null
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
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

echo "Compiling..."
# -target is not optional. Without it swiftc takes the deployment target from
# whatever the build machine is running, so a Mac on macOS 26 produced a binary
# stamped minos 26.0 while the Info.plist below claimed 14.0. Launch Services
# believed the plist and let it start; dyld then refused it, on every Mac older
# than the one that built it. The architecture follows the host so that building
# from source works on an Intel Mac as well.
ARCH="$(uname -m)"
swiftc -O -parse-as-library -target "${ARCH}-apple-macos${MIN_MACOS}" \
    "${HERE}/Sources/${NAME}/${NAME}.swift" \
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
    # Remove the staging copy: two identical bundles both get indexed by
    # Spotlight, so searching the app name offers a stale duplicate.
    rm -rf "${OUT}" "${ICONSET}"
    echo "Installed to /Applications/${NAME}.app"
    open "/Applications/${NAME}.app"
fi
