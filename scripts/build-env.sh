# Shared Xcode 27 toolchain, scoped to this process. Never change xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode_27.1.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
MNT_XCODE_VERSION="$(/usr/bin/xcodebuild -version)" || {
  echo 'Xcode 27 is required. Set DEVELOPER_DIR to its Contents/Developer directory.' >&2
  return 1
}
case "$MNT_XCODE_VERSION" in
  "Xcode 27."*|"Xcode 27"$'\n'*) ;;
  *) echo "Expected Xcode 27; found: $MNT_XCODE_VERSION" >&2; return 1 ;;
esac
MNT_MACOS_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
MNT_CC="$(/usr/bin/xcrun --find clang)"
MNT_CXX="$(/usr/bin/xcrun --find clang++)"
SWIFT_FLAGS=()
if [ -n "${SWIFT_BUILD_JOBS:-}" ]; then SWIFT_FLAGS+=(-j "$SWIFT_BUILD_JOBS"); fi
