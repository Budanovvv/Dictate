#!/bin/bash
# Dictate test run: unit tests + build + bundle checks + launch.
#
# ./test.sh          — full run (without the heavy E2E recognition)
# ./test.sh --e2e    — same + end-to-end WhisperKit test (speech synthesis → recognition)
# ./test.sh --quick  — bundle and launch checks only (no rebuild, no unit tests)
set -uo pipefail
cd "$(dirname "$0")"

DD="$HOME/Library/Caches/DictateBuild"
APP="$DD/Build/Products/Release/Dictate.app"
BIN="$APP/Contents/MacOS/Dictate"
PASS=0; FAIL=0

check() {  # check "name" command...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✅ $name"; PASS=$((PASS+1))
    else
        echo "  ❌ $name"; FAIL=$((FAIL+1))
    fi
}

MODE="${1:-full}"

# Graceful quit: an instant pkill can land mid model-download/verify and
# corrupt the model state (see internal/GRABLI.md).
quit_dictate() {
    pgrep -x Dictate >/dev/null || return 0
    osascript -e 'tell application id "com.valentynbudanov.Dictate" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 8); do pgrep -x Dictate >/dev/null || return 0; sleep 0.25; done
    pkill -x Dictate 2>/dev/null || true
}

# ── 1. Project generation and unit tests ───────────────────────────────────
if [ "$MODE" != "--quick" ]; then
    echo "==> xcodegen"
    check "project generates from project.yml" xcodegen generate
    check "DEVELOPMENT_TEAM survived generation" \
        grep -q "3BN45AZPR2" Dictate.xcodeproj/project.pbxproj

    echo "==> Unit tests (XCTest)"
    [ "$MODE" = "--e2e" ] && export DICTATE_E2E=1 && touch /tmp/dictate-e2e
    if xcodebuild test -project Dictate.xcodeproj -scheme Dictate \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
        2>&1 | tee /tmp/dictate-tests.log | grep -E "Test Suite|error:" | tail -5
    then
        if grep -qF "** TEST SUCCEEDED **" /tmp/dictate-tests.log; then
            echo "  ✅ unit tests"; PASS=$((PASS+1))
        else
            echo "  ❌ unit tests (see /tmp/dictate-tests.log)"; FAIL=$((FAIL+1))
        fi
    else
        echo "  ❌ unit tests failed to run"; FAIL=$((FAIL+1))
    fi
    rm -f /tmp/dictate-e2e

    echo "==> Release build"
    if ./build.sh >/dev/null 2>&1; then
        echo "  ✅ build and signing"; PASS=$((PASS+1))
    else
        echo "  ❌ build"; FAIL=$((FAIL+1))
    fi
fi

# ── 2. Bundle checks ───────────────────────────────────────────────────────
echo "==> Bundle: $APP"
check "bundle exists" test -d "$APP"
check "signature is valid (strict)" codesign --verify --strict "$APP"
check "bundle id is correct" \
    bash -c "codesign -dv '$APP' 2>&1 | grep -q 'Identifier=com.valentynbudanov.Dictate'"
check "signed by our Team" \
    bash -c "codesign -dv '$APP' 2>&1 | grep -q 'TeamIdentifier=3BN45AZPR2'"
check "hardened runtime enabled" \
    bash -c "codesign -dv '$APP' 2>&1 | grep -q 'runtime'"
check "microphone entitlement in place" \
    bash -c "codesign -d --entitlements - '$APP' 2>/dev/null | grep -q 'audio-input'"
check "Info.plist: CFBundleIdentifier" \
    bash -c "defaults read '$APP/Contents/Info.plist' CFBundleIdentifier | grep -qx com.valentynbudanov.Dictate"
check "Info.plist: microphone usage description" \
    bash -c "defaults read '$APP/Contents/Info.plist' NSMicrophoneUsageDescription | grep -q ."
check "Info.plist: 12 localizations declared" \
    bash -c "[ \$(defaults read '$APP/Contents/Info.plist' CFBundleLocalizations | grep -c ,) -ge 11 ]"

# No OpenAI traces in the binary, except model identifiers
# (openai_whisper-… model variant, openai/whisper-… WhisperKit constants).
check "no legacy OpenAI strings in the binary" \
    bash -c "! strings '$BIN' | grep -i openai | grep -v 'openai_whisper' | grep -vq 'openai/whisper'"
# The tokenizer must not go into ~/Documents (tokenizerFolder regression)
check "tokenizer path is not in Documents" \
    bash -c "! strings '$BIN' | grep -q 'Documents/huggingface'"
check "no quarantine xattrs on the sources" \
    bash -c "! xattr -lr Sources/ 2>/dev/null | grep -q quarantine"

# ── 3. Localization integrity (independent of unit tests) ─────────────────
echo "==> Localization"
if python3 - <<'PYEOF' >/dev/null 2>&1
import re, pathlib, sys
src = pathlib.Path("Sources")
loc = (src/"Localization.swift").read_text()
used = set()
for f in src.glob("*.swift"):
    if f.name == "Localization.swift": continue
    for m in re.finditer(r'\bLf?\("((?:[^"\\]|\\.)*)"', f.read_text()):
        used.add(m.group(1).replace('\\"','"'))
for name in ["ru","uk","es","pt","fr","de","zh","ja","ko","vi","tl"]:
    m = re.search(rf'static let {name}: \[String: String\] = \[(.*?)\n    \]', loc, re.S)
    keys = {k.replace('\\"','"') for k in re.findall(r'\n        "((?:[^"\\]|\\.)*)":', m.group(1))}
    if used - keys: sys.exit(1)
PYEOF
then echo "  ✅ every key used in code is present in all 11 tables"; PASS=$((PASS+1))
else echo "  ❌ gaps in the localization tables"; FAIL=$((FAIL+1)); fi

# ── 4. Launch: liveness and single instance ────────────────────────────────
echo "==> Launch"
WAS_RUNNING=$(pgrep -x Dictate | head -1 || true)
quit_dictate; sleep 1
open "$APP"; sleep 4
check "process alive after 4 seconds" pgrep -qx Dictate
check "exactly one instance" bash -c "[ \$(pgrep -x Dictate | wc -l) -eq 1 ]"
# A second copy must exit silently, leaving a single process.
"$BIN" >/dev/null 2>&1 &
SECOND=$!; sleep 2
if ! kill -0 $SECOND 2>/dev/null && [ "$(pgrep -x Dictate | wc -l)" -eq 1 ]; then
    echo "  ✅ second instance yielded silently"; PASS=$((PASS+1))
else
    echo "  ❌ second-instance protection"; FAIL=$((FAIL+1)); kill $SECOND 2>/dev/null
fi
# Stop the app if it was not running before the test.
[ -z "$WAS_RUNNING" ] && quit_dictate

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════"
echo "  PASSED: $PASS   FAILED: $FAIL"
echo "════════════════════════════════════"
[ $FAIL -eq 0 ]
