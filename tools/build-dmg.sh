#!/bin/bash
# The drag-to-Applications disk image (docs/distribution-and-onboarding.md,
# section 7), with nothing but hdiutil, AppleScript and codesign:
#
#   tools/build-dmg.sh OctoDot.app OUT.dmg BACKGROUND.tiff SIGN_IDENTITY [--timestamp|--timestamp=none]
#
# A staging folder holds OctoDot.app, an Applications link and the hidden
# background; a writable image of it gets its Finder window laid out (icon
# view, no toolbar, fixed bounds and positions, the background), then it is
# compressed read-only (UDZO), signed, and verified. The layout needs Finder
# to take AppleScript from this terminal (macOS asks once); with
# OCTODOT_DMG_LAYOUT=0, or when Finder declines, the image is built without
# it, in Finder's default view.
set -euo pipefail
APP=${1:?usage: build-dmg.sh OctoDot.app OUT.dmg BACKGROUND.tiff SIGN_IDENTITY [TIMESTAMP]}
OUT=${2:?out}
BACKGROUND=${3:?background}
IDENTITY=${4:?identity}
TIMESTAMP=${5:---timestamp=none}
VOLUME=OctoDot
WORK=$(mktemp -d)
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ]; then hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [ -d "/Volumes/$VOLUME" ]; then
    echo "build-dmg: a volume named $VOLUME is mounted; eject it first" >&2
    exit 1
fi

# 1. The staging folder.
mkdir -p "$WORK/stage/.background" "$WORK/stage/.fseventsd"
ditto "$APP" "$WORK/stage/OctoDot.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$BACKGROUND" "$WORK/stage/.background/background.tiff"
touch "$WORK/stage/.fseventsd/no_log"          # no fsevents log on the image

# 2. A writable image of it, mounted where Finder sees it by its volume name.
size=$(( $(du -sm "$WORK/stage" | cut -f1) + 40 ))
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -size "${size}m" "$WORK/rw.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"
MOUNTED=1

# 3. The window: icon view, the background, the two icons on its arrow.
if [ "${OCTODOT_DMG_LAYOUT:-1}" != 0 ]; then
    if ! osascript <<EOF 2>/dev/null
tell application "Finder"
    set theDisk to disk "$VOLUME"
    open theDisk
    set theWindow to container window of theDisk
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set bounds of theWindow to {200, 120, 860, 520}
    set theOptions to icon view options of theWindow
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 128
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.tiff" of theDisk
    set position of item "OctoDot.app" of theWindow to {165, 190}
    set position of item "Applications" of theWindow to {495, 190}
    update theDisk without registering applications
    delay 1
    close theWindow
end tell
EOF
    then
        echo "build-dmg: Finder did not lay the window out (allow this terminal to control Finder, or OCTODOT_DMG_LAYOUT=0); default view" >&2
    fi
fi
chflags hidden "$MOUNT/.background" "$MOUNT/.fseventsd" 2>/dev/null || true
sync
hdiutil detach -quiet "$MOUNT"
MOUNTED=0

# 4. Read-only and compressed, signed, verified.
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
codesign --force --sign "$IDENTITY" "$TIMESTAMP" "$OUT"
hdiutil verify -quiet "$OUT"
echo "build-dmg: $OUT ($(du -h "$OUT" | cut -f1))"
