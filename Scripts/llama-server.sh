#!/bin/bash
# Builds llama.cpp's server as one self-contained program for Side Eye.app to carry, so summaries
# work without Homebrew.
#
#   ./Scripts/llama-server.sh <output file>
#
# It fetches llama.cpp at one pinned commit from GitHub, builds only its server, with nothing left to
# load from outside macOS, and writes it to <output file>. Needs git and cmake (brew install cmake).
# The source and the build are kept under .build/llama.cpp, so a second run is quick.
#
# Environment:
#   SIDE_EYE_UNIVERSAL=1   build for Apple silicon and Intel (default: this Mac's architecture)
set -euo pipefail

# llama.cpp 0.4.1, build 10964: the version Side Eye's summaries were written and checked against.
repository="https://github.com/ggml-org/llama.cpp"
commit="b29c606e28a01b1bc8c1351026a0fa6e616bf6c4"

project="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Usage: llama-server.sh <output file>}"
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi
cache="$project/.build/llama.cpp/$commit"
source="$cache/source"

if ! command -v cmake > /dev/null; then
  echo "Building llama.cpp needs cmake. Install it with: brew install cmake" >&2
  exit 2
fi

if [[ "$(git -C "$source" rev-parse HEAD 2> /dev/null || true)" != "$commit" ]]; then
  rm -rf "$source"
  mkdir -p "$source"
  git -C "$source" init --quiet
  # Asking for the commit by its full hash makes git itself check that this is the pinned source.
  git -C "$source" fetch --quiet --depth 1 "$repository" "$commit"
  git -C "$source" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
fi

architectures=("$(uname -m)")
if [[ "${SIDE_EYE_UNIVERSAL:-0}" == 1 ]]; then architectures=(arm64 x86_64); fi

built=()
for architecture in "${architectures[@]}"; do
  # Metal runs the model on Apple silicon's GPU. llama.cpp's own Intel builds leave it off as well.
  metal=ON
  if [[ "$architecture" == x86_64 ]]; then metal=OFF; fi
  build="$cache/build-$architecture"
  # Static libraries, no OpenMP and no OpenSSL: Side Eye talks to the server over a Unix socket, and
  # the result must run on a Mac that has none of Homebrew's libraries. The web UI is left out, which
  # also keeps the build from downloading one. GGML_NATIVE=OFF builds for every Mac of that
  # architecture, not only for this one's processor.
  cmake -S "$source" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_METAL="$metal" \
    -DGGML_METAL_EMBED_LIBRARY="$metal" \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_SERVER=ON > "$build.configure.log" 2>&1 ||
    { echo "Configuring llama.cpp for $architecture failed. See $build.configure.log" >&2; exit 1; }
  cmake --build "$build" --config Release --target llama-server -j "$(sysctl -n hw.logicalcpu)" > "$build.build.log" 2>&1 ||
    { echo "Building llama.cpp for $architecture failed. See $build.build.log" >&2; exit 1; }
  built+=("$build/bin/llama-server")
done

mkdir -p "$(dirname "$output")"
if [[ ${#built[@]} -gt 1 ]]; then
  /usr/bin/lipo -create "${built[@]}" -output "$output"
else
  /bin/cp "${built[0]}" "$output"
fi
/bin/chmod 755 "$output"

# Anything it would load from outside macOS would be missing on another Mac.
foreign="$(/usr/bin/otool -L "$output" | /usr/bin/awk '/^\t/ {print $1}' | /usr/bin/grep -vE '^(/usr/lib/|/System/Library/)' || true)"
if [[ -n "$foreign" ]]; then
  echo "The server still loads libraries other Macs don't have:" >&2
  echo "$foreign" >&2
  exit 1
fi
echo "$output"
/usr/bin/lipo -archs "$output"
