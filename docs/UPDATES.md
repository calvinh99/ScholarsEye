# App updates

ScholarsEye uses Sparkle 2.10 to verify, install, and relaunch signed updates. Its source and release downloads stay inside the private repository `calvinh99/ScholarsEye`. The app discovers the latest published release through GitHub's authenticated API, then resolves the signed appcast to GitHub's temporary download URL and retrieves the ZIP through its API asset URL. Nothing makes the repository or its releases public.

Updates require a higher build number and user action. Recording files live outside the app bundle and are not replaced. Installation is deferred while a recording is active or saving.

The first updater-enabled release is 0.3.0. Existing 0.2.0 installations need one manual ZIP installation because they do not contain an updater. After that bootstrap, users can update from inside the app. Install the app in Applications rather than launching it from an archive or a read-only disk image.

## Private access on each Mac

Each computer needs a GitHub token belonging to someone who has access to the private repository. Use a fine-grained token restricted to **calvinh99/ScholarsEye**, with **Contents: Read-only** permission. Enter it through the app's update connection settings. The app stores it in that Mac's Keychain; the token is not part of the app bundle, signed feed, ZIP, or recording files.

An expired, revoked, or inaccessible token must be replaced on the affected Mac. A private update feed cannot notify a disconnected or unauthorized installation. The app's update interface reports connection failures without requiring a reinstall.

## Release configuration

`config/release.json` is the source of truth:

- `version`: visible `MAJOR.MINOR.PATCH`, initially `0.3.0`.
- `build`: a strictly increasing positive integer string, initially `"3"`. Sparkle compares this number.
- `githubRepository`: `calvinh99/ScholarsEye`.
- `updateFeedURL`: `https://api.github.com/repos/calvinh99/ScholarsEye/releases/latest`. This is the discovery endpoint; the app resolves the actual `appcast.xml` asset before checking Sparkle.
- `publicEDKey`: this application's Sparkle public signing key.

The signing key and final feed configuration must be set before remote updates work. Configuration placeholders are not usable production feeds. No GitHub access token or private signing key belongs in this file.

## One-time signing setup

The current repository is configured with a generated signing key. Its private seed is stored only in the ignored `.secrets/updates/private.b64` file on the maintainer's Mac and the repository's encrypted `SPARKLE_PRIVATE_KEY` Actions secret. The public key is embedded in `config/release.json`. Keep this same key for subsequent releases and keep an encrypted backup of `.secrets/updates`.

For a new installation of the release tooling, the one-time setup is:

```sh
xcrun swift -module-cache-path build/module-cache scripts/create-update-signing-key.swift
# Copy .secrets/updates/public.b64 into publicEDKey in config/release.json.
gh secret set SPARKLE_PRIVATE_KEY --repo calvinh99/ScholarsEye < .secrets/updates/private.b64
```

The generator reuses an existing key and refuses malformed key material. Never regenerate or commit the private key. The workflow exposes the secret only to its signing step; the publisher passes it through stdin and removes it from child environments. Protect the source repository's main branch and release workflow from untrusted changes: this key authorizes executable updates for installed copies.

EdDSA signatures authenticate both the archive and feed. They are separate from Apple Developer ID signing and notarization. Current releases are ad-hoc code signed, so initial installation may require macOS's **Open Anyway** flow. Developer ID signing/notarization can be added separately.

## Publishing changes

Commit the app changes together with incremented `version` and `build` values in `config/release.json`, then push to `main`. The **Publish macOS update** Actions workflow triggers when that configuration changes. It can also be started manually on `main`. Ordinary source commits without a version bump do not announce a new application version.

The workflow uses GitHub's repository-scoped workflow token to publish into the same private repository. It does not change repository visibility. It:

1. Validates configuration, previous published version/build, and the app's embedded public key/feed.
2. Builds and packages a portable ZIP without developer-machine paths.
3. Generates a signed appcast with Sparkle and independently verifies the archive signature using its configured public key.
4. Creates a **draft** release `vVERSION` and uploads the ZIP first.
5. Reads the ZIP's assigned GitHub asset ID and sets the enclosure to `https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/ASSET_ID`.
6. Re-signs the final appcast with Sparkle and verifies that signature, then uploads it to the draft.
7. Confirms both assets are fully uploaded and publishes the complete release as latest.

The latest-release API excludes drafts. A failed upload or signing step therefore cannot expose an incomplete update. No credential appears in the archive URL. The app supplies authorization only to the configured repository API. Sparkle receives the temporary feed URL without a GitHub token; this also avoids Sparkle overriding the API binary-download Accept header. Archive authorization is attached only in the archive request delegate. A feed API response without the expected GitHub download redirect fails safely with a retryable error.

Already published versions and existing drafts are never overwritten. If a job fails after creating a draft, inspect it, remove it if it is an incomplete unpublished attempt, and rerun. For an already published release, bump version and build again. Actions serializes releases to prevent overlapping publication jobs.

There is no forced background installation or restart. A gold arrow icon appears at the top right when an update is available. Clicking it checks the release feed again, downloads the newest compatible release, and quits/reopens the app. A recording must finish saving before that click can start an update; stopping a recording never triggers installation by itself. Right-click the icon for update details, and click the progress indicator to view or cancel an in-progress download.

## Local preparation without publication

With the intended feed/key configured, build and package, then set `SPARKLE_PRIVATE_KEY` from a secure source and run:

```sh
zsh scripts/publish-update.sh --repo calvinh99/ScholarsEye --prepare-only
```

This signs and verifies staged assets under `build/releases/vVERSION/` and makes no GitHub requests. The private appcast is **not yet a publishable feed**: the ZIP's API asset ID does not exist until upload. The normal publisher replaces the staged enclosure and re-signs it after creating the draft.

The output directory must be fresh to prevent stale archives being mixed into a release. Use `--output /absolute/fresh/directory` to choose another destination. Without `--prepare-only`, this command validates GitHub state and publishes a release; use that mode only when intentionally releasing.

Read-only configuration/history check:

```sh
zsh scripts/publish-update.sh --repo calvinh99/ScholarsEye --check
```

Release guard tests:

```sh
python3 -m unittest discover -s tests -p 'test_update_release.py'
```

The tests cover private API configuration, monotonic versions/builds, exact asset URLs and sizes, draft ordering, upload/signing failure, and secret handling. A local integration check additionally rewrote a real signed Sparkle fixture to a GitHub API asset URL and successfully re-signed and verified it, with GitHub operations mocked and no remote changes. An independent CryptoKit check accepted the genuine archive and rejected tampering.

App installation tests use a separate bundle identifier, disposable recordings directory, temporary signing key, and an explicitly allowed loopback feed. Test keys and loopback URLs must never ship in production; packaging rejects local feeds unless its local-test option is explicitly used.

## Optional public distribution

The publisher also supports a public distribution repository when `githubRepository` is empty and `updateFeedURL` is its standard `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` URL. This is not the current private setup. A separate destination requires the Actions variable `SCHOLARSEYE_RELEASE_REPOSITORY` and a scoped `RELEASE_GITHUB_TOKEN` secret; otherwise the workflow uses its own repository and token. Private destinations always require the authenticated configuration.

## References

- [Sparkle setup and signed feeds](https://sparkle-project.org/documentation/)
- [Sparkle update publishing](https://sparkle-project.org/documentation/publishing/)
- [GitHub release asset API](https://docs.github.com/en/rest/releases/assets)
