#!/usr/bin/env bash
# Build a polished .dmg installer for AudioVisualizer.
#
# Steps:
#   1. Release-build the .app via xcodebuild.
#   2. Stage it next to a /Applications symlink and the branded background.
#   3. Create a writable .dmg, mount it, and use AppleScript to set the
#      Finder window background, icon positions, and view options.
#   4. Convert to a compressed read-only .dmg.
#
# Output: <repo-root>/dist/AudioVisualizer-<version>.dmg
#
# Run from the repo root: ./scripts/make-dmg.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(grep -E 'CFBundleShortVersionString' project.yml | sed -E 's/.*"([0-9.]+)".*/\1/')"
VOLNAME="Audio Visualizer ${VERSION}"
DIST_DIR="dist"
STAGE_DIR="${DIST_DIR}/stage"
RW_DMG="${DIST_DIR}/rw.dmg"
FINAL_DMG="${DIST_DIR}/AudioVisualizer-${VERSION}.dmg"
BUILD_DIR="${DIST_DIR}/build"
APP_NAME="AudioVisualizer.app"
BG_SOURCE="docs/installer/dmg-background.png"

echo "==> Building Release ${VERSION}…"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}" "${STAGE_DIR}"
xcodebuild -project AudioVisualizer.xcodeproj \
           -scheme AudioVisualizer \
           -configuration Release \
           -destination 'platform=macOS' \
           -derivedDataPath "${BUILD_DIR}" \
           -quiet build

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}"
[[ -d "${APP_PATH}" ]] || { echo "build product missing at ${APP_PATH}"; exit 1; }

echo "==> Staging…"
cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"
mkdir -p "${STAGE_DIR}/.background"
cp "${BG_SOURCE}" "${STAGE_DIR}/.background/background.png"

echo "==> Creating writable DMG…"
# Sized generously so the AppleScript setup has room.
hdiutil create -volname "${VOLNAME}" \
               -srcfolder "${STAGE_DIR}" \
               -ov -format UDRW -fs HFS+ \
               "${RW_DMG}" >/dev/null

echo "==> Mounting…"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")
MOUNT_DEV=$(echo "${MOUNT_INFO}"  | awk 'NR==1 {print $1}')
MOUNT_PATH=$(echo "${MOUNT_INFO}" | awk -F'\t' 'NR==1 {print $NF}')
echo "    dev: ${MOUNT_DEV}"
echo "    at:  ${MOUNT_PATH}"

# Give Finder a moment to register the mount before AppleScript touches it.
sleep 2

echo "==> Configuring Finder layout…"
osascript <<EOF
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 740, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}" of container window to {150, 195}
        set position of item "Applications" of container window to {390, 195}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

# Force a sync so Finder writes .DS_Store onto the volume.
sync
sleep 1

echo "==> Unmounting…"
hdiutil detach "${MOUNT_DEV}" >/dev/null

echo "==> Compressing to final read-only DMG…"
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_DMG}" >/dev/null
rm -f "${RW_DMG}"

ls -lh "${FINAL_DMG}"
echo ""
echo "Done — ${FINAL_DMG}"
