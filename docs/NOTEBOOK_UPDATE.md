# Notebook interface, playback, and diagnostics

Implemented September 17, 2026. This adds to the native recorder; AI question generation and spaced repetition remain later milestones.

## Interface and identity

- White/gray notebook layout, compact session rows, restrained system icons, and reduced explanatory copy. The doodled eye remains the visual signature.
- Childlike crayon eye app icon and scalable native companion mark. The eye blinks briefly about every six seconds while idle, respects Reduce Motion, and stays static during capture.
- Artwork, native icon packaging, and the built-in image-generation prompts are documented in [the branding notes](../assets/branding/README.md).

## Playback

Select a session to play it inside ScholarsEye. Its saved chunks form one recorded-time timeline, with manual pause gaps omitted. Original source offsets remain available in the composition mapping. Play/pause, scrub, skip ten seconds, replay, and independent microphone/system-audio mute controls are included. An expanded native player provides resizing and fullscreen, with the same controls always visible below the video. No extra permanent video copy is generated. Automatic video-frame OCR is disabled.

Switching sessions stops and releases the previous player. Missing/incomplete media gets a clear error. Old HEVC and H.264 sessions remain playable even though they predate resource diagnostics.

## Measured resource usage

CPU is the delta of the process's user+system CPU seconds divided by elapsed active time: **100% equals one core**. Memory is resident bytes from `task_info`. The sampler runs on a separate utility queue every five seconds; no measurement or JSON write runs on the capture callback queue.

The compact panel shows duration-weighted averages, observed peaks, and CPU/RAM plots. Pauses are excluded. Charts retain at most 240 points; aggregate averages use every valid interval. Measurements persist atomically in a separate `diagnostics.json`. Missing samples remain unavailable rather than being converted to zero. Older recordings show that measurements were not collected.

These values cover ScholarsEye's process, including its UI. They exclude separate WindowServer/encoder services, child analysis processes, and power consumption. Watts are not displayed.

## Validation

The native app was operated through computer use: inspecting the redesigned screens, changing quality/display controls, playing older HEVC/H.264 sessions, seeking across a chunk boundary, muting both sources, pausing, skipping, replaying, and switching sessions. A new recording used a native learning document with typed calculus reasoning, crossed the one-minute chunk boundary, paused/resumed, then automatically opened its saved session with a clean media report and CPU/RAM plots. After quitting and relaunching version 0.2.0, the saved measurements remained visible and playback reopened paused at the beginning.

Expanded playback was checked on first opening and in fullscreen: the controls stay visible, play/pause and seeking work, both audio sources can be muted independently, and closing preserves the position and mute choices. Computer use caught and verified fixes for initially hidden native controls and a stale paused frame after closing the expanded window. The final build restored the matching paused frame at 59.293 seconds and continued playing when closed during playback. Switching to an older session while its expanded window was open closed that window and reset playback to the new session without autoplay.

Test session: `2026-09-17T19-49-47Z-7FEF8C43` (local ignored runtime directory).

| Measurement | Result |
| --- | --- |
| Recorded media | 99.497 seconds across three chunks |
| Diagnostics active time | 98.844 seconds; excludes setup/finalization outside sampling |
| CPU | 7.562% average; 10.826% observed interval peak |
| Resident RAM | 123.035 MiB average; 132.391 MiB observed peak |
| Paused time excluded | 49.530 seconds |
| Readings | 23, no measurement or save failures |

Independent calculations from saved intervals reproduced the CPU and RAM averages exactly. The diagnostics file stayed unchanged while paused and after stopping. These short-session measurements are not an endurance or total-system-energy benchmark.

Persistent native tests cover weighted averages, pause exclusion, missing measurements, bounded chart history across 13 simulated hours, native process reads, atomic saves, old-session compatibility, audio boundary preservation, playback composition offsets, missing files, transport behavior, and independent audio mixing. A native decoded-audio check confirmed that mic-only and system-only outputs differ, while both muted produces zero samples' amplitude.

```sh
zsh scripts/test-recording-diagnostics.sh
zsh scripts/test-capture-audio.sh
zsh scripts/test-session-player.sh
```

The playback test generates its own temporary media fixture; optional explicit recording-folder arguments audit existing sessions. Native codec services must be available to the test process. A restricted shell sandbox can produce AVFoundation decoding errors even on known-good source media; the same checks passed with normal host media-service access.

## Session library refinement — September 20, 2026

Sessions are grouped by local calendar day, newest first. Headings show Today, 1d ago through 6d ago, then a date (including the year when needed). Rows show the time, duration, and file size without a document glyph. Labels refresh when the day/time zone changes or the app becomes active.

Settings lives in the sidebar footer, with the recordings-folder shortcut under Storage and the existing compression, codec, and display controls above it. Command-comma also opens Settings. Capture controls lock during recording while the storage shortcut stays available. The highlighted update button occupies the footer's right side.

A session's ellipsis menu and sidebar context menu contain Reveal in Finder and Delete session. Deletion asks for confirmation, moves the whole folder to macOS Trash, and selects a neighboring session. Finder's Put Back restores it. Capture transitions and media analysis block deletion; the controller owns analysis locks so closing a window cannot bypass them. Quitting terminates and waits for active report writers before releasing those locks. Only direct library child directories with matching manifests may be trashed; symbolic links and unsafe paths are rejected.

The app icon uses the same crayon eye on a subtle beige tile. The original white artwork remains in the repository alongside the image-generated beige edit.

Computer-use validation used an isolated library of copied sessions spanning Today, recent days, a week ago, and the previous year. Verified Settings and its Finder shortcut, playback, cancelling deletion, moving a playing session to Trash, automatic selection/player reset, and recovery with Finder Put Back. A short capture was paused and saved with a successful media check; the session context menu disabled Delete while paused. A controlled media check also disabled Delete until completion. An older-version test build discovered the actual public release and showed the gold update icon in the new footer position. A final quit-during-analysis journey confirmed the child process exited and the existing report stayed unchanged. Hashes of all 31 pre-existing recording files remained unchanged.

Regression checks: `scripts/test-session-library.sh` covers calendar/DST boundaries, safe Trash targets, manifest identity, shared analysis locks, and real child-process shutdown; capture-audio, session-player, and updater suites pass. The playback suite needs access to the host's native codec services.

## Full-page settings and direct recording — September 20, 2026 (0.3.4)

Settings is a destination inside the main window, with grouped native display/audio, quality, and storage controls. Command-comma opens it; the Sessions heading and saved rows return to the library. Audio, codec, compression, and explicit display choices persist across launches.

The recording page is removed. Record lives in the window header on every page and starts capture directly. During capture it becomes a compact status, fixed-width HH:MM:SS timer, Pause/Resume, and Stop & Save. Only the time label schedules a one-second redraw; elapsed interpolation uses ContinuousClock and pauses use the captured duration. The footer retains live average CPU/RAM, small plots, and saved size. Settings and older sessions remain browsable; starting and stopping preserve the current page. A first saved session opens automatically when the library was empty.

Display discovery runs automatically at launch, on activation, in Settings, and after recording stops. Before screen permission is granted, NSScreen supplies connected display choices without prompting. Actual capture-source discovery happens with permission; each Record action refreshes sources so an old display object is not reused. Concurrent refresh/start actions share discovery, valid selections are retained, and failures remain visible.

Computer-use validation covered: first opening with a preselected Gigabyte M32U and no Choose step; an immediately usable picker; Compact/system-audio preference changes surviving relaunch (then restored); one-click recording from Settings; browsing an older session during capture; timer advancement, frozen pause, resume, locked capture settings, and stopping without leaving Settings. That 50-second session saved two chunks, passed its media check, and appeared in the library. A fresh bundle with no recording permission still showed the display picker and an access note without requesting access on launch. A separate empty-library journey with the final build recorded, paused, saved, automatically selected the first session, and played it successfully. All existing user recording hashes stayed unchanged.

`zsh scripts/test-display-discovery.sh` covers permission-free inventory, preference persistence, fallbacks, errors, and concurrent refresh/Record behavior. Existing capture-audio and session-library/analysis-lifecycle checks also pass. The new discovery tests run in the release workflow.
