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

# CFBundleVersion = git commit count: a monotonic build number with nothing to
# hand-bump. Sparkle compares it to decide an update is newer, so it must only
# grow — the commit count on main does. Falls back to 0 outside a git checkout.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

echo "==> xcodebuild (Release), build ${BUILD_NUMBER}"
xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build ${EXTRA[@]+"${EXTRA[@]}"} \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

APP="$DD/Build/Products/Release/Dictate.app"
{ [ -d "$APP" ] && codesign -v "$APP" 2>/dev/null; } || [ "${1:-}" = "--nosign" ] \
    || { echo "!! Build or signing failed"; exit 1; }
echo "==> Done: $APP"

if [ "${1:-}" = "--install" ]; then
    # Graceful quit first: an instant pkill can land mid model-download/verify
    # and corrupt the model state (see internal/GRABLI.md).
    if pgrep -x Dictate >/dev/null; then
        osascript -e 'tell application id "com.valentynbudanov.Dictate" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 8); do pgrep -x Dictate >/dev/null || break; sleep 0.25; done
        pkill -x Dictate 2>/dev/null || true
    fi
    rm -rf /Applications/Dictate.app
    ditto "$APP" /Applications/Dictate.app
    echo "==> Installed: /Applications/Dictate.app"
fi
