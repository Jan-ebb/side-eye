#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$project/Relay.app}"
if [[ "$destination" != /* ]]; then destination="$PWD/$destination"; fi
if [[ "$destination" != *.app ]]; then
  echo "Destination must end in .app" >&2
  exit 2
fi

mkdir -p "$(dirname "$destination")"
stage="$(mktemp -d "$(dirname "$destination")/.relay-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Relay.app"
iconset="$stage/Relay.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"

swift build --package-path "$project" --configuration release
binary="$(swift build --package-path "$project" --configuration release --show-bin-path)/Relay"
/usr/bin/install -m 755 "$binary" "$app/Contents/MacOS/Relay"
/usr/bin/xcrun swiftc "$project/Scripts/icon.swift" -o "$stage/relay-icon"
for size in 16 32 128 256 512; do
  "$stage/relay-icon" "$size" "$iconset/icon_${size}x${size}.png"
  "$stage/relay-icon" "$((size * 2))" "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/Relay.icns"

if [[ -n "${RELAY_SUMMARY_MODEL:-}" ]]; then
  models="$app/Contents/Resources/Models"
  mkdir -p "$models"
  printf '%s  %s\n' '8b049f98461020b7e15797e13413fc63b9b500ffa883c74618b618ecbc2bfccf' "$RELAY_SUMMARY_MODEL" |
    /usr/bin/shasum -a 256 -c
  /bin/cp -c "$RELAY_SUMMARY_MODEL" "$models/RelaySummary.gguf" ||
    /usr/bin/install -m 644 "$RELAY_SUMMARY_MODEL" "$models/RelaySummary.gguf"
  /usr/bin/install -m 644 "$project/ModelLicenses/Qwen-LICENSE.txt" "$models/LICENSE.txt"
  /usr/bin/install -m 644 "$project/ModelLicenses/RelaySummary.md" "$models/RelaySummary.md"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Relay</string>
    <key>CFBundleIdentifier</key><string>com.relay.sessions</string>
    <key>CFBundleIconFile</key><string>Relay</string>
    <key>CFBundleName</key><string>Relay</string>
    <key>CFBundleDisplayName</key><string>Relay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.13.1</string>
    <key>CFBundleVersion</key><string>19</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Relay uses Automation to switch to the exact terminal tab for a Claude Code session when you open it.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$app" "$destination"
echo "$destination"
