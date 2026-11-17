#!/bin/bash
# Builds the release download: a universal Side Eye.app, zipped, with its checksum.
#
#   ./Scripts/release.sh
#
# Environment, both optional:
#   SIDE_EYE_SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)" to sign for other Macs
#   SIDE_EYE_NOTARY_PROFILE    a notarytool keychain profile; with it the app is notarized and stapled
#
# Without a Developer ID the app is ad-hoc signed. It runs, but macOS asks people to allow it by hand.
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '[:space:]' < "$project/VERSION")"
out="$project/dist"
zip="$out/SideEye-$version.zip"

rm -rf "$out"
mkdir -p "$out"
SIDE_EYE_UNIVERSAL=1 "$project/Scripts/package.sh" "$out/Side Eye.app" > /dev/null

archive() { /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$out/Side Eye.app" "$zip"; }
archive
if [[ -n "${SIDE_EYE_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/xcrun notarytool submit "$zip" --keychain-profile "$SIDE_EYE_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$out/Side Eye.app"
  rm "$zip"
  archive
fi

/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}' > "$zip.sha256"
echo "$zip"
echo "sha256 $(cat "$zip.sha256")"
/usr/bin/lipo -archs "$out/Side Eye.app/Contents/MacOS/SideEye"
