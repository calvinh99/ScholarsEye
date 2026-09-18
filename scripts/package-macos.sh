#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_APP="$PROJECT_ROOT/build/ScholarsEye.app"
DISTRIBUTION_PATH="$PROJECT_ROOT/build/distribution"
ALLOW_LOCAL_TEST_FEED=0
while (( $# )); do
  case "$1" in
    --app) SOURCE_APP="${2:?--app requires an absolute app path}"; shift 2 ;;
    --output-dir) DISTRIBUTION_PATH="${2:?--output-dir requires an absolute directory path}"; shift 2 ;;
    --allow-local-test-feed) ALLOW_LOCAL_TEST_FEED=1; shift ;;
    *) printf 'Usage: %s [--app /path/ScholarsEye.app] [--output-dir /path/output] [--allow-local-test-feed]\n' "$0" >&2; exit 1 ;;
  esac
done
if [[ "$SOURCE_APP" != /* || "$SOURCE_APP" != *.app || "$DISTRIBUTION_PATH" != /* || "$DISTRIBUTION_PATH" == / ]]; then
  printf 'App and output paths must be absolute; app path must end in .app.\n' >&2
  exit 1
fi
DESTINATION_APP="$DISTRIBUTION_PATH/ScholarsEye.app"
if [[ "${SOURCE_APP:A}" == "${DESTINATION_APP:A}" ]]; then
  printf 'The package output must not replace its source app.\n' >&2
  exit 1
fi
if [[ ! -f "$SOURCE_APP/Contents/Info.plist" || ! -x "$SOURCE_APP/Contents/MacOS/ScholarsEye" ]]; then
  printf 'No built app found at %s. Run zsh scripts/build-macos.sh first.\n' "$SOURCE_APP" >&2
  exit 1
fi

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
if [[ ! "$APP_VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]]; then
  printf 'Cannot package app with unexpected version: %s\n' "$APP_VERSION" >&2
  exit 1
fi
ZIP_NAME="ScholarsEye-${APP_VERSION}-macOS-AppleSilicon.zip"

mkdir -p "$DISTRIBUTION_PATH"
STAGING_PATH=$(/usr/bin/mktemp -d "$DISTRIBUTION_PATH/.package.XXXXXX")
trap '/bin/rm -rf "$STAGING_PATH"' EXIT
STAGED_APP="$STAGING_PATH/ScholarsEye.app"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"

# Every portable package uses the receiving Mac's home directory. Explicit
# --app paths permit isolated updater fixtures without leaking development paths.
/usr/bin/python3 - "$STAGED_APP/Contents/Info.plist" "$ALLOW_LOCAL_TEST_FEED" <<'PY'
import base64, plistlib, sys
from pathlib import Path
from urllib.parse import urlsplit

path = Path(sys.argv[1])
allow_local = sys.argv[2] == '1'
info = plistlib.loads(path.read_bytes())
feed, key = info.get('SUFeedURL', ''), info.get('SUPublicEDKey', '')
if bool(feed) != bool(key):
    raise SystemExit('A portable updater requires both its feed URL and public signing key.')
if feed:
    parsed = urlsplit(feed)
    local = parsed.hostname in {'localhost', '127.0.0.1', '::1'}
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise SystemExit('Invalid update feed URL in app bundle.')
    if local and not allow_local:
        raise SystemExit('Refusing to distribute an app with a loopback test feed. Use --allow-local-test-feed only for a local fixture.')
    if parsed.scheme != 'https' and not (allow_local and local and parsed.scheme == 'http'):
        raise SystemExit('Distribution update feeds must use HTTPS.')
    try:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError()
    except ValueError:
        raise SystemExit('Invalid Sparkle public signing key in app bundle.')
    for setting in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
        if info.get(setting) is not True:
            raise SystemExit(f'Distribution updater requires {setting}.')
if info.get('ScholarsEyeAllowsLocalUpdateFeed') and not allow_local:
    raise SystemExit('Refusing to distribute a local-test app.')
isolated_fixture = (
    allow_local and info.get('ScholarsEyeAllowsLocalUpdateFeed') is True
    and info.get('CFBundleIdentifier') == 'com.scholarseye.updatetest'
)
if not isolated_fixture:
    info.pop('ScholarsEyeRecordingsPath', None)
for key in ('ScholarsEyeAnalysisScript', 'ScholarsEyeDevelopmentBuild'):
    info.pop(key, None)
path.write_bytes(plistlib.dumps(info))
PY

# Sign only the host app. Preserve upstream Sparkle framework/helper signatures.
# This remains an ad-hoc signature, not Developer ID signing or notarization.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$STAGING_PATH/$ZIP_NAME"

# Verify the archive's actual extracted payload, including nested signatures and
# framework links, before exposing any generated distribution output.
mkdir "$STAGING_PATH/verify"
/usr/bin/ditto -x -k "$STAGING_PATH/$ZIP_NAME" "$STAGING_PATH/verify"
/usr/bin/codesign --verify --deep --strict "$STAGING_PATH/verify/ScholarsEye.app"
if [[ -e "$STAGED_APP/Contents/Frameworks/Sparkle.framework" && ! -L "$STAGING_PATH/verify/ScholarsEye.app/Contents/Frameworks/Sparkle.framework/Versions/Current" ]]; then
  printf 'Packaged Sparkle framework lost its version symlink.\n' >&2
  exit 1
fi

if [[ -e "$DESTINATION_APP" ]]; then
  /bin/mv "$DESTINATION_APP" "$STAGING_PATH/previous.app"
fi
/bin/mv "$STAGED_APP" "$DESTINATION_APP"
/bin/mv -f "$STAGING_PATH/$ZIP_NAME" "$DISTRIBUTION_PATH/$ZIP_NAME"
printf 'Packaged %s\n' "$DISTRIBUTION_PATH/$ZIP_NAME"
