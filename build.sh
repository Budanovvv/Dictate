#!/bin/bash
# Build Dictate.app via xcodebuild. Distribution DMGs are built by ./release.sh.
# Signing Team is picked once in Xcode: target Dictate → Signing & Capabilities → Team.
#
# ./build.sh            — build (Release)
# ./build.sh --install  — build and install into /Applications
# ./build.sh --nosign   — build without signing (compilation check)
#
# The build directory is outside iCloud: the project lives on the Desktop
# (iCloud-synced), and iCloud xattrs (com.apple.fileprovider.*, FinderInfo)
# break codesign ("resource fork … detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")"

DD="$HOME/Library/Caches/DictateBuild"

EXTRA=()
[ "${1:-}" = "--nosign" ] && EXTRA+=(CODE_SIGNING_ALLOWED=NO)

echo "==> xcodebuild (Release)…"
xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" build ${EXTRA[@]+"${EXTRA[@]}"} \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

APP="$DD/Build/Products/Release/Dictate.app"
{ [ -d "$APP" ] && codesign -v "$APP" 2>/dev/null; } || [ "${1:-}" = "--nosign" ] \
    || { echo "!! Build or signing failed"; exit 1; }
echo "==> Done: $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Dictate 2>/dev/null || true
    rm -rf /Applications/Dictate.app
    ditto "$APP" /Applications/Dictate.app
    echo "==> Installed: /Applications/Dictate.app"
fi
