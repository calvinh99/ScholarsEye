#!/bin/zsh
# Build an isolated updater journey. Everything generated stays in ignored runtime/.
set -euo pipefail
umask 077
PROJECT_ROOT="${0:A:h:h}"
FIXTURE_ROOT="$PROJECT_ROOT/runtime/update-test"
SPARKLE_BIN="$PROJECT_ROOT/build/dependencies/Sparkle-2.10.0/bin"
PORT="8768"
REUSE_BUILDS=0

while (( $# )); do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --reuse-builds) REUSE_BUILDS=1; shift ;;
    --help|-h)
      printf 'Usage: zsh scripts/prepare-update-test.sh [--port 8768] [--reuse-builds]\n'
      printf 'Creates signed local update fixtures for com.scholarseye.updatetest, version 0.3.0 → 0.3.1.\n'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
if [[ ! "$PORT" =~ '^[0-9]+$' ]] || (( PORT < 1024 || PORT > 65535 )); then
  printf 'Choose a local test port from 1024 to 65535.\n' >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_BIN/generate_appcast" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
  printf 'Fetch the pinned Sparkle dependency before preparing updater tests.\n' >&2
  exit 1
fi
mkdir -p "$FIXTURE_ROOT/keys" "$FIXTURE_ROOT/recordings" "$FIXTURE_ROOT/server" "$PROJECT_ROOT/build/module-cache"
PRIVATE_KEY="$FIXTURE_ROOT/keys/private-seed.b64"
PUBLIC_KEY_PATH="$FIXTURE_ROOT/keys/public.b64"
/usr/bin/xcrun swift -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  "$PROJECT_ROOT/tests/support/create_update_test_key.swift" "$PRIVATE_KEY" "$PUBLIC_KEY_PATH"
PUBLIC_KEY="$(cat "$PUBLIC_KEY_PATH")"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"

for KIND VERSION BUILD_NUMBER in baseline 0.3.0 3 upgrade 0.3.1 4; do
  TEST_APP="$FIXTURE_ROOT/$KIND/ScholarsEye.app"
  if (( ! REUSE_BUILDS )); then
    SCHOLARSEYE_VERSION="$VERSION" \
    SCHOLARSEYE_BUILD_NUMBER="$BUILD_NUMBER" \
    SCHOLARSEYE_APP_PATH="$TEST_APP" \
    SCHOLARSEYE_BUNDLE_ID=com.scholarseye.updatetest \
    SCHOLARSEYE_RECORDINGS_PATH="$FIXTURE_ROOT/recordings" \
    SCHOLARSEYE_UPDATE_FEED_URL="$FEED_URL" \
    SCHOLARSEYE_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
    SCHOLARSEYE_GITHUB_REPOSITORY='' \
    SCHOLARSEYE_ALLOW_LOCAL_UPDATE_FEED=1 \
      /bin/zsh "$PROJECT_ROOT/scripts/build-macos.sh"
  fi
  # A stale or production app must never silently enter the test fixture.
  /usr/bin/python3 - "$TEST_APP" "$VERSION" "$BUILD_NUMBER" "$FEED_URL" "$PUBLIC_KEY" <<'PY'
import plistlib, sys
from pathlib import Path
app, version, build, feed, public = sys.argv[1:]
info = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
expected = {'CFBundleIdentifier': 'com.scholarseye.updatetest',
            'CFBundleShortVersionString': version, 'CFBundleVersion': build,
            'SUFeedURL': feed, 'SUPublicEDKey': public,
            'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit('Isolated updater fixture has incorrect ' + key + '; rebuild it')
PY
  /bin/zsh "$PROJECT_ROOT/scripts/package-macos.sh" --app "$TEST_APP" \
    --output-dir "$FIXTURE_ROOT/packages/$KIND" --allow-local-test-feed
done

# Prepare independent feeds so the running app can exercise each error without
# changing its preferences, signatures, compiled URL, or any production data.
/usr/bin/python3 - "$FIXTURE_ROOT" "$PORT" <<'PY'
import json, shutil, sys
from pathlib import Path
root, port = Path(sys.argv[1]), int(sys.argv[2])
for scenario, kind, version in [('good', 'upgrade', '0.3.1'), ('no-update', 'baseline', '0.3.0')]:
    folder = root / 'server' / scenario
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir()
    archive = root / 'packages' / kind / ('ScholarsEye-' + version + '-macOS-AppleSilicon.zip')
    shutil.copy2(archive, folder / archive.name)
(root / 'fixture.json').write_text(json.dumps({
    'bundleIdentifier': 'com.scholarseye.updatetest', 'port': port,
    'baselineVersion': '0.3.0', 'baselineBuild': '3',
    'upgradeVersion': '0.3.1', 'upgradeBuild': '4',
    'recordingsDirectory': str(root / 'recordings'),
    'baselineApp': str(root / 'baseline/ScholarsEye.app'),
    'upgradeApp': str(root / 'upgrade/ScholarsEye.app')}, indent=2) + '\n')
PY

for SCENARIO in good no-update; do
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$PRIVATE_KEY" \
    --maximum-deltas 0 --download-url-prefix "http://127.0.0.1:$PORT/" \
    "$FIXTURE_ROOT/server/$SCENARIO"
  "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$PRIVATE_KEY" "$FIXTURE_ROOT/server/$SCENARIO/appcast.xml"
done

/usr/bin/python3 - "$FIXTURE_ROOT" "$SPARKLE_BIN/sign_update" "$PRIVATE_KEY" <<'PY'
import shutil, subprocess, sys
from pathlib import Path
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
root, signer, key = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for scenario in ['tampered-archive', 'bad-feed']:
    destination = root / 'server' / scenario
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(root / 'server/good', destination)
archive = next((root / 'server/tampered-archive').glob('*.zip'))
with archive.open('r+b') as handle:
    offset = archive.stat().st_size // 2
    handle.seek(offset)
    original = handle.read(1)
    handle.seek(offset)
    handle.write(bytes([original[0] ^ 1]))  # Preserve declared content length.
feed = root / 'server/bad-feed/appcast.xml'
content = feed.read_bytes()
# Keep well-formed XML and a detectable edit covered by the embedded signature.
marker = b'<title>'
if marker not in content:
    raise SystemExit('Generated feed did not contain a title')
feed.write_bytes(content.replace(marker, marker + b'Tampered ', 1))
# Check the fixtures themselves before a GUI run: corruption must be rejected by
# the official verifier, and both original archives must remain valid.
for scenario in ['good', 'no-update', 'tampered-archive']:
    folder = root / 'server' / scenario
    enclosure = ET.parse(folder / 'appcast.xml').find('./channel/item/enclosure')
    if enclosure is None:
        raise SystemExit('Generated feed has no update enclosure')
    signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
    target = folder / Path(urlsplit(enclosure.attrib['url']).path).name
    result = subprocess.run([signer, '--verify', '--ed-key-file', key, str(target), signature],
                            capture_output=True, text=True)
    if (result.returncode == 0) != (scenario != 'tampered-archive'):
        raise SystemExit('Unexpected archive signature verification result for ' + scenario)
result = subprocess.run([signer, '--verify', '--ed-key-file', key, str(feed)],
                        capture_output=True, text=True)
if result.returncode == 0:
    raise SystemExit('The bad-feed fixture unexpectedly passed signature verification')
(root / 'scenario.txt').write_text('no-update\n')
print('Prepared updater fixtures: valid archives/feeds verified; both tampered cases rejected.')
print('Initial scenario is no-update.')
print('Launch: ' + str(root / 'baseline/ScholarsEye.app'))
print('Serve: python3 tests/support/serve_updates.py')
print('Switch: python3 tests/support/serve_updates.py --set-scenario good')
PY
