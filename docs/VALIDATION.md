# Recording prototype validation

These notes distinguish actual computer-use journeys from synthetic checks. The full learning/problem/scheduling backend is not implemented yet. The two-hour acceptance gate in the build plan has not passed merely because shorter tests succeeded.

## Actual native journey — September 16, 2026

Built the Apple silicon macOS app with Apple's Swift 6.2.4 toolchain, targeting macOS 15. Launched the application through computer use and inspected its actual UI.

Exercised Start with microphone and system audio enabled, switched to a native TextEdit document containing Python code and mathematical notation, typed a mistaken prediction and its correction, played known synthetic speech through QuickTime, paused, resumed, added a final recall answer, and stopped. Opened the saved session in the app, inspected automatic post-recording analysis, opened its folder, played an HEVC chunk in QuickTime, quit, and relaunched the app. The saved session remained in the library.

macOS permission dialogs needed user interaction: the computer-use tool cannot control the system permission-dialog app. The user approved recording permissions. A secondary direct-screen-access notice is visible in part of the first recording. This limits the uncluttered visual-quality sample; it does not invalidate the media integrity checks. The browser tool blocked the local HTML fixture, so the actual journey used a local TextEdit document instead.

The first recorded session is `2026-09-16T16-45-50Z-404C8AF4` in the ignored `runtime/recordings` directory.

| Check | Observed result |
| --- | --- |
| Recorded time | 245.864 seconds, excluding the pause |
| Files | Five finalized MP4 chunks plus manifest and analysis report |
| Video | Hardware HEVC, 1920 × 1080, 248 decoded frames |
| Audio | Separate AAC microphone and system-audio streams in every chunk |
| Media size | 6,874,307 bytes; approximately 100.7 MB/hour if this workload continued |
| Integrity | Full decoding succeeded for all video/audio tracks; frame counts and byte sizes matched the manifest |
| Reported dropped samples | Zero video frames and zero audio samples in this run |
| Pause | 27.746 seconds of media gap retained in the source timeline |
| System audio | Recorded narration matched the known source envelope with 0.9814 correlation |
| Microphone | Stream and distinct signal verified; intelligibility requires a known live spoken sample |
| Idle candidates | None for this active journey; the manual pause remained outside recorded intervals |

A 12-sample, roughly one-minute process measurement during this recording found 106.3–109.2 MiB resident memory and CPU averaging 5.37% of one core (range 4.5–9.9%). These figures cover the app process, not all WindowServer/encoder work or total system energy. They are not two-hour endurance measurements.

Review after this run identified transition/termination and late-audio boundary cases needing additional handling. The initial zero-drop counters alone cannot prove absence of every boundary omission. Follow-up verification is recorded below.

## Follow-up native journeys

The next build captured the selected display at 2560 × 1440 using its physical pixel scale. Computer use verified that the earlier session's saved analysis and measured storage estimate persisted across relaunch. A second learning journey included typed calculus notes, spoken audio playback, a one-minute chunk boundary, Pause/Resume, and both quit choices: Keep Recording continued capture; Stop and Quit finalized the session before exiting. Relaunch showed a complete session with no unfinished files. Its three HEVC chunks decoded successfully, with 104 frames, both AAC tracks, 102.698 seconds of recorded time, and 6,266,118 bytes (219.7 MB/hour for this workload).

This journey exposed a real stereo-audio boundary defect: one 960-sample system-audio packet (20 ms at 48 kHz) was dropped because CoreMedia's sample-range copy does not support non-interleaved audio. The new counters and post-analysis surfaced the loss, and idle omission remained disabled. The fix copies channel planes correctly; final verification below distinguishes the corrected recording from this diagnostic run.

A separate short computer-use journey selected Compact and H.264, recorded the learning document with microphone audio, stopped, and inspected the completed session. The saved report completed without warnings. This verifies the selectable codec path, not a controlled HEVC-versus-H.264 quality comparison.

With planar PCM copying corrected, session `2026-09-17T01-54-54Z-3EC68B7D` saved 90.958 seconds in two HEVC chunks: 91 frames, both audio tracks, and 3,635,950 bytes (143.9 MB/hour). All tracks decoded. System audio contributed exactly 2,880,000 source samples to the first 60-second chunk, with the next chunk starting at zero; container timing differed by only 42 microseconds. Microphone sample counts account for its approximately 214 ms startup offset. No boundary loss was evident. A 290-sample warning remained consistent with startup alignment, prompting separate explicit accounting for samples outside the recorded interval.

An actual decoded frame from this session showed legible Python closures and corrections, matrix entries, subscripts, powers, partial derivatives, and an integral in the native TextEdit fixture. The test explicitly raised that window onto the recorded display. Eight process samples during this 1440p recording showed CPU averaging 6.65% of one core (5.6–7.5%) and resident memory of 96.1–110.9 MiB. This exceeds the initial aspirational 5% app-CPU target; system energy and a two-hour run remain unmeasured. It is not a comparative codec benchmark.

## Final build verification

The final native journey, `2026-09-17T02-01-23Z-C4A5B425`, exercised Start with both audio sources, typed recall in TextEdit, a full one-minute chunk boundary, speech playback, Pause/Resume, Stop & Save, and the saved-session page. Computer use verified a clean UI throughout and an automatic **Media checked** result with no warnings. The previous 1440p clip was also opened, sought, and played in QuickTime through computer use.

| Final recording check | Result |
| --- | --- |
| Recorded time | 115.813 seconds |
| Format | Hardware HEVC, 2560 × 1440, 1 fps |
| Media | Three finalized chunks, 117 video frames, separate microphone/system AAC tracks |
| Size | 4,109,834 bytes; projected 127.8 MB/hour for this workload |
| Capture loss | Zero dropped video frames and zero dropped audio samples |
| Startup alignment | 849 samples explicitly accounted for before the recorded segment; not hidden as in-window loss |
| First chunk system audio | Exactly 2,880,000 source samples for 60 seconds |
| Post-recording report | Complete, no warnings; originals retained |
| Independent integrity audit | All three video streams and six audio streams fully decoded; byte/frame totals matched; 9.278-second pause gap preserved |

The optional alignment counter preserves compatibility with older manifests. It only classifies samples proven to precede the initial/resumed segment; late audio inside a recorded interval still counts as loss. These short runs validate the implemented controls and corrected boundary handling. They do not close the endurance and failure-testing gates below.

## Synthetic checks

- A direct encoder check using the native writer produced five seconds of hardware HEVC at exactly 1 fps, with continuous PCM converted to mono AAC. File duration and frame count matched. The input was a flat image and silence, so its tiny output size is not a realistic compression estimate.
- Native PCM regression tests exercise the actual boundary-copy helper with mono interleaved, stereo interleaved, and stereo non-interleaved Float32 buffers. They verify every channel's data, sample counts, timestamps, exact/fractional boundaries, and the real 925/35 split that exposed the system-audio defect. Run `zsh scripts/test-capture-audio.sh`.
- Alignment tests distinguish proven audio preroll before initial/resumed capture from late data inside a capture segment. Invalid/unknown timing still counts as loss. Existing manifests decode without the new optional alignment counter. A segment start remains fixed across chunk rotations, so an expired handoff cannot conceal late audio as startup trimming.
- Bounded synthetic controller checks verified that deferred capture failure finalizes a failed manifest and that Stop and Quit waits through an in-flight transition. These complement the actual safe-quit journey; they do not establish every OS failure path.
- Eight media-analysis integration tests passed: unchanged silent video and preserved margins, active/missing/multiple audio, matching static images across chunk boundaries, screen changes, pause gaps, dropped audio, incomplete/corrupt/missing files, CLI error reporting, and the production three-minute threshold with 30-second margins. The test suite verifies that original media hashes stay unchanged.
- The idle analysis only proposes candidates. It does not yet delete footage or send a shortened input to a model. Identical-frame matching deliberately keeps footage with uncertain visual changes, including some clocks and cursors.

## Outstanding acceptance work

- Two-hour resource/energy/endurance run and representative size comparisons across compression profiles.
- Controlled live speech to verify microphone intelligibility and synchronization by ear.
- Force-quit recovery, sleep/lock and device-change behavior, low-disk failure, and encoder/storage fault injection.
- Second-Mac transport, authenticated server, model extraction, generated problems, grading, and FSRS review are later milestones and have not been tested.
