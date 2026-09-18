#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/scholarseye-player.XXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
mkdir -p "$PROJECT_ROOT/build/module-cache"

# Default: generated media only. Explicit arguments opt into existing sessions.
SESSION_ARGS=("$@")
if (( $# == 0 )); then
  /usr/bin/python3 - "$TEST_WORK/session" <<'PY'
import json, pathlib, shutil, subprocess, sys
folder = pathlib.Path(sys.argv[1])
folder.mkdir()
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
chunks = []
for index, (color, offset) in enumerate([('white', 0), ('gray', 4), ('navy', 12)], 1):
    path = folder / ('chunk-%06d.mp4' % index)
    subprocess.run([ffmpeg, '-nostdin', '-v', 'error',
        '-f', 'lavfi', '-i', 'color=c=%s:s=640x360:r=1:d=4' % color,
        '-itsoffset', '0.1', '-f', 'lavfi', '-i', 'sine=frequency=317:sample_rate=48000,volume=0.04',
        '-f', 'lavfi', '-i', 'sine=frequency=977:sample_rate=48000,volume=0.8',
        '-map', '0:v', '-map', '1:a', '-map', '2:a', '-t', '4',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '18',
        '-c:a', 'aac', '-ar:a:0', '24000', '-ac:a:0', '1', '-b:a:0', '48k',
        '-ar:a:1', '48000', '-ac:a:1', '2', '-b:a:1', '96k', str(path)], check=True)
    chunks.append({'id': index, 'fileName': path.name, 'codec': 'h264', 'hardwareAccelerated': False,
        'startOffsetSeconds': offset, 'durationSeconds': 4, 'byteCount': path.stat().st_size,
        'videoFrames': 4, 'droppedVideoFrames': 0, 'droppedAudioSamples': 0,
        'microphoneSamples': 187200, 'systemAudioSamples': 192000})
manifest = {'schemaVersion': 1, 'id': 'synthetic-playback-fixture', 'startedAt': '2026-01-01T00:00:00Z',
    'endedAt': '2026-01-01T00:00:16Z', 'status': 'complete',
    'configuration': {'framesPerSecond': 1, 'maxWidth': 640, 'videoBitrate': 400000, 'codec': 'h264',
        'recordMicrophone': True, 'recordSystemAudio': True, 'chunkDuration': 4},
    'displayID': 1, 'displayWidth': 640, 'displayHeight': 360, 'durationSeconds': 12,
    'bytesWritten': sum(c['byteCount'] for c in chunks), 'chunks': chunks, 'unfinishedFiles': [],
    'events': [{'kind': 'pause', 'atOffsetSeconds': 8}, {'kind': 'resume', 'atOffsetSeconds': 12}]}
(folder / 'manifest.json').write_text(json.dumps(manifest))
PY
  SESSION_ARGS=(--synthetic "$TEST_WORK/session")
fi

/usr/bin/xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/CaptureModels.swift" \
  "$PROJECT_ROOT/apps/macos/ScholarsEye/SessionPlayer.swift" \
  "$PROJECT_ROOT/tests/SessionPlayerTests.swift" -o "$TEST_WORK/SessionPlayerTests"
"$TEST_WORK/SessionPlayerTests" "${SESSION_ARGS[@]}"
