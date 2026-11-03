#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-env.sh
/usr/bin/xcrun swift test --arch arm64 "${SWIFT_FLAGS[@]}" "$@"

# App-specific UI regressions run alongside the core suite.
mkdir -p .build/menu-layout-checks
/usr/bin/xcrun swiftc -target arm64-apple-macosx26.0 -parse-as-library -swift-version 5 \
  Sources/MeetingNoteTaker/MenuPanel.swift \
  Sources/MeetingNoteTaker/AudioLevelState.swift \
  Sources/MeetingNoteTaker/ShortcutReferenceView.swift \
  Sources/MeetingNoteTaker/OpenSettingsButton.swift \
  Sources/MeetingNoteTaker/MenuPopoverSizing.swift \
  Tests/MenuLayoutChecks/MenuLayoutChecks.swift \
  -o .build/menu-layout-checks/check
.build/menu-layout-checks/check

/usr/bin/xcrun swiftc -target arm64-apple-macosx26.0 -parse-as-library -swift-version 5 \
  Sources/MeetingNoteTaker/ShortcutReferenceView.swift \
  Sources/MeetingNoteTaker/OpenSettingsButton.swift \
  Tests/ShortcutReferenceChecks/ShortcutReferenceChecks.swift \
  -o .build/menu-layout-checks/shortcut-reference
.build/menu-layout-checks/shortcut-reference

mkdir -p .build/shortcut-checks
/usr/bin/xcrun swiftc -target arm64-apple-macosx26.0 -parse-as-library Sources/MeetingNoteTaker/GlobalHotkey.swift Tests/ShortcutChecks/ShortcutChecks.swift -o .build/shortcut-checks/check
.build/shortcut-checks/check
