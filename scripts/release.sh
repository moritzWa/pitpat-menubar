#!/bin/bash
# Signs with a Developer ID, notarizes, staples, and publishes dist/PitPatBar.zip as a GitHub release.
# Needs APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID in the environment, and `gh` logged in.
#   scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
: "${APPLE_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}" "${APPLE_TEAM_ID:?}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*(${APPLE_TEAM_ID})\)\"/\1/p" | head -1)"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for team $APPLE_TEAM_ID"; exit 1; }

swift test
echo "$VERSION" > VERSION
SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh "$VERSION"

rm -f dist/notarize.zip dist/PitPatBar.zip
ditto -c -k --keepParent dist/PitPatBar.app dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --wait \
  --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
xcrun stapler staple dist/PitPatBar.app
xcrun stapler validate dist/PitPatBar.app
spctl --assess --type execute --verbose=2 dist/PitPatBar.app

ditto -c -k --keepParent dist/PitPatBar.app dist/PitPatBar.zip
gh release create "v$VERSION" dist/PitPatBar.zip --title "PitPat Bar $VERSION" --generate-notes
