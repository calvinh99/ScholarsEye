# Install ScholarsEye on another Mac

Requires an **Apple silicon Mac (M1 or newer) running macOS 15 or later**. This build does not run on Intel Macs.

1. AirDrop the latest `ScholarsEye-<version>-macOS-AppleSilicon.zip` to your laptop, or download it from the public [GitHub releases](https://github.com/calvinh99/ScholarsEye/releases).
2. Double-click the ZIP, then move `ScholarsEye.app` into **Applications**.
3. Open ScholarsEye. Approve screen recording and microphone access when requested; each Mac needs its own permissions. If macOS requests a restart, quit and reopen the app.

This personal development build is ad-hoc signed and has not been notarized by Apple. If macOS blocks the first launch, follow Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445) in **System Settings → Privacy & Security** for this app.

Recordings are saved on that Mac in `~/Movies/ScholarsEye`. The ZIP contains the app only; your existing recordings are not included. Recording, in-app playback, and CPU/RAM diagnostics require no Python, FFmpeg, or other installations.

Versions **0.3.2 and later** use public update downloads, with **no GitHub account or token required**. Install a current ZIP manually once over 0.3.0/0.3.1: those older builds still expect a private-repository token even after the repository becomes public. Your saved sessions live outside the app and remain in place.

The update icon beside Settings in the sidebar footer turns gold when a release is available. Nothing installs until you click it. That click checks for the latest release, downloads and verifies it, then quits and reopens the app. Finish and save any recording before clicking; the app never queues an automatic restart for the end of a recording. See [update publishing](UPDATES.md).

To share saved sessions with the Mac mini, install **0.4.0 or later**, configure **Master server** in Settings, and choose **Sync now**. On the MacBook, use the existing SSH host alias `macmini` and the mini's recordings folder, `/Users/calvin/ScholarsEye/runtime/recordings`. See [master server setup](SYNC.md) for prerequisites and transfer behavior. The app keeps its own local recordings folder; setting a master server does not redirect live capture onto the network.

Automatic model analysis and review-card generation are not implemented yet. The developer's media-audit and idle-candidate helper stays on the Mac mini and is not included in this portable package.

## Create the ZIP on the development Mac

After building the app, run from the ScholarsEye project directory:

```sh
zsh scripts/package-macos.sh
```

The ZIP and portable app appear in `build/distribution/`. Packaging removes development-only storage and analysis paths from the copy, re-signs it, and verifies the signature. It does not alter `build/ScholarsEye.app` or include footage, source code, or the runtime folder. Re-running replaces only the generated distribution app and the ZIP for that version.

## Package verification

The September 17, 2026 ZIP was extracted into a separate folder and launched through computer use on the Mac mini. A fresh session recorded, paused, saved to `~/Movies/ScholarsEye`, displayed persisted CPU/RAM measurements, and played with seeking. Its manifest is complete. ZIP integrity and the extracted app's signature passed; no recordings or development paths were included. This verifies the portable layout on the Mac mini, not installation on the MacBook or every supported macOS version. The portable app correctly reports “Media check unavailable” for the optional developer helper.
