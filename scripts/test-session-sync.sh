#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholarseye-sync-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/CaptureModels.swift" \
  "$PROJECT_ROOT"/apps/macos/ScholarsEye/SessionSync*.swift \
  "$PROJECT_ROOT/tests/SessionSyncTests.swift" -o "$TEST_DIR/SessionSyncTests"
"$TEST_DIR/SessionSyncTests"
cd "$PROJECT_ROOT"
/usr/bin/python3 -m unittest discover -s tests -p 'test_sync_helper.py'
