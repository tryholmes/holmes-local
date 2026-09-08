#!/usr/bin/env bash
# Builds Holmes.app (Release), optionally signs + notarizes it with a Developer
# ID, and packages a themed drag-to-Applications DMG.
#
#   scripts/release/build-dmg.sh                       # ad-hoc signed (local / CI without secrets)
#   HOLMES_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
#   HOLMES_NOTARY_PROFILE=holmes-notary \
#   scripts/release/build-dmg.sh                       # signed + notarized + stapled
#
# Environment (all optional):
#   HOLMES_SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc; Gatekeeper will
#                          ask the user to right-click ▸ Open the first time).
#   HOLMES_TEAM_ID         Apple team id, needed with a real identity.
#   HOLMES_NOTARY_PROFILE  `xcrun notarytool store-credentials` profile name. When
#                          set (and the identity is not ad-hoc) the app and the DMG
#                          are notarized and stapled.
#   HOLMES_VERSION         Override the version string (default: MARKETING_VERSION).
#   HOLMES_OUT             Output directory (default: <repo>/dist).
#
# The DMG contains Holmes.app only. The browser extension, the SDK CLI and the
# MCP config are inside the app bundle and installed by Holmes itself on first
# launch (onboarding ▸ Connect your browser / Connect your tools).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$HERE/../.." && pwd)"            # <repo>/holmes
REPO_DIR="$(cd "$PROJ_DIR/.." && pwd)"
OUT="${HOLMES_OUT:-$REPO_DIR/dist}"
WORK="$(mktemp -d /tmp/holmes-dmg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

IDENTITY="${HOLMES_SIGN_IDENTITY:--}"
TEAM_ID="${HOLMES_TEAM_ID:-}"
NOTARY="${HOLMES_NOTARY_PROFILE:-}"
VERSION="${HOLMES_VERSION:-$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJ_DIR/holmes.xcodeproj/project.pbxproj" | head -1)}"
APP_NAME="Holmes"
VOL_NAME="Holmes ${VERSION}"
DMG_NAME="Holmes-${VERSION}.dmg"

log() { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Build Release
# ---------------------------------------------------------------------------
log "Building ${APP_NAME} ${VERSION} (Release, identity: ${IDENTITY})"
DERIVED="$WORK/DerivedData"
SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=${IDENTITY}")
if [[ "$IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
else
  [[ -n "$TEAM_ID" ]] || { echo "HOLMES_TEAM_ID is required with a real signing identity" >&2; exit 2; }
  SIGN_ARGS+=("DEVELOPMENT_TEAM=${TEAM_ID}" "OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime")
fi
(
  cd "$PROJ_DIR"
  set -o pipefail
  xcodebuild -project holmes.xcodeproj -scheme holmes -configuration Release \
             -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
             "${SIGN_ARGS[@]}" build \
    | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
)
APP_SRC="$DERIVED/Build/Products/Release/holmes.app"
[[ -d "$APP_SRC" ]] || { echo "Build failed: $APP_SRC not found" >&2; exit 1; }

STAGE="$WORK/stage"
mkdir -p "$STAGE"
APP="$STAGE/${APP_NAME}.app"
ditto "$APP_SRC" "$APP"

# ---------------------------------------------------------------------------
# 2. Sign (re-sign the renamed bundle so the seal matches) + notarize app
# ---------------------------------------------------------------------------
ENTITLEMENTS="$PROJ_DIR/holmes/Resources/holmes.entitlements"
log "Signing ${APP_NAME}.app"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  # Inner-most first: frameworks/bundles, then the app.
  find "$APP/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) 2>/dev/null \
    | while read -r item; do codesign --force --timestamp --options runtime --sign "$IDENTITY" "$item"; done
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

if [[ -n "$NOTARY" && "$IDENTITY" != "-" ]]; then
  log "Notarizing ${APP_NAME}.app"
  ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------------------
# 3. Themed DMG
# ---------------------------------------------------------------------------
log "Rendering DMG background"
mkdir -p "$STAGE/.background"
BG="$STAGE/.background/background.png"
swift "$HERE/make-dmg-background.swift" "$BG" "$VERSION" || {
  echo "background render failed; continuing with a plain DMG" >&2; rm -f "$BG"; }
ln -s /Applications "$STAGE/Applications"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

RW="$WORK/rw.dmg"
log "Creating DMG"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -ov "$RW"
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/Apple_HFS/ {print $3}')"
[[ -n "$MOUNT_DIR" ]] || { echo "mount failed" >&2; exit 1; }
if [[ -f "$STAGE/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR" || true
fi

# Finder layout: icon view, background picture, app on the left, Applications
# on the right. Best effort — a headless runner without a Finder session just
# ships the DMG unlaid-out.
osascript <<EOF || echo "Finder layout skipped" >&2
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 13
    try
      set background picture of theViewOptions to file ".background:background.png"
    end try
    set position of item "${APP_NAME}.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync
hdiutil detach -quiet "$MOUNT_DIR" || { sleep 2; hdiutil detach -force "$MOUNT_DIR"; }

mkdir -p "$OUT"
FINAL="$OUT/$DMG_NAME"
rm -f "$FINAL"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL"

# ---------------------------------------------------------------------------
# 4. Sign + notarize the DMG
# ---------------------------------------------------------------------------
if [[ "$IDENTITY" != "-" ]]; then
  log "Signing DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$FINAL"
  if [[ -n "$NOTARY" ]]; then
    log "Notarizing DMG"
    xcrun notarytool submit "$FINAL" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$FINAL"
  fi
fi

# A fixed-name copy so a "latest" permalink never needs updating:
#   https://github.com/<org>/<repo>/releases/latest/download/Holmes.dmg
cp -f "$FINAL" "$OUT/Holmes.dmg"
shasum -a 256 "$FINAL" | tee "$FINAL.sha256"
shasum -a 256 "$OUT/Holmes.dmg" > "$OUT/Holmes.dmg.sha256"
log "Done: $FINAL"
if [[ "$IDENTITY" == "-" ]]; then
  echo "NOTE: ad-hoc signed. Users must right-click ▸ Open on first launch (or run: xattr -dr com.apple.quarantine /Applications/Holmes.app)."
fi
