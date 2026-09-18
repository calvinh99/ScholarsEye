#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
SPARKLE_PATH="$PROJECT_ROOT/build/dependencies/Sparkle-2.10.0"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scholarseye-updater.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
if [[ ! -d "$SPARKLE_PATH/Sparkle.framework" ]]; then
  printf 'Fetch the pinned Sparkle dependency before running updater tests.\n' >&2
  exit 1
fi
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  -F "$SPARKLE_PATH" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$SPARKLE_PATH" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/GitHubUpdateSource.swift" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/UpdateController.swift" \
  "$PROJECT_ROOT/tests/UpdateControllerTests.swift" \
  -o "$TEST_DIR/UpdateControllerTests"
"$TEST_DIR/UpdateControllerTests"
