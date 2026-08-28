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

# Optional local watcher (developer machine only; a clone has no watcher
# and skips this): records whether anything replaces the installed app
# mid-release — evidence for a real incident seen on this machine once.
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

# The owner's personal-only code must never leave this machine. Three layers
# already stop it — the directory is outside the repository, the code compiles
# to nothing without DICTATE_PERSONAL, and release builds never set that flag —
# but every one of those depends on somebody remembering. This one does not:
# it reads the finished binary and refuses to ship if the marker is in it.
if /usr/libexec/PlistBuddy -c "Print :DictatePersonalBuild" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "  ❌ this is a PERSONAL build — refusing to publish"
    exit 1
fi
echo "  ✅ not a personal build"

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

# 3. Notarization — skipped only when the keychain profile is not configured
# (or unreachable). Both DMGs (the branded human download and the plain Sparkle
# payload) are notarized and stapled so Gatekeeper accepts them offline.
# NOTARIZED gates --publish below: a skip (even a transient network failure of
# the profile check) must never end in silently publishing unnotarized DMGs.
NOTARIZED=0
if xcrun notarytool history --keychain-profile dictate-notary >/dev/null 2>&1; then
    for artifact in "$BRANDED_TMP" "$UPDATE_DMG"; do
        echo "==> Notarization: $(basename "$artifact") (may take a few minutes)…"
        SUBMIT_OUT=$(xcrun notarytool submit "$artifact" --keychain-profile dictate-notary --wait 2>&1) \
            || { echo "$SUBMIT_OUT"; echo "  ❌ notarization submit failed"; exit 1; }
        echo "$SUBMIT_OUT"
        # --wait exits 0 even for "status: Invalid" — check the verdict and pull
        # the analysis log, otherwise the flow dies later on stapler with no clue.
        if ! grep -q "status: Accepted" <<<"$SUBMIT_OUT"; then
            SUB_ID=$(grep -m1 -oE 'id: [0-9a-f-]+' <<<"$SUBMIT_OUT" | awk '{print $2}')
            echo "  ❌ notarization not accepted for $(basename "$artifact")"
            [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" --keychain-profile dictate-notary || true
            exit 1
        fi
        xcrun stapler staple "$artifact"
        echo "  ✅ notarized and stapled: $(basename "$artifact")"
    done
    NOTARIZED=1
else
    echo "  ⚠️  notarization skipped: dictate-notary profile missing or unreachable"
    echo "     (set it up: xcrun notarytool store-credentials dictate-notary --apple-id … --team-id 3BN45AZPR2 --password …)"
fi

# 3.5. Icon on the branded .dmg file itself (visible locally/AirDrop; HTTP
#      downloads strip the xattr). create-dmg --volicon already sets the mounted
#      volume's icon; this also stamps the icon onto the .dmg file. Applied AFTER
#      stapling so the notarized file is not modified afterwards (an xattr icon
#      doesn't touch the data fork, so the staple stays valid). Only the branded
#      DMG gets it — the plain update DMG is never seen by a human.
# Cosmetic only — must never abort a release that is already notarized.
if osascript -e 'use framework "AppKit"' \
    -e "set i to current application's NSImage's alloc()'s initWithContentsOfFile:\"$PWD/Sources/AppIcon.icns\"" \
    -e "current application's NSWorkspace's sharedWorkspace()'s setIcon:i forFile:\"$BRANDED_TMP\" options:0" >/dev/null
then echo "  ✅ icon on the .dmg file"
else echo "  ⚠️  couldn't stamp the icon onto the .dmg (cosmetic, continuing)"
fi

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
#
# Written to CONVERGE rather than to run once. A publish is four network calls
# (tag, create, three uploads, flip), and 2026-08-19 proved what a dropped
# connection in the middle leaves behind: the tag pushed, `gh release create`
# died halfway through its uploads, its own cleanup of the half-made release
# ALSO failed, and the fallback `gh release upload` then 404'd — because what
# was left was a DRAFT, and drafts cannot be found by tag. The result was a
# release on GitHub carrying one file of three, invisible to every by-tag
# command, and it had to be finished by hand.
#
# So: find the release including drafts, make sure every asset is there, and
# only then make it visible. Re-running after any failure is now the fix rather
# than a second way to make a mess — each step checks the state it wants and
# skips the work if it already holds.
if [ "${1:-}" = "--publish" ]; then
    if [ "$NOTARIZED" -ne 1 ]; then
        echo "  ❌ refusing to publish: the DMGs are NOT notarized (see the ⚠️ above)."
        echo "     Fix the dictate-notary profile / network and re-run ./release.sh --publish"
        exit 1
    fi
    TAG="v$VERSION"
    ASSETS=("$DMG" "$UPDATE_DMG" "$OUT/appcast.xml")

    git tag -f "$TAG" && git push -f origin "$TAG"

    # Drafts are invisible to /releases/tags/{tag}, which is exactly the hole we
    # fell into — list and match by hand instead.
    release_id() {
        gh api "/repos/$REPO/releases?per_page=100" \
            --jq "[.[] | select(.tag_name == \"$TAG\") | .id] | first // empty" 2>/dev/null
    }

    ID=$(release_id || true)
    if [ -z "${ID:-}" ]; then
        # Created as a DRAFT and with no assets: a release becomes visible in
        # the last step, once its files are actually on it. Nobody should ever
        # meet a "latest release" whose download 404s.
        ID=$(gh api -X POST "/repos/$REPO/releases" \
                -f tag_name="$TAG" -f name="Dictate $VERSION" \
                -F draft=true -F body=@"$NOTES_MD" --jq .id)
        echo "  ✅ draft release created ($ID)"
    else
        echo "  ✅ reusing existing release $ID (draft or published)"
    fi

    # Uploads are the part that actually fails, so they are the part that
    # retries. --clobber makes a re-run replace a half-uploaded asset instead
    # of erroring on the name.
    for asset in "${ASSETS[@]}"; do
        name=$(basename "$asset")
        for attempt in 1 2 3; do
            if gh release upload "$TAG" "$asset" --repo "$REPO" --clobber; then
                break
            fi
            if [ "$attempt" -eq 3 ]; then
                echo "  ❌ could not upload $name after 3 attempts."
                echo "     The release is still a draft — nothing is public. Re-run ./release.sh --publish"
                exit 1
            fi
            echo "  ⚠️  upload of $name failed (attempt $attempt/3) — retrying in 10s"
            sleep 10
        done
    done

    # Belt: ask GitHub what it actually holds, rather than trusting three exit
    # codes. A release published with a missing file is the failure this whole
    # section exists to prevent.
    HAVE=$(gh api "/repos/$REPO/releases/$ID" --jq '[.assets[].name] | sort | join(",")')
    for asset in "${ASSETS[@]}"; do
        case ",$HAVE," in
            *",$(basename "$asset"),"*) ;;
            *) echo "  ❌ $(basename "$asset") is missing from the release after upload."
               echo "     Left as a draft. Re-run ./release.sh --publish"; exit 1 ;;
        esac
    done
    echo "  ✅ all assets present: $HAVE"

    # Only now is it a release. make_latest is explicit because it is NOT the
    # default for an edited draft: 2.6.0 went out with 2.4.0 still wearing the
    # "Latest" badge, which is the badge the README's download link follows.
    gh api -X PATCH "/repos/$REPO/releases/$ID" \
        -F draft=false -F make_latest=true --jq '.html_url' > /dev/null
    STATE=$(gh api "/repos/$REPO/releases/$ID" --jq '"draft=\(.draft)"')
    LATEST=$(gh api "/repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || echo "?")
    if [ "$STATE" != "draft=false" ] || [ "$LATEST" != "$TAG" ]; then
        echo "  ❌ release did not go public cleanly ($STATE, latest=$LATEST)."
        echo "     Re-run ./release.sh --publish"
        exit 1
    fi
    echo "  ✅ published and marked latest: https://github.com/$REPO/releases/tag/$TAG"
    echo "  ⚠️  Sparkle will only see the update once the releases repository is public"
else
    echo
    echo "Artifacts in $OUT/. To publish: ./release.sh --publish"
fi