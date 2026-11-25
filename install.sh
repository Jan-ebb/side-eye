#!/bin/bash
# Installs Side Eye from its newest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/Jan-ebb/side-eye/main/install.sh | bash
#
# It downloads the release zip, checks it against the SHA-256 published next to it, puts Side Eye.app
# in Applications in place of any copy already there, and opens it. A file fetched this way carries
# no download warning, so macOS opens the app without the "could not verify" dialog that a browser
# download gets.
#
# Environment, all optional:
#   SIDE_EYE_VERSION        install this version, such as 0.18.0, in place of the newest
#   SIDE_EYE_INSTALL_DIR    where the app goes (default: /Applications, or ~/Applications if you
#                           can't write there)
#   SIDE_EYE_DOWNLOAD_BASE  fetch the zip and its checksum from this address, for trying the script out
set -euo pipefail

repository="https://github.com/Jan-ebb/side-eye"
app="Side Eye.app"

stop() { echo "$1" >&2; exit 1; }

if [[ "$(uname -s)" != Darwin ]]; then stop "Side Eye runs on macOS only."; fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then stop "Side Eye needs macOS 14 or later."; fi

if [[ -n "${SIDE_EYE_VERSION:-}" ]]; then
  tag="v${SIDE_EYE_VERSION#v}"
else
  # GitHub answers /releases/latest by sending the browser on to the newest release's own page.
  latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$repository/releases/latest")" ||
    stop "Couldn't reach GitHub to find the newest release."
  tag="${latest##*/}"
fi
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then stop "Couldn't find the newest release of Side Eye."; fi
version="${tag#v}"
zip="SideEye-$version.zip"
base="${SIDE_EYE_DOWNLOAD_BASE:-$repository/releases/download/$tag}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The name is in braces and the text plain ASCII: the bash that ships with macOS reads a character
# such as an ellipsis straight after a variable as part of its name.
echo "Downloading Side Eye ${version}..."
curl -fsSL "$base/$zip" -o "$work/$zip" || stop "Couldn't download Side Eye ${version}."
curl -fsSL "$base/$zip.sha256" -o "$work/$zip.sha256" || stop "Couldn't download the checksum for Side Eye ${version}."
expected="$(tr -d '[:space:]' < "$work/$zip.sha256")"
actual="$(shasum -a 256 "$work/$zip" | awk '{print $1}')"
if [[ -z "$expected" || "$expected" != "$actual" ]]; then
  stop "The download doesn't match its published checksum, so nothing was installed."
fi

/usr/bin/ditto -x -k "$work/$zip" "$work/unpacked"
if [[ ! -d "$work/unpacked/$app" ]]; then stop "The download didn't contain $app."; fi

destination="${SIDE_EYE_INSTALL_DIR:-/Applications}"
if [[ -z "${SIDE_EYE_INSTALL_DIR:-}" && ! -w "$destination" ]]; then destination="$HOME/Applications"; fi
mkdir -p "$destination"

# A running copy is asked to quit, so the new one can take its place.
if pgrep -x SideEye > /dev/null; then
  pkill -x SideEye || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x SideEye > /dev/null || break
    sleep 0.3
  done
fi

target="$destination/$app"
if [[ -e "$target" ]]; then rm -rf "$target"; fi
mv "$work/unpacked/$app" "$target"

echo "Installed Side Eye ${version} in ${destination}."
open "$target"
echo "It has no Dock icon: look for the pill at the right edge of your screen, or press Control-Option-Space."
