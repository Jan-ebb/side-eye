#!/bin/bash
# Builds the release download: a universal Relay.app, zipped, with its checksum.
#
#   ./Scripts/release.sh
#
# Environment, both optional:
#   RELAY_SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)" to sign for other Macs
#   RELAY_NOTARY_PROFILE    a notarytool keychain profile; with it the app is notarized and stapled
#
# Without a Developer ID the app is ad-hoc signed. It runs, but macOS asks people to allow it by hand.
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '[:space:]' < "$project/VERSION")"
out="$project/dist"
zip="$out/Relay-$version.zip"

rm -rf "$out"
mkdir -p "$out"
RELAY_UNIVERSAL=1 "$project/Scripts/package.sh" "$out/Relay.app" > /dev/null

archive() { /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$out/Relay.app" "$zip"; }
archive
if [[ -n "${RELAY_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/xcrun notarytool submit "$zip" --keychain-profile "$RELAY_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$out/Relay.app"
  rm "$zip"
  archive
fi

/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}' > "$zip.sha256"
echo "$zip"
echo "sha256 $(cat "$zip.sha256")"
/usr/bin/lipo -archs "$out/Relay.app/Contents/MacOS/Relay"
