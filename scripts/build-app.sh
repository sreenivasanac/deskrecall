#!/bin/bash
# Builds DeskRecall.app (menu bar app, no Dock icon), signs it and installs it.
#   scripts/build-app.sh            build, install to /Applications, launch
#   RELEASE=1 scripts/build-app.sh  build for Apple Silicon and Intel, write build/DeskRecall.zip, install nothing.
#                                   With a "Developer ID Application" certificate in the keychain the archive is
#                                   also notarized by Apple and stapled, so it opens without a Gatekeeper warning.
#                                   One-time setup for that (stores an app-specific password in the keychain):
#                                     xcrun notarytool store-credentials deskrecall-notary --apple-id YOU --team-id TEAM
#   INSTALL_DIR=~/Applications SIGN_IDENTITY="My Cert" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DeskRecall"                      # keep in sync with Config.swift
BUNDLE_ID="com.sreenivasanac.deskrecall"
VERSION="0.4.0"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

# macOS ties the Accessibility grant to the code signature. A real identity (even a self-signed
# one) keeps the grant across rebuilds; ad-hoc signing ("-") makes you re-grant every build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # A Developer ID certificate first (the only kind Apple notarizes), else whatever is there.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' 'NF>1{print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

if [ -n "${RELEASE:-}" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
else
  swift build -c release
  BINARY=".build/release/$APP_NAME"
fi
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"    # drawn by scripts/make-icon.swift
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
NOTARY_PROFILE="${NOTARY_PROFILE:-deskrecall-notary}"    # keychain profile made by `notarytool store-credentials`
# Hardened runtime always, so everyday builds behave like the notarized one. No entitlements are
# needed: the app loads only Apple's own frameworks, and Accessibility is a user grant.
SIGN_OPTIONS=(--force --options runtime --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
case "$SIGN_IDENTITY" in "Developer ID Application"*) SIGN_OPTIONS+=(--timestamp) ;; esac    # notarization wants Apple's timestamp
codesign "${SIGN_OPTIONS[@]}" "$APP"
echo "signed with: $SIGN_IDENTITY"

if [ -n "${RELEASE:-}" ]; then
  ZIP="build/$APP_NAME.zip"       # one name for every version, so the "latest release" download link never changes
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"      # ditto keeps the signature intact; plain zip does not
  case "$SIGN_IDENTITY" in
    "Developer ID Application"*)
      xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$APP"             # the ticket travels with the app, so first launch works offline
      rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
      spctl --assess --type execute -v "$APP" ;;
    *) echo "NOT notarized: no Developer ID Application certificate in the keychain; macOS will warn on first launch" ;;
  esac
  echo "release archive: $ZIP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
  exit 0
fi

pkill -x "$APP_NAME" 2>/dev/null || true
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
open "$INSTALL_DIR/$APP_NAME.app"
echo "installed and launched: $INSTALL_DIR/$APP_NAME.app"
