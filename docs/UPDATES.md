# App updates

ScholarsEye uses Sparkle 2.10 to verify, install, and relaunch signed updates. Version 0.3.2 and later use the public release feed in `calvinh99/ScholarsEye`. Users need no GitHub account, connection step, or access token. Both the app ZIP and update feed are signed with the same release key used by earlier versions.

The app checks at launch and about once an hour. A gold arrow appears at the top right when an update is available. Clicking it checks the feed again, downloads the newest compatible release, and quits/reopens the app. A recording must finish saving before that click can start an update; stopping a recording never starts installation automatically. Right-click the icon for details, and click the progress indicator to view or cancel a download.

## Moving from private updates

Install the 0.3.2 ZIP manually once over 0.3.0 or 0.3.1. Older copies still have the private-repository configuration and will ask for a token even if the repository is public. The new app has no private-repository identifier in its bundle, does not read an update token from Keychain, and enables public background checks even when an earlier private build disabled Sparkle's scheduler. Saved recordings remain outside the app bundle.

## Release configuration

`config/release.json` is the source of truth:

- `version`: visible `MAJOR.MINOR.PATCH`.
- `build`: a strictly increasing positive integer string used by Sparkle.
- `githubRepository`: empty for public, unauthenticated downloads.
- `updateFeedURL`: `https://github.com/calvinh99/ScholarsEye/releases/latest/download/appcast.xml`.
- `publicEDKey`: the stable public signing key embedded in the app.

The repository must be public before publishing this configuration. The publisher checks visibility and rejects an unauthenticated feed targeting a private repository. It also rejects a public-mode app bundle that still contains private-repository settings.

## Signing setup

The existing private signing seed is stored in ignored `.secrets/updates/private.b64` on the maintainer's Mac and in the repository's encrypted `SPARKLE_PRIVATE_KEY` Actions secret. Keep the same key for subsequent releases and keep an encrypted backup. Only its public key is committed. Making the source repository public does not require putting the signing key in source control.

For a fresh maintainer setup, generate or reuse a local signing key and configure the Actions secret:

```sh
xcrun swift -module-cache-path build/module-cache scripts/create-update-signing-key.swift
# Copy .secrets/updates/public.b64 into publicEDKey in config/release.json.
gh secret set SPARKLE_PRIVATE_KEY --repo calvinh99/ScholarsEye < .secrets/updates/private.b64
```

The generator refuses malformed existing key material. The workflow exposes the secret only to its signing step, and the publisher passes it through stdin. The release workflow runs on main-branch configuration changes or a manual dispatch, never on pull requests. Only trusted maintainers should be able to change the release workflow or publish from main.

Update signatures are separate from Apple Developer ID signing and notarization. Current releases are ad-hoc signed; initial installation may require macOS's Open Anyway flow. Developer ID signing/notarization can be added separately.

## Publishing a release

Commit the app changes together with incremented `version` and `build` values, then push to `main`. The **Publish macOS update** Actions workflow triggers when `config/release.json` changes. Ordinary source commits without a version bump do not announce an app update.

GitHub Actions uses its built-in repository-scoped workflow credential to publish. No user supplies a token to the app, and there is no separate cross-repository publishing credential. The workflow:

1. Checks repository visibility and monotonically increasing version/build values.
2. Builds and tests the app, then packages a ZIP without development paths or recordings.
3. Generates a signed feed and independently verifies the ZIP signature against the configured public key.
4. Creates a draft release and uploads the complete ZIP and signed `appcast.xml`.
5. Verifies both assets are fully uploaded, then publishes the release as latest.

The public appcast points directly to the ZIP at `https://github.com/calvinh99/ScholarsEye/releases/download/vVERSION/ScholarsEye-VERSION-macOS-AppleSilicon.zip`. Neither request contains a GitHub credential.

Published versions and existing drafts are never overwritten. If a job fails after creating a draft, inspect the draft before removing an incomplete unpublished attempt and retrying. Already published releases require another version/build increment. Actions serializes releases to prevent overlapping publication jobs.

## Local tooling and validation

Read-only release readiness check:

```sh
zsh scripts/publish-update.sh --repo calvinh99/ScholarsEye --check
```

Build, package, and sign locally without publication:

```sh
zsh scripts/build-macos.sh
zsh scripts/package-macos.sh
# Supply SPARKLE_PRIVATE_KEY securely, then:
zsh scripts/publish-update.sh --repo calvinh99/ScholarsEye --prepare-only
```

Prepared assets appear under `build/releases/vVERSION/`. The output directory must be fresh; use `--output /absolute/fresh/directory` if needed. Without `--prepare-only`, the publisher checks GitHub state and publishes a release.

```sh
python3 -m unittest discover -s tests -p 'test_update_release.py'
zsh scripts/test-updater.sh
```

See [computer-use verification](UPDATER_VERIFICATION.md) for the actual install/restart journey. Isolated fixtures use a separate bundle identifier, copied recordings, disposable signing key, and explicitly enabled loopback feed. Packaging rejects local feeds unless its local-test option is used.

The code retains private-feed support for deployments that deliberately require it: set `githubRepository` to the release repository and use its authenticated latest-release API endpoint. That mode requires per-device Keychain credentials and is not enabled in current releases.

## References

- [Sparkle setup and signed feeds](https://sparkle-project.org/documentation/)
- [Sparkle update publishing](https://sparkle-project.org/documentation/publishing/)
- [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
