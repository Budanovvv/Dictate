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

# The llama.cpp helper is deliberately NOT in the repository (34 MB per copy,
# forever in git history, and as much again on every llama.cpp bump) — it is
# reproduced from a pinned upstream commit. Check BEFORE xcodegen: without this
# the run dies inside spec validation with "missing source directory", which
# reads like a corrupt checkout rather than a one-command fix.
if [ ! -x Resources/llama-server ]; then
    echo "!! Resources/llama-server is missing (helper for on-device text generation)."
    echo "   Build it once:  ./tools/build-llama-server.sh"
    exit 1
fi

# Dictate.xcodeproj is generated from project.yml (XcodeGen) and gitignored.
# Regenerate it every build so project.yml stays the single source of truth —
# otherwise a MARKETING_VERSION bump in project.yml never reaches the built app
# (the version lives in the .pbxproj, which xcodebuild reads as-is).
if command -v xcodegen >/dev/null; then
    xcodegen generate --quiet
else
    echo "!! xcodegen not found (brew install xcodegen) — using existing Dictate.xcodeproj as-is"
fi

DD="$HOME/Library/Caches/DictateBuild"
APP="$DD/Build/Products/Release/Dictate.app"

NOSIGN=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --nosign) NOSIGN=1 ;;
        --install) INSTALL=1 ;;
        *) echo "!! unknown flag: $arg"; exit 2 ;;
    esac
done

EXTRA=()
[ "$NOSIGN" = 1 ] && EXTRA+=(CODE_SIGNING_ALLOWED=NO)

# CFBundleVersion = git commit count: a monotonic build number with nothing to
# hand-bump. Sparkle compares it to decide an update is newer, so it must only
# grow — the commit count on main does. Falls back to 0 outside a git checkout.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Drop the previous artifact FIRST: with it in place, a failed xcodebuild would
# leave a perfectly signed stale app behind and the checks below would bless it
# — release.sh could then ship an old binary under a new version number.
rm -rf "$APP"

echo "==> xcodebuild (Release), build ${BUILD_NUMBER}"
set +o pipefail   # grep exiting 1 on "no matching lines" must not kill the build output filter
xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build ${EXTRA[@]+"${EXTRA[@]}"} \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
XC=${PIPESTATUS[0]}
set -o pipefail
[ "$XC" -eq 0 ] || { echo "!! xcodebuild failed (exit $XC)"; exit 1; }

{ [ -d "$APP" ] && codesign -v "$APP" 2>/dev/null; } || [ "$NOSIGN" = 1 ] \
    || { echo "!! Build or signing failed"; exit 1; }
echo "==> Done: $APP"

if [ "$INSTALL" = 1 ]; then
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
