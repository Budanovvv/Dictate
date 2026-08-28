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
# The owner's personal-only build. Sources/Personal/ is excluded from the
# repository and compiles to nothing without this flag, so a release built
# without --personal cannot contain it even by accident. release.sh greps the
# finished binary to make sure.
PERSONAL_FLAGS=()
if [[ " $* " == *" --personal "* ]]; then
    # Both halves matter. The compilation condition is what actually includes
    # the code; the Info.plist key is what release.sh can SEE. A marker inside
    # the binary would not do — dead code is stripped, so the check would pass
    # for the wrong reason, which is worse than no check at all.
    # $(inherited) is load-bearing: a build setting on the xcodebuild command
    # line applies to EVERY target, package dependencies included. Replacing the
    # value outright wiped swift-crypto's own conditions and broke its module
    # resolution — append, never replace.
    PERSONAL_FLAGS=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DICTATE_PERSONAL')
    echo "==> PERSONAL build — must not be released"
fi

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
        --personal) ;;   # handled above, before xcodegen
        *) echo "!! unknown flag: $arg"; exit 2 ;;
    esac
done


# A meeting being recorded outlives no restart: quitting the app closes its
# transcript file, and installing quits the app. That is not theory — the
# archive has two afternoons of forty-second fragments from days when this
# script ran every fifteen minutes while a real conversation was happening,
# and the owner reasonably thought the app had broken.
#
# Read from the log rather than from a flag file: the app already says when a
# session starts and stops, and a flag would be one more thing to leave stale
# after a crash. If the newest of those two lines is a start, something is
# being recorded right now.
meeting_is_recording() {
    local log="$HOME/Library/Logs/Dictate/dictate.log"
    [ -f "$log" ] || return 1
    pgrep -x Dictate >/dev/null || return 1      # no app, nothing to interrupt
    local last
    last=$(grep -a "meeting: session started\|meeting: session stopping" "$log" | tail -1)
    [[ "$last" == *"session started"* ]]
}

if meeting_is_recording; then
    echo "!! a meeting is being recorded — stopping now would close its transcript"
    echo "   stop the recording first (menu bar -> Stop), then run this again"
    exit 3
fi

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
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${PERSONAL_FLAGS[@]+"${PERSONAL_FLAGS[@]}"} \
    build ${EXTRA[@]+"${EXTRA[@]}"} \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
XC=${PIPESTATUS[0]}
set -o pipefail
[ "$XC" -eq 0 ] || { echo "!! xcodebuild failed (exit $XC)"; exit 1; }

# Mark a personal build so release.sh can SEE it. Stamped here rather than as
# a compile-time marker because dead code is stripped: a personal build with
# the feature not yet wired up would pass a binary grep for the wrong reason,
# and a check that passes for the wrong reason is worse than no check.
# Before codesign — editing the plist afterwards would break the signature.
if [ ${#PERSONAL_FLAGS[@]} -gt 0 ]; then
    /usr/libexec/PlistBuddy -c "Add :DictatePersonalBuild bool true" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    codesign --force --deep --sign "Developer ID Application" "$APP" >/dev/null 2>&1 \
        || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

{ [ -d "$APP" ] && codesign -v "$APP" 2>/dev/null; } || [ "$NOSIGN" = 1 ] \
    || { echo "!! Build or signing failed"; exit 1; }
echo "==> Done: $APP"

if [ "$INSTALL" = 1 ]; then
    # Graceful quit first: an instant pkill can land mid model-download/verify
    # and corrupt the model state (see the project's local notes).
    if pgrep -x Dictate >/dev/null; then
        osascript -e 'tell application id "com.valentynbudanov.Dictate" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 8); do pgrep -x Dictate >/dev/null || break; sleep 0.25; done
        pkill -x Dictate 2>/dev/null || true
    fi
    rm -rf /Applications/Dictate.app
    ditto "$APP" /Applications/Dictate.app
    # The build copy has done its job. A second runnable Dictate on disk is
    # the double-paste grabli, and once `open` has ever touched it, Launchpad
    # lists two Dictates (2026-08-27). /Applications is now the only copy;
    # test.sh falls back to it when the cache one is gone.
    rm -rf "$APP"
    echo "==> Installed: /Applications/Dictate.app"
    # The quit above must not be the end state: an install that leaves the
    # menu-bar app dead reads as "the build broke it" (2026-08-27, twice in
    # one morning before this line existed). LaunchServices returns -600 if
    # `open` fires while the old process is still exiting — wait it out.
    for _ in $(seq 8); do pgrep -x Dictate >/dev/null || break; sleep 0.25; done
    open -a /Applications/Dictate.app
    echo "==> Relaunched"
fi
