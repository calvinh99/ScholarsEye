# Sync saved sessions through the Mac mini

ScholarsEye can copy saved sessions in both directions between a Mac's local library and a master folder over SSH. Start the transfer manually from **Settings → Master server**. Capture stays local, so the MacBook can record while away from the mini and sync later. The transfer copies existing compressed files; it does not transcode video or audio.

## Connect the MacBook

Both computers must be online on the same Tailscale network, and SSH (Remote Login) must be enabled on the mini. The mini also needs `/usr/bin/python3` for the transfer helper and `/usr/bin/rsync`; the laptop uses its system SSH and rsync clients and does not need Python for sync. Use the existing `macmini` alias in `~/.ssh/config`. For a new machine, the template is:

```sshconfig
Host macmini
    HostName YOUR_MINI_TAILSCALE_ADDRESS
    User YOUR_MACOS_USERNAME
    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY
    IdentitiesOnly yes
```

The identity file stays on the MacBook. ScholarsEye invokes the system SSH client and uses its existing configuration; it does not store or copy private keys into the app or recording folders. If the key needs a passphrase, unlock it through your normal SSH agent before syncing.

Before the first app sync, verify the connection in Terminal:

```sh
ssh macmini true
ssh macmini /usr/bin/python3 --version
```

For a first connection, verify the mini's host key before accepting it. The app's connection is noninteractive; resolve host-key or authentication prompts in Terminal first.

In ScholarsEye on the MacBook, set the host to `macmini` and the master recordings folder to:

```text
/Users/calvin/ScholarsEye/runtime/recordings
```

This is the folder used by the current development app on the mini. Settings persist on the MacBook. The server field is initially empty so installing the app on another Mac does not connect to a server automatically.

## Choose the correct library

| App | Local recordings folder |
| --- | --- |
| Development app on this Mac mini | `/Users/calvin/ScholarsEye/runtime/recordings` |
| Portable app installed from a ZIP | `~/Movies/ScholarsEye` on that Mac |

Setting the master folder does not merge these two locations on the mini or move existing recordings. The mini's development app reads the master folder directly; it does not need to sync that folder back to itself. A portable app running on the mini uses its separate local library unless explicitly configured otherwise.

Recordings and sync settings are outside the application bundle and survive app updates. The installation ZIP and GitHub releases contain no footage or SSH credentials.

## What sync copies

Only completed sessions with an end time, saved chunks, and no unfinished files are eligible. Live, paused, failed, and interrupted recordings are skipped. Each copied session contains its manifest, the MP4 chunks listed by that manifest, and recorded CPU/RAM diagnostics when available. All microphone and system-audio tracks stay in their original MP4 files. Media-audit reports and other analysis outputs are not transferred or used to decide whether two saved recordings match.

The app inventories both libraries, uploads sessions missing from the mini, and downloads sessions missing from this Mac. Matching sessions are skipped. If the same session ID exists with different recording contents, sync reports a conflict and leaves both existing copies unchanged. It does not select a winner by modification time.

Files transfer into hidden staging folders. Their SHA-256 checksums are verified before the completed session folder is published with an atomic rename. A partially downloaded recording never appears as a playable session in the sidebar. Interrupted transfers do not replace an existing session folder; retry sync after the connection recovers.

Cancelling stops the local transfer processes and waits for them to exit. A session may already have finished publishing on the mini when the connection closes; cancellation does not roll back completed copies. The next sync recognizes matching sessions and resumes staged work. No continuously running sync service is installed on the mini.

Sync does not propagate deletion. Moving a local session to Trash does not remove the mini's copy, and that copy can return on the next sync. Likewise, a copy removed from the mini can be uploaded again from another Mac. This version has no shared Trash, deletion markers, automatic retention policy, or remote deletion command.

## A typical session

1. Record on the MacBook and choose **Stop & save**.
2. Once the session is saved and any local media check has finished, open **Settings → Master server** and start sync.
3. Wait for completion. The session is now stored in the mini's configured folder, and sessions recorded on the mini appear in the MacBook's library.
4. Select a downloaded session in the sidebar and play it normally. Playback uses the local copy and works when the mini is offline.

Finish recording and media checks before syncing. While a transfer is running, recording, local session deletion, new media checks, and update installation are blocked. You can continue browsing saved sessions. Quitting cancels the local transfer and waits for its processes to exit; completed copies remain saved.

Transfers keep copies on both computers and temporarily need space for staging. Sync is not a storage-eviction feature: it does not remove local video after upload or lower its quality. Future model processing and spaced-repetition generation are separate from this transfer feature.

If the mini is offline, reconnect Tailscale and retry. If authentication fails, check the same SSH alias in Terminal; the app does not show a password or private-key passphrase dialog. For an existing host-key mismatch, verify the mini's identity before changing your SSH trust configuration.
