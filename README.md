# ScholarsEye

A native macOS app that turns learning sessions into a small, personalized queue of typed-answer memory problems.

The intended loop is simple: **record → learn normally → stop → review later**. ScholarsEye should remove the work of creating review material. The MVP has no daily review-time budget or new-card admission cap.

The native recording prototype is the current implementation milestone. The architecture and build plan describe the intended system; backend processing, question generation, grading, and scheduling are later milestones, not completed features.

- [Architecture](docs/ARCHITECTURE.md): product behavior, native capture, Mac mini storage/server, model pipeline, grading, scheduling, sync, and costs.
- [Build plan](docs/BUILD_PLAN.md): ordered implementation milestones and acceptance criteria.

Initial scope: one person using several Macs, macOS 15+, with the existing M4 Mac mini storing recordings and coordinating processing. Capture defaults to 1 fps with continuous audio. Storage compression and low recording overhead are core requirements. Idle footage is identified after recording, before expensive model processing; capture does not run idle detection. No Cloudflare R2 or other cloud media archive is required for the MVP.

The first deliverable is a measured recording prototype, followed by one complete record-to-review flow. Every user-facing change must be validated through computer use and a realistic learning journey, alongside checks of the saved media and resource usage. A build passing alone does not establish that recording works.

## Run the recording prototype

On an Apple silicon Mac with macOS 15+ and Apple's Swift command-line tools:

```sh
zsh scripts/build-macos.sh
open build/ScholarsEye.app
```

The development build stores recordings in `runtime/recordings` under this checkout. It requests screen/microphone permission only when starting capture or explicitly choosing a display. Video defaults to hardware HEVC at 1 fps; H.264 and three compression presets are selectable. Microphone and optional system audio are separate AAC tracks.

The native interface uses a monochrome notebook style and a hand-drawn eye. Start a session, pause/resume as needed, then Stop & Save to open it in the built-in player. Playback joins saved chunks, skips manual pause gaps, supports seeking and replay, and lets you mute microphone/system audio independently. Expand the video into a resizable window with native fullscreen controls to inspect small code and maths. Recordings are read directly from disk; playback does not create another permanent video copy. Automatic video-frame OCR is disabled.

New sessions include a compact CPU/RAM panel with duration-weighted averages, observed peaks, and small plots. Native process counters are sampled every five seconds while recording; pauses are excluded and measurements persist in `diagnostics.json`. CPU 100% means one core. RAM is resident memory. These metrics cover the ScholarsEye process, not all system capture/encoder work; power consumption is not displayed. Older sessions show that resource measurements are unavailable. Charts retain at most 240 points while aggregate averages use all valid intervals.

After Stop, the local analysis script checks the saved media and prepares conservative idle candidates. This uses the installed `ffmpeg` and `ffprobe` tools. It preserves originals and does not yet submit recordings to an LLM or automatically remove candidate intervals.

```sh
zsh scripts/test-capture-audio.sh
zsh scripts/test-recording-diagnostics.sh
zsh scripts/test-session-player.sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/analyze_recording.py /absolute/path/to/a/completed/session
```

Generated recordings, build output, and local test media are ignored by `.gitignore`. See [recorder validation](docs/VALIDATION.md) and [interface, playback, and diagnostics validation](docs/NOTEBOOK_UPDATE.md) for measured results and remaining checks. No model API credentials, cloud archive, or server installation is needed for this recorder milestone.

## Install and update

See [installation](docs/INSTALL.md) for the portable Apple silicon ZIP and [updates](docs/UPDATES.md) for private GitHub access and release publishing. Portable copies check at launch and about once an hour, then show an **Update** button. Clicking it installs a signed update and restarts after any recording has finished. Development builds are updated by rebuilding, so automatic installation cannot replace their development storage configuration.

Publishing requires incrementing both version and build in `config/release.json` and pushing to `main`. Source-only commits do not announce an update. The source repository and release downloads stay private.
