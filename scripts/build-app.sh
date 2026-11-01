#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${1:-${CONFIGURATION:-release}}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Configuration must be debug or release" >&2; exit 1 ;; esac
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
source scripts/build-env.sh
case "${RELEASE_SIGNING:-adhoc}" in
  adhoc) [ "${SIGNING_IDENTITY:--}" = - ] || { echo 'Ad-hoc builds require SIGNING_IDENTITY=-.' >&2; exit 1; } ;;
  notarized) [[ "${SIGNING_IDENTITY:-}" == 'Developer ID Application: '* ]] || { echo 'Notarized builds require a Developer ID Application identity.' >&2; exit 1; } ;;
  *) echo 'RELEASE_SIGNING must be adhoc or notarized.' >&2; exit 1 ;;
esac
bash scripts/build-native.sh
/usr/bin/xcrun swift build --arch arm64 -c "$CONFIGURATION" "${SWIFT_FLAGS[@]}"
BIN_DIR="$(/usr/bin/xcrun swift build --arch arm64 -c "$CONFIGURATION" --show-bin-path)"
FINAL_APP="$PWD/dist/MeetingNoteTaker.app"
PACKAGE_ROOT="$(mktemp -d "$PWD/.build/app-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
APP="$PACKAGE_ROOT/MeetingNoteTaker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/MeetingNoteTaker" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/release-version.py stamp "$APP/Contents/Info.plist"
cp build/helpers/whisper-worker build/helpers/whisper-cli build/helpers/llama-server "$APP/Contents/Helpers/"
cp build/licenses/* "$APP/Contents/Resources/Licenses/"
cp .build/checkouts/FluidAudio/LICENSE "$APP/Contents/Resources/Licenses/FluidAudio-LICENSE"
cp .build/checkouts/swift-markdown/LICENSE.txt "$APP/Contents/Resources/Licenses/swift-markdown-LICENSE.txt"
cp .build/checkouts/swift-markdown/NOTICE.txt "$APP/Contents/Resources/Licenses/swift-markdown-NOTICE.txt"
cp .build/checkouts/swift-cmark/COPYING "$APP/Contents/Resources/Licenses/swift-cmark-COPYING"
for resource in "$BIN_DIR"/*.bundle; do
  [ -e "$resource" ] || continue
  cp -R "$resource" "$APP/Contents/Resources/"
done
SIGNING_ARGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != - ]; then SIGNING_ARGS+=(--timestamp); fi
for helper in "$APP/Contents/Helpers/"*; do
  codesign "${SIGNING_ARGS[@]}" "$helper"
done
codesign "${SIGNING_ARGS[@]}" --entitlements Resources/Entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/validate-platform.py "$APP"
mkdir -p "$PWD/dist"
source scripts/replace-directory.sh
replace_directory "$APP" "$FINAL_APP"
echo "Built $FINAL_APP"
