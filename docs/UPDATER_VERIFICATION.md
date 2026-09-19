# Reproducible updater verification

The updater journey uses an isolated `com.scholarseye.updatetest` bundle, local
recordings, and a disposable signing key in ignored `runtime/update-test/`. It
does not read or change production signing keys, the Keychain, user defaults for
`com.scholarseye.app`, or real recordings. The test server binds only to
`127.0.0.1` and serves prepared public files; the key is outside its served tree.

Prepare both applications and signed feeds after implementing the app code:

```sh
zsh scripts/prepare-update-test.sh
python3 tests/support/serve_updates.py
```

Preparation builds version **0.3.0 (3)** and **0.3.1 (4)**, packages the update,
and uses Sparkle's pinned official `generate_appcast` and `sign_update` tools.
The private test seed is generated with CryptoKit, stored with mode `0600`, and
passed by filename. No secret is printed. Signed feeds are required and update
archives are verified before extraction in both builds. The helper checks these
settings before packaging and independently confirms good signatures and the
intentional failures in the tampered fixtures.

Launch `runtime/update-test/baseline/ScholarsEye.app` with computer use. The
initial server scenario is `no-update`. Change scenarios while the server runs:

```sh
python3 tests/support/serve_updates.py --set-scenario good
```

Available scenarios:

| Scenario | Expected result |
| --- | --- |
| `no-update` | Signed feed offers the current build. The app says it is up to date. |
| `unavailable` | The feed returns HTTP 404. A manual check shows a recoverable error. |
| `bad-feed` | Valid XML modified after signing. The app rejects the feed and offers no install. |
| `good` | Signed feed offers 0.3.1. The app offers an update and can download it. |
| `tampered-archive` | Valid signed feed but an archive byte changed without changing file length. Installation fails signature verification and the current app remains intact. |

For a complete computer-use journey, check the unchanged case, unavailable feed,
bad feed, discovery of the good update, and rejection of the corrupted archive.
Then restore `good`, retry the update, accept restart, and inspect both the
reopened app and its installed version. Check that local session data survives.
An active recording, paused recording, and stop/finalization must prevent
installation/restart; verify those separately without forcing termination.

After a successful update the baseline application has been replaced by 0.3.1.
Quit it before rebuilding fixtures for another run. `--reuse-builds` only applies
when both original application versions remain unchanged; the script refuses a
stale or already-upgraded baseline. Use `--port` during preparation if 8768 is
occupied; the server port must match the URL compiled into the test apps.

The fixture-server safety checks can run without building or starting the app:

```sh
PYTHONPYCACHEPREFIX="$PWD/build/python-cache" python3 -m unittest discover -s tests -p test_update_fixture.py -v
```

Run the updater's controller checks independently of screen/microphone
permissions and live network access:

```sh
zsh scripts/test-updater.sh
```

Those checks exercise URL/key validation, an explicit install choice, blocking
while capture is active, a capture/restart race, cancellation revoking consent,
verification errors, progress overflow/nonfinite values, and successful guard
release. They invoke the same controller callbacks used by Sparkle.

Private GitHub discovery has its own deterministic checks:

```sh
zsh scripts/test-github-updates.sh
```

They cover exact stable `appcast.xml` discovery, only accepting asset API URLs
from the configured repository, request headers, token input validation, the
1 MiB metadata limit, and distinct authentication/rate-limit/missing-release
errors. They use synthetic metadata and a dummy token; they make no network
requests and never read or write the Keychain. Fixture app builds explicitly
clear `SCHOLARSEYE_GITHUB_REPOSITORY` so the loopback signing/restart journey
remains independent of a GitHub account.

These instructions describe the repeatable test procedure. They do not by
themselves claim the GUI journey has been executed; record observed results in
the release's validation notes.

## Observed computer-use validation — September 18, 2026

The isolated native app was exercised through its real interface on the Mac mini:

- A signed current-version feed reported 0.3.0 as up to date.
- A modified feed was rejected before an install offer.
- A signed feed pointing to altered archive bytes was rejected before installation.
- An unavailable feed showed a recoverable error; retrying with a valid feed worked.
- Clicking **Update & restart** upgraded 0.3.0 (3) to 0.3.1 (4). The original app quit, the app inventory showed it running again without a manual launch, and its reopened UI displayed 0.3.1.
- The saved 99-second session opened and played before and after updating. SHA-256 checks confirmed all six copied session files were unchanged.

Recording/pause/finalization and the start-versus-install race are covered by controller tests. This updater test did not initiate a new recording or request additional capture permissions. Private GitHub transport is verified separately from the isolated loopback install test.

The first [private release workflow](https://github.com/calvinh99/ScholarsEye/actions/runs/35393559192) passed and published v0.3.0. A live probe using the same GitHub discovery helper retrieved that release's raw signed RSS feed with HTTP 200, without attaching authorization to its temporary CDN URL. A separate native URLSession redirect test confirmed a dummy Authorization header is stripped on a host change, matching Sparkle's default downloader behavior.

The exact CI-produced ZIP was downloaded, its archive signature checked against the embedded public key, extracted, and its full code signature verified. Computer use launched that app and confirmed version 0.3.0 with the private GitHub connection interface. No GitHub token was entered or saved in the app during validation; each device still needs its user-provided read-only token. End-to-end private installation with a saved device credential remains untested; the authenticated transport and actual installation/relaunch were verified separately.

## Highlighted update icon — September 19, 2026

The isolated app was rebuilt with the top-right gold arrow and recheck-on-click behavior. Computer use confirmed the icon stayed highlighted while a saved session played and no installation began. Right-clicking opened update details.

After discovery, the server was switched to unavailable. Clicking the highlighted icon fetched the feed again, displayed a recoverable retrieval error, and left version 0.3.0 (3) installed. Restoring the valid feed and clicking again completed the fresh check, download, installation, and automatic relaunch into 0.3.1 (4). The icon returned to its neutral appearance, the saved session played, and SHA-256 checks confirmed all six copied session files were unchanged.

Controller checks cover a newer release replacing an earlier notification, cancellation and late callbacks, SDK readiness transitions, and recording guards. The implementation observes Sparkle's readiness properties before starting the fresh check; it uses no timing delay or polling.
