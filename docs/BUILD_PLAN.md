# ScholarsEye build plan

This plan starts with one user and the existing Mac mini. Milestones are acceptance gates rather than promised calendar dates. The architecture is described in [ARCHITECTURE.md](ARCHITECTURE.md).

The recorder prototype is the current implementation milestone. Later features below are proposals, not statements of completed work. The MVP records at 1 fps by default, stores footage on the mini, runs idle filtering only after recording, and has no daily review-time budget or new-card admission cap. Compression and low resource usage are core acceptance criteria.

For every user-facing change, use computer control to walk through a realistic user journey in the built app. Pair visible behavior with media/artifact inspection and appropriate resource measurements. Record the exercised steps and results; a successful build is not sufficient validation. Report blocked or unrun scenarios explicitly.

## 0. Establish the project and evaluation baseline

- Establish a native macOS 15+ app with stable bundle identity using the available Swift toolchain; install/select full Xcode when the build or distribution workflow requires it.
- Keep capture, local persistence, review UI, and scheduling separable inside the native app.
- Create one Python backend containing API, worker, schema migrations, and model adapters.
- Define versioned JSON contracts and shared scheduler history fixtures.
- Prepare two or three short representative sessions, using synthetic/non-sensitive material while validating capture and model-provider settings. No cloud storage setup is needed.

Proposed implementation layout:

```text
apps/macos/ScholarsEye/        SwiftUI/AppKit app
packages/CaptureKit/          Stream handling, timestamps, file rotation
packages/LearningCore/        Local models, review logic, scheduler adapter
packages/SyncKit/             SQLite outbox, upload and sync client
services/backend/app/api/     FastAPI endpoints and auth
services/backend/app/worker/  Durable jobs and media preparation
services/backend/app/learning/Extraction, validation, grading, scheduling
services/backend/migrations/ PostgreSQL schema migrations
contracts/                   JSON schemas, API examples, conformance fixtures
evals/                       Non-sensitive fixtures and private-dataset tooling
ops/macos/                   launchd templates and backup/restore procedures
docs/                        Architecture, decisions, measurements
```

Exit: native app launches, backend starts locally, schemas validate, secrets and recordings are excluded from source control.

## 1. Prove low-overhead recording

Build Start/Pause/Stop, source selection, permissions, visible recording state, 1 fps capture, continuous microphone, optional system audio, and one-minute chunk manifests. Record entirely locally on the mini first. Do not add live idle detection. Prefer hardware HEVC if verified to preserve readable evidence with low overhead, and retain an H.264 fallback. Frame-rate tuning can follow the fixed 1 fps default.

Exercise the first real journey with computer use: launch, grant permissions, select a source, start, switch between coding/terminal/math tasks, speak, pause/resume if supported, stop, inspect the resulting session, and play the saved footage/audio. Include a static reading period and an actual break; capture must continue through both unless explicitly paused.

Verify a two-hour representative session, including:

- Legible code, terminal output, and mathematics at candidate resolutions/codecs, comparing HEVC and H.264 file sizes at 1 fps.
- Intelligible audio and measured synchronization across chunk boundaries.
- Flat memory usage, bounded queues, recorded app/system CPU and energy, and measured bytes/hour.
- Force-quit/relaunch recovery, sleep/lock transitions, display changes, and audio-device changes.
- Disk-limit behavior that preserves all existing recordings and stops or pauses visibly; no automatic raw-media deletion.
- Saved codec, dimensions, timing, audio tracks, playable chunks, final manifest, and total on-disk size matching the app's displayed session.

Exit: trustworthy evidence with known costs. Publish actual measurements before selecting default resolution and bitrate. Treat incomplete sessions explicitly.

## 2. Deliver one complete record-to-review flow

Set up PostgreSQL, a private local media directory, one durable worker, and a paid Gemini project on the mini. Read finalized local recordings directly for this milestone. Add manifest verification and processing status; no cloud media bucket or remote-upload prerequisite is needed.

Before model submission, run cheap post-recording audio/screen-change analysis to identify likely idle intervals. Preserve original files and timestamp mappings, exclude only high-confidence breaks, and keep ambiguous static reading/thinking footage. Verify both savings on long breaks and preservation of useful quiet learning.

Implement evidence extraction, consolidation, candidate generation, and validation for constrained short/numeric/code-output questions. Display a few validated questions in the native app, accept typed answers, show concise corrections, and schedule the next review through FSRS. Include basic skip, bad-question reporting, and grade override immediately so the first real loop can recover from an incorrect question or grade. The first processing pass can run against local fixture files before connecting it to the app. Do not add daily review budgets or card admission caps.

Exit: use the native app to record a real session, stop, receive useful source-backed problems, answer them correctly and incorrectly, and see the correct feedback and next due state without editing cards. Inspect the persisted outcomes as well as the UI. Replaying a job does not duplicate problems. Keep a quality inspection switch during development; the intended user flow remains automatic.

## 3. Make daily review worthwhile

Add deduplication against prior sessions, refined grade correction handling, short relearning behavior, and an optional evidence player. Introduce semantic grading only with an uncertainty result and recorded rubric/version. Keep the MVP free of review-time budgets and new-item admission control.

Evaluate at least 30–50 candidate problems from varied sessions. Track factual correctness, ambiguity, useful concept coverage, grading mistakes, acceptance/deletion, review minutes, and actual one-week recall. Any discovered incorrect active answer is a defect to fix; a small sample is not proof of universal correctness.

Exit: most admitted problems are worth reviewing, false-negative grading is uncommon and correctable, and the daily workload stays usable. Weak extraction quality sends work back to the pipeline rather than adding more cards.

## 4. Support a second Mac and server outages

Before remote access, configure private HTTPS through Tailscale and require application device authentication. Add device pairing/revocation, authenticated chunk uploads directly to the mini, transactional outboxes, cached due questions, provisional offline schedules, cursor sync, and versioned reconciliation. Write incoming media to temporary files, verify size/hash, recheck session state, and atomically commit. Serve evidence through authenticated API endpoints; do not introduce presigned URLs. Pin FSRS configurations and verify Swift/Python parity using shared histories.

Use computer control on both Macs to exercise recording/upload, offline answers, duplicate retries, two attempts from the same schedule predecessor, clock changes, an overridden grade, a materially edited problem, and explicit deletion while another device is offline. Kill a worker during a model call and during publication; restart the mini during an upload. Confirm hash-verified files and recoverable incomplete uploads on disk.

Exit: history is preserved, clients converge on the same schedule, no duplicate card publication occurs, deleted data is not resurrected, and outages produce understandable waiting states.

## 5. Operate it reliably on the mini

Harden supervised services, intentional power/reboot behavior, bounded worker concurrency, disk limits, encrypted database backups to a selected separate local/external destination, and a tested restore. Verify private HTTPS and device access rules. Add per-session cost accounting and cleanup of temporary derivatives, abandoned uploads, and temporary provider files. Preserve completed raw footage until explicit user deletion. No automatic archive expiry or cloud backup requirement is part of the MVP.

Package a signed/notarized app for installation on the user's Macs when distributing beyond local development. Keep OS permission onboarding clear and verify the installed build's capture behavior.

Exit: services recover after restart, a backup restores correctly, secrets stay out of logs, and a week of ordinary use does not need developer intervention.

## Later work, justified by measurements

Configurable frame rate and higher-detail capture, safe app exclusion, more displays, optional app/context integrations, symbolic math equivalence, isolated coding exercises, calibrated personalized scheduling, selective cheaper-model routing, and optional migration of media/backend storage to managed hosting. Revisit review workload controls only if actual use warrants them and the user wants them.

Before enabling arbitrary code answers, specify a disposable execution boundary with no host credentials or network, plus CPU/memory/time limits. Before a public multi-user launch, add managed accounts, tenancy verification, service quotas, recovery objectives, and distribution/update infrastructure.

The native recorder spike now exists, with actual computer-use journeys and saved-media checks documented in [VALIDATION.md](VALIDATION.md). Milestone 1 remains open until endurance, recovery, device-change, and compression comparisons pass. The next product milestone is the first complete local record-to-review flow in Milestone 2.
