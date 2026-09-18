#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
APP_PATH="${SCHOLARSEYE_APP_PATH:-$PROJECT_ROOT/build/ScholarsEye.app}"
if [[ "$APP_PATH" != /* || "$APP_PATH" != *.app || "$APP_PATH" == /.app ]]; then
  printf 'SCHOLARSEYE_APP_PATH must be an absolute path ending in .app.\n' >&2
  exit 1
fi

mkdir -p "${APP_PATH:h}" "$PROJECT_ROOT/build/module-cache"
BUILD_PATH=$(/usr/bin/mktemp -d "${APP_PATH:h}/.scholarseye-build.XXXXXX")
trap '/bin/rm -rf "$BUILD_PATH"' EXIT
STAGED_APP="$BUILD_PATH/ScholarsEye.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"

# Validate release configuration before compiling or fetching dependencies.
/usr/bin/python3 - "$STAGED_APP" "$PROJECT_ROOT" <<'PY'
import base64, json, os, plistlib, re, sys
from pathlib import Path
from urllib.parse import urlsplit

app, root = map(Path, sys.argv[1:])
config = json.loads((root / 'config/release.json').read_text())
def value(environment, field):
    return str(os.environ.get(environment, config[field]))
version = value('SCHOLARSEYE_VERSION', 'version')
build = value('SCHOLARSEYE_BUILD_NUMBER', 'build')
feed = value('SCHOLARSEYE_UPDATE_FEED_URL', 'updateFeedURL')
key = value('SCHOLARSEYE_UPDATE_PUBLIC_KEY', 'publicEDKey')
repository = os.environ.get('SCHOLARSEYE_GITHUB_REPOSITORY', config.get('githubRepository', ''))
bundle_id = os.environ.get('SCHOLARSEYE_BUNDLE_ID', 'com.scholarseye.app')
allow_local = os.environ.get('SCHOLARSEYE_ALLOW_LOCAL_UPDATE_FEED') == '1'
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version):
    raise SystemExit('Release version must be a numeric version, such as 0.3.0.')
if not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Build number must be a positive integer and increase for each release.')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
    raise SystemExit('Bundle identifier must use reverse-domain syntax.')
if repository and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+', repository):
    raise SystemExit('GitHub repository must be an owner/repository pair.')
if bool(feed) != bool(key):
    raise SystemExit('Configure both updateFeedURL and publicEDKey, or leave both empty.')
local_feed = False
if feed:
    parsed = urlsplit(feed)
    local_feed = parsed.hostname in {'localhost', '127.0.0.1', '::1'}
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise SystemExit('The update feed URL must have a host, with no credentials or fragment.')
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and local_feed and allow_local):
        raise SystemExit('Update feeds require HTTPS. Loopback HTTP requires SCHOLARSEYE_ALLOW_LOCAL_UPDATE_FEED=1 for testing.')
    if local_feed and not allow_local:
        raise SystemExit('Loopback update feeds require SCHOLARSEYE_ALLOW_LOCAL_UPDATE_FEED=1 for testing.')
    try:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError()
    except ValueError:
        raise SystemExit('The Sparkle public key must be a base64-encoded 32-byte Ed25519 public key.')

recordings = Path(os.environ.get('SCHOLARSEYE_RECORDINGS_PATH', str(root / 'runtime/recordings')))
if not recordings.is_absolute():
    raise SystemExit('SCHOLARSEYE_RECORDINGS_PATH must be an absolute path.')
recordings.mkdir(parents=True, exist_ok=True)
info = {
    'CFBundleName': 'ScholarsEye', 'CFBundleDisplayName': 'ScholarsEye',
    'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'ScholarsEye',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
    'CFBundleIconFile': 'ScholarsEye', 'CFBundleVersion': build,
    'LSMinimumSystemVersion': '15.0', 'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'NSMicrophoneUsageDescription': 'Record your spoken questions and explanations during a learning session.',
    'NSScreenCaptureUsageDescription': 'Record your chosen display to preserve the work from your learning session.',
    'ScholarsEyeRecordingsPath': str(recordings),
    'ScholarsEyeAnalysisScript': str(root / 'scripts/analyze_recording.py'),
    'ScholarsEyeDevelopmentBuild': True,
    # Private GitHub feeds need authenticated asset discovery before each check;
    # the app controls that schedule instead of Sparkle's static-feed scheduler.
    'SUEnableAutomaticChecks': not bool(repository),
    'SUAutomaticallyUpdate': False,
    'SUAllowsAutomaticUpdates': False,
    'SUScheduledCheckInterval': 3600,
    'SUSendProfileInfo': False,
    'SUVerifyUpdateBeforeExtraction': True,
    'SURequireSignedFeed': True,
}
if feed:
    info.update(SUFeedURL=feed, SUPublicEDKey=key)
if repository:
    info['ScholarsEyeGitHubRepository'] = repository
if local_feed and allow_local:
    info['ScholarsEyeAllowsLocalUpdateFeed'] = True
    info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY

SPARKLE_PATH=$(zsh "$PROJECT_ROOT/scripts/fetch-sparkle.sh")
# ditto retains the framework's symlinks, permissions, and upstream helper
# signatures. Never deep-sign Sparkle's bundled installer and XPC services.
/usr/bin/ditto "$SPARKLE_PATH/Sparkle.framework" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  -F "$SPARKLE_PATH" -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$PROJECT_ROOT"/apps/macos/ScholarsEye/*.swift \
  -o "$STAGED_APP/Contents/MacOS/ScholarsEye"

ICON_SOURCE="$PROJECT_ROOT/assets/branding/ScholarsEyeAppIcon.png"
ICON_CACHE="$PROJECT_ROOT/assets/branding/ScholarsEye.icns"
ICONSET_PATH="$PROJECT_ROOT/build/ScholarsEye.iconset"
if [[ "${SCHOLARSEYE_REBUILD_ICON:-0}" == "1" || ! -s "$ICON_CACHE" ]]; then
  /usr/bin/xcrun swift -module-cache-path "$PROJECT_ROOT/build/module-cache" "$PROJECT_ROOT/assets/branding/package-icon.swift"
  mkdir -p "$ICONSET_PATH"
  for ICON_SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_RETINA_SIZE=$((ICON_SIZE * 2))
    /usr/bin/sips -z "$ICON_RETINA_SIZE" "$ICON_RETINA_SIZE" "$ICON_SOURCE" --out "$ICONSET_PATH/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET_PATH" -o "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$STAGED_APP/Contents/Resources/ScholarsEye.icns"
cp "$ICON_SOURCE" "$STAGED_APP/Contents/Resources/ScholarsEyeAppIcon.png"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# Replace only this explicitly selected build output after a successful build.
if [[ -e "$APP_PATH" ]]; then
  /bin/mv "$APP_PATH" "$BUILD_PATH/previous.app"
fi
/bin/mv "$STAGED_APP" "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
