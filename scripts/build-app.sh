#!/bin/bash
# Builds DeskRecall.app (menu bar app, no Dock icon), signs it and installs it.
#   scripts/build-app.sh            build, install to /Applications, launch
#   RELEASE=1 scripts/build-app.sh  build for Apple Silicon and Intel, write build/DeskRecall.zip, install nothing.
#                                   With a "Developer ID Application" certificate in the keychain the archive is
#                                   also notarized by Apple and stapled, so it opens without a Gatekeeper warning.
#                                   One-time setup for that (stores an app-specific password in the keychain):
#                                     xcrun notarytool store-credentials deskrecall-notary --apple-id YOU --team-id TEAM
#                                   A notarized release also rewrites site/appcast.xml, the feed installed copies
#                                   read for updates, with what's new taken from scripts/release-notes.html.
#   INSTALL_DIR=~/Applications SIGN_IDENTITY="My Cert" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DeskRecall"                      # keep in sync with Config.swift
BUNDLE_ID="com.sreenivasanac.deskrecall"
VERSION="0.5.1"
SITE="https://deskrecall.pragnyalabs.com"
REPO="https://github.com/sreenivasanac/deskrecall"
# Sparkle checks every update against this key; the private half is in the login keychain of the
# Mac that makes releases (created once with Sparkle's generate_keys).
UPDATE_PUBLIC_KEY="btTeacgMbZ4ndOwyExmWJ24P1jYqfqpyuQZAnUWM9/E="
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

# macOS ties the Accessibility grant to the code signature. A real identity (even a self-signed
# one) keeps the grant across rebuilds; ad-hoc signing ("-") makes you re-grant every build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # A Developer ID certificate first (the only kind Apple notarizes), else whatever is there.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' 'NF>1{print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

ARCHS=()
[ -z "${RELEASE:-}" ] || ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
PRODUCTS="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"    # the updater
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
  <key>NSHumanReadableCopyright</key><string>© 2026 Sreenivasan AC. MIT licence.</string>
  <key>SUFeedURL</key><string>$SITE/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict></plist>
EOF
NOTARY_PROFILE="${NOTARY_PROFILE:-deskrecall-notary}"    # keychain profile made by `notarytool store-credentials`
# Hardened runtime (and Apple's timestamp) with a Developer ID, as notarization requires. Not
# otherwise: the hardened runtime only loads libraries signed by the same team, and an ad hoc or
# self-signed build has no team, so the app would refuse its own Sparkle framework and not launch.
# No entitlements are needed, and Accessibility is a user grant.
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
case "$SIGN_IDENTITY" in "Developer ID Application"*) SIGN_OPTIONS+=(--options runtime --timestamp) ;; esac
# Inside out, as Sparkle's documentation prescribes: its helpers, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE"
codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID" "$APP"
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
      spctl --assess --type execute -v "$APP"
      # The update feed that installed copies read: this version, signed with the update key.
      # Publish the archive as release v$VERSION before deploying site/, or the feed points at nothing.
      SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP")"    # sparkle:edSignature="…" length="…"
      cat > site/appcast.xml <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$(cat scripts/release-notes.html)]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/$APP_NAME.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
FEED
      echo "update feed: site/appcast.xml" ;;
    *) echo "NOT notarized: no Developer ID Application certificate in the keychain; macOS will warn on first launch" ;;
  esac
  echo "release archive: $ZIP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
  exit 0
fi

pkill -x "$APP_NAME" 2>/dev/null || true
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
open "$INSTALL_DIR/$APP_NAME.app"
echo "installed and launched: $INSTALL_DIR/$APP_NAME.app"
