#!/bin/bash
# Dictate release: build → branded DMG (human) + plain DMG (Sparkle payload)
#                  → notarize both → Sparkle EdDSA signing → appcast.
#
# ./release.sh              — build release artifacts into ./release
# ./release.sh --publish    — same + git tag + GitHub Release with DMG and appcast
#
# Notarization kicks in automatically if the keychain profile is configured:
#   xcrun notarytool store-credentials dictate-notary \
#       --apple-id <APPLE_ID> --team-id 3BN45AZPR2 --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")"

DD="$HOME/Library/Caches/DictateBuild"
APP="$DD/Build/Products/Release/Dictate.app"
TOOLS="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
OUT="release"
DMG="$OUT/Dictate-$VERSION.dmg"                 # branded, human-facing (built in $DD, moved into $OUT after appcast)
UPDATE_DMG="$OUT/Dictate-$VERSION-update.dmg"   # plain, Sparkle's silent-update payload (appcast points here)
BRANDED_TMP="$DD/Dictate-$VERSION.dmg"          # branded staged outside $OUT so generate_appcast ignores it
REPO="Budanovvv/Dictate"

echo "==> Release v$VERSION"

# Phantom watch: something on this machine has repeatedly replaced
# /Applications/Dictate.app during release builds (internal/GRABLI.md).
# Record evidence while we work; the check at the end reports real changes.
PHANTOM_LOG="${TMPDIR:-/tmp}/dictate-phantom-watch.log"
PHANTOM_PID=""
if [ -f internal/claude-tooling/phantom-watch.py ]; then
    rm -f "$PHANTOM_LOG"
    python3 internal/claude-tooling/phantom-watch.py "$PHANTOM_LOG" >/dev/null 2>&1 &
    PHANTOM_PID=$!
fi
finish_phantom_watch() {
    [ -n "$PHANTOM_PID" ] || return 0
    kill "$PHANTOM_PID" 2>/dev/null || true
    # "CHANGE None ->" is the watcher's own baseline; anything else is real
    if grep "CHANGE (" "$PHANTOM_LOG" >/dev/null 2>&1; then
        echo "  ⚠️  /Applications/Dictate.app CHANGED during the release — see $PHANTOM_LOG"
    fi
}
trap finish_phantom_watch EXIT

# 1. Clean build + tests
./build.sh >/dev/null
echo "  ✅ build"
./test.sh --quick >/dev/null 2>&1 && echo "  ✅ quick tests" || { echo "  ❌ tests"; exit 1; }

# 2. Two DMGs from one re-signed app:
#   • BRANDED (Dictate-X.dmg) — the human download: a create-dmg image with a
#     custom volume icon and a "Drag into Applications" background layout.
#   • PLAIN  (Dictate-X-update.dmg) — Sparkle's silent-update payload, a bare
#     hdiutil image. A branded DMG carries a saved Finder window state (.DS_Store)
#     that makes the volume auto-open and FLASH on screen every time Sparkle
#     mounts it for a silent update (this is exactly why 2.2.1 dropped branding).
#     Sparkle only ever mounts the PLAIN one, so silent updates stay silent while
#     humans still get the nice branded window. The appcast points at -update.dmg.
# Staging lives OUTSIDE iCloud: ./release is on the Desktop, and the iCloud
# daemon tags files there within seconds (com.apple.fileprovider.*, FinderInfo)
# — the tags get packed into the DMG and break strict codesign of the app.
STAGE="$DD/dmg-stage"
rm -rf "$OUT" "$STAGE" && mkdir -p "$OUT" "$STAGE"
ditto "$APP" "$STAGE/Dictate.app"

# Re-sign Sparkle's nested helpers with our Developer ID. xcodebuild re-signs the
# framework's own binary but leaves Updater.app, Autoupdate and the two XPCServices
# with their upstream signatures and no secure timestamp — the notary service
# rejects those ("not signed with a valid Developer ID certificate" / "no secure
# timestamp"). Sign inside-out (deepest bundle first), then re-seal the framework
# and finally the app. The app re-sign carries only Dictate.entitlements, so it
# also drops the get-task-allow that Xcode would otherwise inject.
DEVID="Developer ID Application: Valentyn Budanov (3BN45AZPR2)"
SPK="$STAGE/Dictate.app/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in \
    "$SPK/XPCServices/Downloader.xpc" \
    "$SPK/XPCServices/Installer.xpc" \
    "$SPK/Updater.app" \
    "$SPK/Autoupdate"; do
    codesign --force --options runtime --timestamp --sign "$DEVID" "$component"
done
codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$STAGE/Dictate.app/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp \
    --entitlements Sources/Dictate.entitlements --sign "$DEVID" "$STAGE/Dictate.app"

codesign --verify --strict --deep "$STAGE/Dictate.app" \
    || { echo "  ❌ staged app fails strict codesign (xattr detritus?)"; exit 1; }
# Branded human DMG first, while $STAGE still holds ONLY Dictate.app (create-dmg
# adds its own Applications drop-link). Built into $DD, not $OUT, so the
# generate_appcast scan below never lists it as a second update. create-dmg
# briefly opens a Finder window to bake in the icon layout — that saved state is
# precisely what we keep away from Sparkle.
if ! command -v create-dmg >/dev/null; then
    echo "  ❌ create-dmg not found (brew install create-dmg) — cannot build the branded installer"; exit 1
fi
rm -f "$BRANDED_TMP"
create-dmg \
    --volname "Dictate" \
    --volicon "Sources/AppIcon.icns" \
    --background "assets/dmg-background.tiff" \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "Dictate.app" 150 185 \
    --app-drop-link 450 185 \
    --hide-extension "Dictate.app" \
    --no-internet-enable \
    "$BRANDED_TMP" "$STAGE" >/dev/null
codesign --force --timestamp --sign "Developer ID Application" "$BRANDED_TMP"
echo "  ✅ branded DMG: $DMG ($(du -h "$BRANDED_TMP" | cut -f1 | xargs))"

# Plain update DMG (Sparkle payload): bare image, no saved window state.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dictate" -srcfolder "$STAGE" -ov -format UDZO -quiet "$UPDATE_DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "Developer ID Application" "$UPDATE_DMG"
echo "  ✅ update DMG: $UPDATE_DMG ($(du -h "$UPDATE_DMG" | cut -f1 | xargs))"

# 3. Notarization — skipped if the keychain profile is not configured. Both DMGs
# (the branded human download and the plain Sparkle payload) are notarized and
# stapled so Gatekeeper accepts them offline.
if xcrun notarytool history --keychain-profile dictate-notary >/dev/null 2>&1; then
    for artifact in "$BRANDED_TMP" "$UPDATE_DMG"; do
        echo "==> Notarization: $(basename "$artifact") (may take a few minutes)…"
        xcrun notarytool submit "$artifact" --keychain-profile dictate-notary --wait
        xcrun stapler staple "$artifact"
        echo "  ✅ notarized and stapled: $(basename "$artifact")"
    done
else
    echo "  ⚠️  notarization skipped: no dictate-notary profile"
    echo "     (set it up: xcrun notarytool store-credentials dictate-notary --apple-id … --team-id 3BN45AZPR2 --password …)"
fi

# 3.5. Icon on the branded .dmg file itself (visible locally/AirDrop; HTTP
#      downloads strip the xattr). create-dmg --volicon already sets the mounted
#      volume's icon; this also stamps the icon onto the .dmg file. Applied AFTER
#      stapling so the notarized file is not modified afterwards (an xattr icon
#      doesn't touch the data fork, so the staple stays valid). Only the branded
#      DMG gets it — the plain update DMG is never seen by a human.
osascript -e 'use framework "AppKit"' \
    -e "set i to current application's NSImage's alloc()'s initWithContentsOfFile:\"$PWD/Sources/AppIcon.icns\"" \
    -e "current application's NSWorkspace's sharedWorkspace()'s setIcon:i forFile:\"$BRANDED_TMP\" options:0" >/dev/null \
    && echo "  ✅ icon on the .dmg file"

# 4. Release notes — taken from the body of the released commit. GitHub's
# --generate-notes builds text from pull requests, and we push to main
# directly, so it produces an empty page. The same notes are converted to
# HTML next to the DMG: generate_appcast embeds them into the appcast, and
# Sparkle shows the changelog right in the update window.
NOTES_MD="$OUT/notes.md"
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
[ "$PREV_TAG" = "v$VERSION" ] && PREV_TAG=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || true)
{
    git log -1 --format=%b
    [ -n "$PREV_TAG" ] && printf '\n**Full Changelog**: https://github.com/%s/compare/%s...v%s\n' "$REPO" "$PREV_TAG" "$VERSION"
} > "$NOTES_MD"
python3 - "$NOTES_MD" > "$OUT/Dictate-$VERSION-update.html" <<'PYEOF'
# Minimal markdown → HTML for Sparkle: paragraphs, "- " lists, **bold**, links.
import html, re, sys
text = open(sys.argv[1]).read()
def inline(s):
    s = html.escape(s)
    s = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', s)
    s = re.sub(r'(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)
    return s
out = []
for block in re.split(r'\n\s*\n', text):
    block = block.strip('\n')
    if not block.strip():
        continue
    if block.lstrip().startswith('## '):
        out.append('<h2>%s</h2>' % inline(block.lstrip()[3:].strip()))
    elif block.lstrip().startswith('- '):
        items = re.split(r'\n(?=- )', block.lstrip())
        lis = ''.join('<li>%s</li>' % inline(' '.join(l.strip() for l in i[2:].splitlines())) for i in items)
        out.append('<ul>%s</ul>' % lis)
    else:
        out.append('<p>%s</p>' % inline(' '.join(l.strip() for l in block.splitlines())))
print('\n'.join(out))
PYEOF
echo "  ✅ release notes from the commit body"

# 5. Update signing (EdDSA from Keychain) + appcast
"$TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --embed-release-notes \
    -o "$OUT/appcast.xml" "$OUT"
echo "  ✅ appcast.xml (EdDSA signature from Keychain)"

# The branded DMG was kept out of $OUT so generate_appcast (which scans the whole
# folder) wouldn't list it as a second update. The appcast now references only the
# plain -update.dmg; move the human installer into place for publishing.
mv "$BRANDED_TMP" "$DMG"
echo "  ✅ branded installer ready: $DMG"

# 6. Publishing
if [ "${1:-}" = "--publish" ]; then
    git tag -f "v$VERSION" && git push -f origin "v$VERSION"
    gh release create "v$VERSION" "$DMG" "$UPDATE_DMG" "$OUT/appcast.xml" \
        --repo "$REPO" --title "Dictate $VERSION" --notes-file "$NOTES_MD" 2>/dev/null \
      || gh release upload "v$VERSION" "$DMG" "$UPDATE_DMG" "$OUT/appcast.xml" --repo "$REPO" --clobber
    echo "  ✅ published: https://github.com/$REPO/releases/tag/v$VERSION"
    echo "  ⚠️  Sparkle will only see the update once the releases repository is public"
else
    echo
    echo "Artifacts in $OUT/. To publish: ./release.sh --publish"
fi