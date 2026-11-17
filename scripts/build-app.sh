#!/bin/bash
# Builds DeskRecall.app (menu bar app, no Dock icon), signs it and installs it.
#   scripts/build-app.sh            build, install to /Applications, launch
#   INSTALL_DIR=~/Applications SIGN_IDENTITY="My Cert" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DeskRecall"                      # keep in sync with Config.swift
BUNDLE_ID="com.sreenivasanac.deskrecall"
VERSION="0.2.0"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

# macOS ties the Accessibility grant to the code signature. A real identity (even a self-signed
# one) keeps the grant across rebuilds; ad-hoc signing ("-") makes you re-grant every build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' 'NF>1{print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

swift build -c release
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "signed with: $SIGN_IDENTITY"

pkill -x "$APP_NAME" 2>/dev/null || true
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
open "$INSTALL_DIR/$APP_NAME.app"
echo "installed and launched: $INSTALL_DIR/$APP_NAME.app"
