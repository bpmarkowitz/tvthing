#!/bin/sh
# Builds the release downloads into dist/. With NOTARY_PROFILE set (an `xcrun notarytool
# store-credentials` keychain profile), the Mac app is signed with your Developer ID,
# notarized by Apple, and stapled, so it opens without Gatekeeper warnings.
#
#   BUILD_DIR=… TEAM=… NOTARY_PROFILE=… mac/Scripts/release.sh
set -eu

BUILD_DIR=${BUILD_DIR:?}
APP="$BUILD_DIR/xcode/Build/Products/Release/TV Thing.app"
TEAM=${TEAM:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}

set -- -project mac/TVThing.xcodeproj -scheme TVThing -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath "$BUILD_DIR/xcode"
[ -n "$TEAM" ] && set -- "$@" DEVELOPMENT_TEAM="$TEAM"
if [ -n "$NOTARY_PROFILE" ]; then
  [ -n "$TEAM" ] || { echo "error: notarizing needs TEAM in Local.mk" >&2; exit 1; }
  set -- "$@" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp
fi
xcodebuild "$@" clean build | grep -E "^\*\* |error:" || true
[ -d "$APP" ] || { echo "error: build failed" >&2; exit 1; }

mkdir -p dist
rm -f dist/*.zip
if [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  rm dist/notarize.zip
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi
ditto -c -k --keepParent "$APP" dist/TV-Thing-mac.zip
cp carthing/dist/TVThing-CarThing.zip dist/TVThing-CarThing.zip
