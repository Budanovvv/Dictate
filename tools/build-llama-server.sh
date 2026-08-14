#!/bin/bash
# Builds Resources/llama-server: the universal (arm64 + x86_64) llama.cpp
# server that Dictate embeds at Contents/Helpers and runs as a child process
# to generate meeting titles, summaries and section lines.
#
#   ./tools/build-llama-server.sh
#
# Run this only when the pinned llama.cpp commit changes. The result is a
# 34 MB binary; whether it lives in git or is built on demand is a decision
# for whoever owns the repository — see the note at the bottom.
#
# WHY A SEPARATE PROCESS AND NOT A LINKED LIBRARY: this app linked llama.cpp
# once, for the AI-polish feature, and it aborted with SIGABRT on EVERY quit
# once a model had been loaded — llama's C++ static destructors tear down the
# Metal device inside exit() and race its own async init worker. See
# internal/GRABLI.md and Sources/LocalTextEngine.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned. An unpinned llama.cpp is a different program every week, and the
# generation quality in internal/CONTEXT.md was measured against this one.
COMMIT="7e4c0a9"
REPO="https://github.com/ggml-org/llama.cpp"
WORK="${TMPDIR:-/tmp}/dictate-llama-build"
OUT="Resources/llama-server"

command -v cmake >/dev/null || { echo "!! cmake not found (brew install cmake)"; exit 1; }

if [ ! -d "$WORK/.git" ]; then
    rm -rf "$WORK"
    git clone "$REPO" "$WORK"
fi
git -C "$WORK" fetch --all --quiet
git -C "$WORK" checkout --quiet "$COMMIT"

# Common flags, and every one of them earns its place:
#   BUILD_SHARED_LIBS=OFF  one self-contained executable — no dylibs to embed,
#                          re-path and sign separately.
#   LLAMA_CURL=OFF         the app downloads the model itself, with its own
#                          progress, resume and checksum (see
#                          LocalTextModelDownload). libcurl would be a second
#                          downloader and a third-party dependency.
#   LLAMA_OPENSSL=OFF      NOT optional. Left on, cmake finds Homebrew's
#                          OpenSSL and links /opt/homebrew/opt/openssl@3/... —
#                          a path that does not exist on a user's Mac. Verify
#                          with `otool -L`: nothing outside /usr/lib and
#                          /System/Library may appear.
#   deployment target 15.0 matches the app's.
COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_CURL=OFF
    -DLLAMA_OPENSSL=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_SERVER=ON
)

echo "==> arm64 (Metal)"
# GGML_METAL_EMBED_LIBRARY: the Metal shaders are compiled into the binary
# instead of shipped beside it as a .metallib, so there is exactly one file to
# copy and sign.
cmake -S "$WORK" -B "$WORK/build-arm64" "${COMMON[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null
cmake --build "$WORK/build-arm64" -j "$(sysctl -n hw.ncpu)" --target llama-server >/dev/null

echo "==> x86_64 (CPU)"
# No Metal: an Intel Mac's GPU cannot run these kernels, so the x86_64 slice is
# an honest CPU build. Slower — measured at ~14 s per passage against ~1.1 s on
# Apple silicon — which matches the claim this project already makes about
# Intel (internal/CONTEXT.md, item 5г). GGML_NATIVE=OFF so the binary does not
# bake in THIS machine's instruction set.
cmake -S "$WORK" -B "$WORK/build-x86" "${COMMON[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DGGML_METAL=OFF -DGGML_NATIVE=OFF >/dev/null
cmake --build "$WORK/build-x86" -j "$(sysctl -n hw.ncpu)" --target llama-server >/dev/null

mkdir -p Resources
lipo -create -output "$OUT" \
    "$WORK/build-arm64/bin/llama-server" "$WORK/build-x86/bin/llama-server"
chmod +x "$OUT"
# The project lives on an iCloud-synced Desktop and iCloud tags files within
# seconds; those tags break codesign ("resource fork … detritus not allowed").
xattr -c "$OUT"

echo
echo "==> $OUT"
lipo -info "$OUT"
echo "linked against (must be system-only):"
otool -L "$OUT" | tail -n +2 | sed 's/^/    /'
if otool -L "$OUT" | tail -n +2 | grep -qv -e "/usr/lib/" -e "/System/Library/"; then
    echo "!! non-system dependency — this binary will not run on a user's Mac"
    exit 1
fi
echo
echo "Signing is handled by the app build: project.yml copies this into"
echo "Contents/Helpers with CodeSignOnCopy, so it inherits the Release"
echo "configuration's Developer ID identity, hardened runtime and --timestamp."
echo "Verify after ./build.sh with:"
echo "    codesign -dv --verbose=4 \\"
echo "      ~/Library/Caches/DictateBuild/Build/Products/Release/Dictate.app/Contents/Helpers/llama-server"
