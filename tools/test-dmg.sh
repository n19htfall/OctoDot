#!/bin/bash
# The disk image gate (docs/distribution-and-onboarding.md, section 8, gate 2):
#
#   tools/test-dmg.sh OctoDot-<version>.dmg COMPANION_ID IME_ID TEAM_ID
#
# The image verifies and is signed; mounted read-only (out of Finder's sight),
# it holds OctoDot.app, intact and signed by the team with the companion's
# identifier, the input method inside it with its own, and an Applications
# link to /Applications; and it detaches cleanly.
set -u
DMG=${1:?usage: test-dmg.sh DMG COMPANION_ID IME_ID TEAM_ID}
COMPANION=${2:?companion id}
IME=${3:?ime id}
TEAM=${4:?team id}
MOUNT=$(mktemp -d)
failures=0
check() {
    if [ "$1" = 0 ]; then echo "ok    $2"; else echo "FAIL  $2"; failures=$((failures + 1)); fi
}
ident() { codesign -dv "$1" 2>&1 | sed -n "s/^$2=//p"; }

hdiutil verify -quiet "$DMG"; check $? "the image verifies (its checksums)"
codesign --verify "$DMG" 2>/dev/null; check $? "the image is signed"
[ "$(ident "$DMG" TeamIdentifier)" = "$TEAM" ]; check $? "  by team $TEAM"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"; check $? "it mounts, read-only"
APP="$MOUNT/OctoDot.app"
[ -d "$APP" ]; check $? "it holds OctoDot.app"
codesign --verify --deep --strict "$APP" 2>/dev/null; check $? "  intact (codesign --verify --deep --strict)"
[ "$(ident "$APP" Identifier)" = "$COMPANION" ] && [ "$(ident "$APP" TeamIdentifier)" = "$TEAM" ]
check $? "  the companion, $COMPANION, signed by team $TEAM"
[ "$(ident "$APP/Contents/Resources/OctoDotIME.app" Identifier)" = "$IME" ]
check $? "  with the input method inside, $IME"
read -r _ pin_size pin_name < "$APP/Contents/Resources/OctoDotIME.app/Contents/Resources/data/grammar.pin" 2>/dev/null
[ -n "${pin_name:-}" ] && [ "$(stat -f %z "$APP/Contents/Resources/Grammar/$pin_name" 2>/dev/null)" = "${pin_size:-}" ]
check $? "  and the grammar model it pins, for a first install without a download"
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = /Applications ]
check $? "an Applications link, to /Applications"
[ -f "$MOUNT/.background/background.tiff" ]; check $? "the window's background, hidden in .background"
touch "$MOUNT/write-test" 2>/dev/null; [ $? -ne 0 ]; check $? "the volume is read-only"
extra=$(ls -A "$MOUNT" | grep -vE '^(OctoDot\.app|Applications|\.background|\.fseventsd|\.DS_Store|\.Trashes)$')
[ -z "$extra" ]; check $? "nothing else on it${extra:+ (has: $extra)}"
hdiutil detach -quiet "$MOUNT"; check $? "it detaches cleanly"
rmdir "$MOUNT" 2>/dev/null
[ $failures -eq 0 ] && echo "test-dmg: $(basename "$DMG") is good" || echo "test-dmg: $failures check(s) failed"
exit $((failures > 0))
