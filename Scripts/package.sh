#!/bin/bash
set -euo pipefail

# Builds Side Eye.app. Environment:
#   SIDE_EYE_UNIVERSAL=1        build for Apple silicon and Intel (default: this Mac's architecture)
#   SIDE_EYE_BUNDLE_ID          the app identifier (default: io.github.jan-ebb.side-eye)
#   SIDE_EYE_SUMMARY_MODEL      path to the summary model to bundle (default: none)
#   SIDE_EYE_LLAMA_SERVER       path to a self-contained llama-server to put inside, so summaries need
#                               no Homebrew (default: none; Scripts/llama-server.sh builds one)
project="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$project/Side Eye.app}"
version="$(tr -d '[:space:]' < "$project/VERSION")"
build="$(git -C "$project" rev-list --count HEAD 2>/dev/null || echo 1)"
bundle_id="${SIDE_EYE_BUNDLE_ID:-io.github.jan-ebb.side-eye}"
arch_flags=()
if [[ "${SIDE_EYE_UNIVERSAL:-0}" == 1 ]]; then arch_flags=(--arch arm64 --arch x86_64); fi
if [[ "$destination" != /* ]]; then destination="$PWD/$destination"; fi
if [[ "$destination" != *.app ]]; then
  echo "Destination must end in .app" >&2
  exit 2
fi

mkdir -p "$(dirname "$destination")"
stage="$(mktemp -d "$(dirname "$destination")/.side-eye-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Side Eye.app"
iconset="$stage/SideEye.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"

swift build --package-path "$project" --configuration release ${arch_flags[@]+"${arch_flags[@]}"}
binary="$(swift build --package-path "$project" --configuration release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)/SideEye"
/usr/bin/install -m 755 "$binary" "$app/Contents/MacOS/SideEye"
/usr/bin/xcrun swiftc "$project/Scripts/icon.swift" -o "$stage/side-eye-icon"
for size in 16 32 128 256 512; do
  "$stage/side-eye-icon" "$size" "$iconset/icon_${size}x${size}.png"
  "$stage/side-eye-icon" "$((size * 2))" "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/SideEye.icns"

if [[ -n "${SIDE_EYE_SUMMARY_MODEL:-}" ]]; then
  models="$app/Contents/Resources/Models"
  mkdir -p "$models"
  printf '%s  %s\n' '8b049f98461020b7e15797e13413fc63b9b500ffa883c74618b618ecbc2bfccf' "$SIDE_EYE_SUMMARY_MODEL" |
    /usr/bin/shasum -a 256 -c
  /bin/cp -c "$SIDE_EYE_SUMMARY_MODEL" "$models/SideEyeSummary.gguf" ||
    /usr/bin/install -m 644 "$SIDE_EYE_SUMMARY_MODEL" "$models/SideEyeSummary.gguf"
  /usr/bin/install -m 644 "$project/ModelLicenses/Qwen-LICENSE.txt" "$models/LICENSE.txt"
  /usr/bin/install -m 644 "$project/ModelLicenses/SideEyeSummary.md" "$models/SideEyeSummary.md"
fi

if [[ -n "${SIDE_EYE_LLAMA_SERVER:-}" ]]; then
  mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
  /usr/bin/install -m 755 "$SIDE_EYE_LLAMA_SERVER" "$app/Contents/Helpers/llama-server"
  /usr/bin/install -m 644 "$project/ModelLicenses/llama.cpp-LICENSE.txt" "$app/Contents/Resources/Licenses/llama.cpp.txt"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>SideEye</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleIconFile</key><string>SideEye</string>
    <key>CFBundleName</key><string>Side Eye</string>
    <key>CFBundleDisplayName</key><string>Side Eye</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Side Eye uses Automation to switch to the exact terminal tab for a Claude Code session when you open it.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$app/Contents/Info.plist"
# Signed ad-hoc, which needs no certificate: Apple silicon runs nothing that is unsigned. A program
# inside the app is signed before the app that contains it.
if [[ -e "$app/Contents/Helpers/llama-server" ]]; then
  /usr/bin/codesign --force --sign - "$app/Contents/Helpers/llama-server"
fi
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict --deep "$app"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$app" "$destination"
echo "$destination"
