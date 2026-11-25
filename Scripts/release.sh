#!/bin/bash
# Builds the release download: a universal Side Eye.app, zipped, with its checksum. The app carries
# llama.cpp's server, built by Scripts/llama-server.sh, which needs cmake.
#
#   ./Scripts/release.sh
#
# The app is signed ad-hoc, with no certificate. People install it with install.sh: an app that
# arrives through a browser instead is blocked by macOS.
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '[:space:]' < "$project/VERSION")"
out="$project/dist"
zip="$out/SideEye-$version.zip"

rm -rf "$out"
mkdir -p "$out"
SIDE_EYE_UNIVERSAL=1 "$project/Scripts/llama-server.sh" "$out/llama-server" > /dev/null
SIDE_EYE_UNIVERSAL=1 SIDE_EYE_LLAMA_SERVER="$out/llama-server" "$project/Scripts/package.sh" "$out/Side Eye.app" > /dev/null
rm "$out/llama-server"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$out/Side Eye.app" "$zip"

/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}' > "$zip.sha256"
echo "$zip"
echo "sha256 $(cat "$zip.sha256")"
/usr/bin/lipo -archs "$out/Side Eye.app/Contents/MacOS/SideEye"
