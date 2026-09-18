# Notebook interface, playback, and diagnostics

Implemented September 17, 2026. This adds to the native recorder; AI question generation and spaced repetition remain later milestones.

## Interface and identity

- White/gray notebook layout, compact session rows, hand-drawn navigation marks, and reduced explanatory copy.
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
