#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholarseye-displays.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/CaptureModels.swift" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/SessionLibrary.swift" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/RecordingDiagnostics.swift" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/CaptureEngine.swift" \
  "$PROJECT_ROOT/tests/DisplayDiscoveryTests.swift" \
  -o "$TEST_DIR/DisplayDiscoveryTests"
"$TEST_DIR/DisplayDiscoveryTests"
