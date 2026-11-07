#!/bin/zsh
# Builds ConfigBox.app into ./build (release, size-optimized) and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
LOG="$(mktemp)"
if ! swift build -c "$CONFIG" >"$LOG" 2>&1; then
  grep -v '^\[' "$LOG"; rm -f "$LOG"; echo "build failed"; exit 1
fi
rm -f "$LOG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ConfigBox"

APP="build/ConfigBox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ConfigBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/" 2>/dev/null || true
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

# TCC grants (Accessibility / Screen Recording) are tied to the code signature. With ad-hoc
# signing they must be re-granted after every rebuild, so prefer a real (self-signed is fine)
# code-signing identity: pass CODESIGN_IDENTITY="Name", or the first valid one is picked up.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi
codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.hayato.configbox "$APP"
echo "Signed with: $CODESIGN_IDENTITY"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
