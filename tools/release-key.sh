#!/bin/bash
# Makes OctoDot's update signing key, once (docs/distribution-and-onboarding.md,
# section 5):
#
#   tools/release-key.sh OCTO_UPDATE_SIGN
#
# An Ed25519 pair: the private key into the login Keychain (a generic
# password, never a file, never the repository), the public key into
# macos/update-public-key.txt, which builds put in the companion's Info.plist
# and which is committed. Refuses to replace a key that exists: every
# installed copy trusts it, and only it.
set -euo pipefail
SIGNER=${1:?usage: release-key.sh OCTO_UPDATE_SIGN}
SERVICE=io.github.n19htfall.OctoDot.update-signing
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
    echo "release-key: a signing key is already in the Keychain ($SERVICE); installed copies trust it, so it stays" >&2
    exit 1
fi
pair=$("$SIGNER" keygen)
private=$(echo "$pair" | awk '$1 == "private" { print $2 }')
public=$(echo "$pair" | awk '$1 == "public" { print $2 }')
security add-generic-password -s "$SERVICE" -a OctoDot -l "OctoDot update signing key" -w "$private"
echo "$public" > "$ROOT/macos/update-public-key.txt"
echo "release-key: the private key is in your login Keychain ($SERVICE); the public key is in macos/update-public-key.txt"
echo "Back the private key up somewhere safe: an update signed with another key is refused by every installed copy."
