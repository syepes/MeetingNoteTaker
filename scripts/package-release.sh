#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-env.sh
TAG="${1:?Usage: package-release.sh vX.X.X}"
VERSION="$(python3 scripts/release-version.py tag "$TAG")"
APP="$PWD/dist/MeetingNoteTaker.app"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$ACTUAL_VERSION" = "$VERSION" ] || { echo "Bundle version $ACTUAL_VERSION does not match $TAG" >&2; exit 1; }
python3 scripts/validate-platform.py "$APP"
codesign --verify --deep --strict "$APP"
MODE="${RELEASE_SIGNING:-adhoc}"
mkdir -p .build dist
PACKAGE_ROOT="$(mktemp -d "$PWD/.build/release-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
mkdir -p "$PACKAGE_ROOT/assets"
ARCHIVE="MeetingNoteTaker-$TAG-macos-arm64.zip"
case "$MODE" in
  notarized)
    : "${NOTARY_PROFILE:?}"
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    if [ -n "${NOTARY_KEYCHAIN:-}" ]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
    SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
    [[ "$SIGNATURE" == *'Authority=Developer ID Application:'* && "$SIGNATURE" == *'runtime'* ]] || {
      echo 'Notarization requires a Developer ID signature and hardened runtime.' >&2; exit 1;
    }
    ditto "$APP" "$PACKAGE_ROOT/$(basename "$APP")"
    APP="$PACKAGE_ROOT/$(basename "$APP")"
    ditto -c -k --keepParent "$APP" "$PACKAGE_ROOT/notary.zip"
    xcrun notarytool submit "$PACKAGE_ROOT/notary.zip" "${NOTARY_ARGS[@]}" --wait --timeout 30m
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose "$APP"
    SIGNING_NOTE='Developer ID signed and notarized by Apple.'
    ;;
  adhoc)
    SIGNATURE="$(codesign -dv "$APP" 2>&1)"
    [[ "$SIGNATURE" == *'Signature=adhoc'* ]] || { echo 'Ad-hoc packaging requires an ad-hoc build; select the matching release mode.' >&2; exit 1; }
    SIGNING_NOTE='Ad-hoc signed; not notarized by Apple. macOS Gatekeeper may block this build.'
    ;;
  *) echo 'RELEASE_SIGNING must be adhoc or notarized' >&2; exit 1 ;;
esac
ditto -c -k --keepParent "$APP" "$PACKAGE_ROOT/assets/$ARCHIVE"
(cd "$PACKAGE_ROOT/assets" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
cat > "$PACKAGE_ROOT/assets/release-notes.md" <<NOTES
Native macOS menu bar app for Apple Silicon (arm64), macOS 26 or later.

$SIGNING_NOTE

Download \`$ARCHIVE\`, extract it, and move MeetingNoteTaker.app to Applications.
The app starts in the menu bar. Model weights are not included and are downloaded explicitly in Settings.

The attached SHA-256 file can be checked alongside the ZIP with \`shasum -a 256 -c $ARCHIVE.sha256\`.
NOTES
source scripts/replace-directory.sh
replace_directory "$PACKAGE_ROOT/assets" "$PWD/dist/release"
printf 'Packaged: dist/release/%s\n' "$ARCHIVE"
