# Session sync implementation — 0.4.0

Manual SSH sync lives in the main Settings page under Master server. Connection settings persist in the local user defaults; no credentials are stored by ScholarsEye. The system SSH client uses the host alias and keys already configured on the sending Mac. See [setup and behavior](SYNC.md).

Sync copies completed recording snapshots in both directions: manifests, original compressed MP4 chunks with their separate audio tracks, and available diagnostics. It does not encode footage again, propagate deletion, or merge conflicting recordings. Hidden staging keeps unfinished downloads out of the sidebar until verification and publication finish.

The app owns one sync task across all windows. CaptureController serializes sync with recording, deletion, and media analysis. The update controller checks the same lock before installing or restarting; sync also checks that update installation has not begun. Quitting cancels the active transfer and waits for its local processes before exiting. Closing the window does not abandon the task.

Computer-use and real MacBook-to-Mini validation are intentionally deferred at the user's request. The user will install this release through the updater and try the transfer from the MacBook. Automated fixture checks exercise transfers and library locking without modifying existing recordings.

Run `zsh scripts/test-session-sync.sh` for native transfer and remote-helper checks, and `zsh scripts/test-session-library.sh` for capture, analysis, deletion, and termination exclusion. The transfer fixtures invoke the system rsync through an isolated local SSH adapter; they exercise file transfer and remote helper commands without making a network connection. This does not verify the MacBook's Tailscale reachability, SSH credentials, or macOS permissions.
