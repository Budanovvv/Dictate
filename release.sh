#!/bin/bash
# Dictate release: build → DMG → (notarization) → Sparkle signing → appcast.
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
DMG="$OUT/Dictate-$VERSION.dmg"
REPO="Budanovvv/Dictate"

echo "==> Release v$VERSION"

# 1. Clean build + tests
./build.sh >/dev/null
echo "  ✅ build"
./test.sh --quick >/dev/null 2>&1 && echo "  ✅ quick tests" || { echo "  ❌ tests"; exit 1; }

# 2. DMG with branded layout; background: assets/dmg-background.tiff (1x+2x).
# Staging lives OUTSIDE iCloud: ./release is on the Desktop, and the iCloud
# daemon tags files there within seconds (com.apple.fileprovider.*, FinderInfo)
# — the tags get packed into the DMG and break strict codesign of the app.
STAGE="$DD/dmg-stage"
rm -rf "$OUT" "$STAGE" && mkdir -p "$OUT" "$STAGE"
ditto "$APP" "$STAGE/Dictate.app"
codesign --verify --strict "$STAGE/Dictate.app" \
    || { echo "  ❌ staged app fails strict codesign (xattr detritus?)"; exit 1; }
if command -v create-dmg >/dev/null; then
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
        "$DMG" "$STAGE" >/dev/null
else
    echo "  ⚠️  create-dmg not found (brew install create-dmg) — building a plain DMG"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Dictate" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
fi
rm -rf "$STAGE"
codesign --force --sign "Apple Development" "$DMG" 2>/dev/null || true
echo "  ✅ DMG: $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

# 3. Notarization — skipped if the keychain profile is not configured.
if xcrun notarytool history --keychain-profile dictate-notary >/dev/null 2>&1; then
    echo "==> Notarization (may take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile dictate-notary --wait
    xcrun stapler staple "$DMG"
    echo "  ✅ notarized and stapled"
else
    echo "  ⚠️  notarization skipped: no dictate-notary profile"
    echo "     (set it up: xcrun notarytool store-credentials dictate-notary --apple-id … --team-id 3BN45AZPR2 --password …)"
fi

# 3.5. Icon on the .dmg file itself (visible locally/AirDrop; HTTP downloads
#      strip the xattr). Applied AFTER stapling so the file is not modified later.
osascript -e 'use framework "AppKit"' \
    -e "set i to current application's NSImage's alloc()'s initWithContentsOfFile:\"$PWD/Sources/AppIcon.icns\"" \
    -e "current application's NSWorkspace's sharedWorkspace()'s setIcon:i forFile:\"$PWD/$DMG\" options:0" >/dev/null \
    && echo "  ✅ icon on the .dmg file"

# 4. Update signing (EdDSA from Keychain) + appcast
"$TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    -o "$OUT/appcast.xml" "$OUT"
echo "  ✅ appcast.xml (EdDSA signature from Keychain)"

# 5. Publishing
if [ "${1:-}" = "--publish" ]; then
    git tag -f "v$VERSION" && git push -f origin "v$VERSION"
    gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" \
        --repo "$REPO" --title "Dictate $VERSION" --generate-notes 2>/dev/null \
      || gh release upload "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --clobber
    echo "  ✅ published: https://github.com/$REPO/releases/tag/v$VERSION"
    echo "  ⚠️  Sparkle will only see the update once the releases repository is public"
else
    echo
    echo "Artifacts in $OUT/. To publish: ./release.sh --publish"
fi