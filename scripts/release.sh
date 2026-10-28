#!/bin/zsh
# Builds Scout for Apple silicon, signs it with Developer ID, notarizes it,
# packages it into a DMG and (optionally) publishes a GitHub release.
#
# Usage:
#   scripts/release.sh [version] [--publish] [--no-notarize]
#
#   version        Marketing version, e.g. 1.0.0 (defaults to MARKETING_VERSION in the project)
#   --publish      Create a GitHub release "v<version>" with the DMG attached (uses gh)
#   --no-notarize  Skip notarization (the app will only run on this Mac without Gatekeeper warnings)
#
# Signing uses the Xcode account for team $TEAM_ID with automatic signing
# (-allowProvisioningUpdates), so no certificates or passwords are needed in this script.
# Alternatively set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID to use an App Store Connect API key (CI).

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=${TEAM_ID:-6H56BMGV4C}
APP=Scout
PUBLISH=0
NOTARIZE=1
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    -*) echo "Unknown option $arg" >&2; exit 1 ;;
    *) VERSION=$arg ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION=$(xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')
fi
BUILD_NUMBER=$(git rev-list --count HEAD)
OUT=build/release
ARCHIVE=$OUT/$APP.xcarchive
EXPORT=$OUT/export
DMG=$OUT/$APP-$VERSION-arm64.dmg

AUTH=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

step() { print -P "\n%F{blue}==>%f %B$1%b" }

rm -rf $OUT
mkdir -p $OUT

step "Archiving $APP $VERSION ($BUILD_NUMBER) for arm64"
xcodebuild archive \
  -project $APP.xcodeproj -scheme $APP -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $ARCHIVE \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER \
  DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGN_STYLE=Automatic \
  "${AUTH[@]}" -quiet

export_options() {
  cat > $OUT/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>$1</string>
</dict>
</plist>
EOF
}

if (( NOTARIZE )); then
  step "Signing with Developer ID and uploading to Apple for notarization"
  export_options upload
  xcodebuild -exportArchive -archivePath $ARCHIVE -exportOptionsPlist $OUT/ExportOptions.plist \
    -exportPath $OUT/upload "${AUTH[@]}" -quiet

  step "Waiting for notarization (usually a few minutes)"
  for attempt in {1..60}; do
    if xcodebuild -exportNotarizedApp -archivePath $ARCHIVE -exportPath $EXPORT "${AUTH[@]}" > $OUT/notarize.log 2>&1; then
      echo "Notarized."
      break
    fi
    if grep -qiE "invalid|rejected" $OUT/notarize.log; then
      cat $OUT/notarize.log >&2
      echo "Notarization was rejected." >&2
      exit 1
    fi
    (( attempt == 60 )) && { cat $OUT/notarize.log >&2; echo "Timed out waiting for notarization." >&2; exit 1; }
    sleep 30
  done
else
  step "Signing with Developer ID (not notarized)"
  export_options export
  xcodebuild -exportArchive -archivePath $ARCHIVE -exportOptionsPlist $OUT/ExportOptions.plist \
    -exportPath $EXPORT "${AUTH[@]}" -quiet
fi

APP_PATH=$EXPORT/$APP.app
step "Verifying signature"
codesign --verify --deep --strict --verbose=2 $APP_PATH
codesign -dv $APP_PATH 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime" || true
lipo -archs $APP_PATH/Contents/MacOS/$APP
if (( NOTARIZE )); then
  xcrun stapler validate $APP_PATH
  spctl --assess --type execute --verbose=2 $APP_PATH
fi

step "Creating $DMG"
STAGING=$OUT/dmg
mkdir -p $STAGING
ditto $APP_PATH $STAGING/$APP.app
ln -s /Applications $STAGING/Applications
hdiutil create -volname "$APP $VERSION" -srcfolder $STAGING -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov $DMG >/dev/null
rm -rf $STAGING

# Sign and notarize the disk image itself when a local Developer ID certificate and a
# notarytool keychain profile are available (the app inside is already notarized and stapled).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -n "$IDENTITY" ]]; then
  step "Signing the disk image with $IDENTITY"
  codesign --sign "$IDENTITY" --timestamp $DMG
  if [[ -n "${NOTARY_PROFILE:-}" ]] && (( NOTARIZE )); then
    xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $DMG
  fi
fi

shasum -a 256 $DMG | tee $DMG.sha256
ls -lh $DMG

if (( PUBLISH )); then
  TAG=v$VERSION
  step "Publishing GitHub release $TAG"
  NOTES=$OUT/notes.md
  {
    echo "Scout $VERSION for Apple silicon Macs (macOS 15 or later)."
    echo
    echo "Download **$(basename $DMG)**, open it and drag Scout to Applications."
    (( NOTARIZE )) && echo "The app is signed with Developer ID and notarized by Apple."
    echo
    echo "SHA-256: \`$(cut -d' ' -f1 $DMG.sha256)\`"
  } > $NOTES
  if gh release view $TAG >/dev/null 2>&1; then
    gh release upload $TAG $DMG --clobber
  else
    git push origin HEAD
    gh release create $TAG $DMG --title "Scout $VERSION" --notes-file $NOTES --target "$(git rev-parse HEAD)"
  fi
  gh release view $TAG --json url --jq .url
fi
