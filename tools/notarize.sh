#!/bin/bash
# Notarizes and staples a release (docs/distribution-and-onboarding.md, section 7):
#
#   tools/notarize.sh OctoDot.app|OctoDot.dmg NOTARY_PROFILE
#
# An app goes to Apple's notary service as a zip (ditto keeps its signature
# and metadata), a disk image as it is; `notarytool submit --wait` blocks
# until Apple answers. Accepted, the ticket is stapled to the app or image,
# so Gatekeeper accepts it offline. Rejected, Apple's log says why. The
# profile holds the credentials, in the Keychain, made once with:
#   xcrun notarytool store-credentials NOTARY_PROFILE --apple-id … --team-id G4JRQAX252
set -euo pipefail
TARGET=${1:?usage: notarize.sh OctoDot.app|OctoDot.dmg NOTARY_PROFILE}
PROFILE=${2:?notary profile}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "notarize: no notarytool credentials named $PROFILE in the Keychain; make them once with" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id <team>" >&2
    exit 1
fi
submission="$TARGET"
if [ -d "$TARGET" ]; then
    submission="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$submission"
fi
result=$(xcrun notarytool submit "$submission" --keychain-profile "$PROFILE" --wait --output-format json)
status=$(echo "$result" | plutil -extract status raw - 2>/dev/null || echo unknown)
id=$(echo "$result" | plutil -extract id raw - 2>/dev/null || echo "")
if [ "$status" != Accepted ]; then
    echo "notarize: $(basename "$TARGET") was not accepted ($status)" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "notarize: $(basename "$TARGET") notarized and stapled"
