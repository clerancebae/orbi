#!/bin/zsh
# Builds Orbi signed with Developer ID, notarizes it, and publishes a GitHub release.
# Usage: scripts/release.sh            (version = MARKETING_VERSION in project.yml)
#        scripts/release.sh --no-upload (build + notarize only, leaves dist/Orbi-<v>.zip)
#
# One-time setup (see docs/DEVELOPMENT.md → Releasing):
#   - a "Developer ID Application" certificate in the keychain
#   - notary credentials: xcrun notarytool store-credentials orbi-notary \
#       --apple-id <apple id> --team-id <team id> --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${ORBI_NOTARY_PROFILE:-orbi-notary}"
UPLOAD=1; [[ "${1:-}" == "--no-upload" ]] && UPLOAD=0
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM: \([A-Z0-9]*\).*/\1/p' project.yml | head -1)
DIST=dist; ARCHIVE=$DIST/Orbi.xcarchive; APP=$DIST/export/Orbi.app; ZIP=$DIST/Orbi-$VERSION.zip

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No 'Developer ID Application' certificate in the keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "Notary profile '$PROFILE' missing. Run: xcrun notarytool store-credentials $PROFILE ..."; exit 1; }
if (( UPLOAD )) && gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists. Bump MARKETING_VERSION in project.yml."; exit 1
fi

echo "▸ Building Orbi $VERSION (team $TEAM)"
rm -rf $DIST; mkdir -p $DIST
xcodegen generate --quiet
xcodebuild -project Orbi.xcodeproj -scheme Orbi -configuration Release \
  -archivePath $ARCHIVE -derivedDataPath build -allowProvisioningUpdates archive -quiet

cat > $DIST/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $DIST/export \
  -exportOptionsPlist $DIST/ExportOptions.plist -allowProvisioningUpdates -quiet

echo "▸ Notarizing (usually 1–5 min)"
ditto -c -k --keepParent $APP $DIST/notarize.zip
xcrun notarytool submit $DIST/notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple $APP
spctl --assess --type execute -vv $APP   # must say: source=Notarized Developer ID

ditto -c -k --keepParent $APP $ZIP
shasum -a 256 $ZIP
echo "▸ Built $ZIP"

if (( UPLOAD )); then
  gh release create "v$VERSION" $ZIP --title "Orbi $VERSION" --generate-notes
  echo "▸ Published v$VERSION"
fi
