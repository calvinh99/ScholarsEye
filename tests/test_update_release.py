import base64
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/update_release.py"
spec = importlib.util.spec_from_file_location("update_release", MODULE_PATH)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
NS = release.SPARKLE_NS
REPO = "example/ScholarsEye"
CONFIG = {"version": "0.3.0", "build": "3", "publicEDKey": base64.b64encode(bytes(32)).decode(),
          "updateFeedURL": f"https://github.com/{REPO}/releases/latest/download/appcast.xml"}

PRIVATE_CONFIG = dict(CONFIG, githubRepository=REPO,
                      updateFeedURL=f"https://api.github.com/repos/{REPO}/releases/latest")


class ReleasePolicyTests(unittest.TestCase):
    def test_config_requires_real_matching_https_feed_and_public_key(self):
        release.validate_config(CONFIG, REPO)
        bad = [("updateFeedURL", "http://localhost:1234/appcast.xml"),
               ("updateFeedURL", "https://github.com/other/repo/releases/latest/download/appcast.xml"),
               ("publicEDKey", ""), ("publicEDKey", "not a key"), ("version", "0.3"),
               ("version", "0.3.0-beta"), ("version", "01.3.0"), ("build", "0"),
               ("build", "3.1"), ("build", 3)]
        for key, value in bad:
            with self.subTest(key=key, value=value), self.assertRaises(release.ReleaseError):
                release.validate_config(dict(CONFIG, **{key: value}), REPO)
        for repository in (None, "../repo", "owner/../repo", "owner/repo?token=secret", "owner/.."):
            with self.subTest(repo=repository), self.assertRaises(release.ReleaseError):
                release.validate_config(CONFIG, repository)

    def test_private_configuration_uses_repository_api_discovery(self):
        release.validate_config(PRIVATE_CONFIG, REPO)
        with self.assertRaises(release.ReleaseError):
            release.validate_config(dict(PRIVATE_CONFIG, githubRepository="other/private"), REPO)
        with self.assertRaises(release.ReleaseError):
            release.validate_config(dict(PRIVATE_CONFIG, updateFeedURL=CONFIG["updateFeedURL"]), REPO)
        self.assertEqual(release.asset_url(REPO, 12345),
                         f"https://api.github.com/repos/{REPO}/releases/assets/12345")
        for invalid in (0, -1, True, "123?token=secret", "123", None):
            with self.subTest(invalid=invalid), self.assertRaises(release.ReleaseError):
                release.asset_url(REPO, invalid)

    def test_private_repo_requires_authenticated_config_without_changing_visibility(self):
        with patch.object(release, "run", side_effect=[json.dumps({"private": True}), "[[]]"]) as run:
            self.assertIsNone(release.preflight(PRIVATE_CONFIG, REPO))
        self.assertTrue(all(call.args[0][1] == "api" for call in run.call_args_list))
        with patch.object(release, "run", return_value=json.dumps({"private": True})), \
             self.assertRaisesRegex(release.ReleaseError, "authenticated"):
            release.preflight(CONFIG, REPO)

    def test_private_release_uploads_archive_then_signed_feed_before_latest(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "update.zip"
            archive.write_bytes(b"archive")
            feed = Path(temp) / "appcast.xml"
            feed.write_bytes(b"signed feed")
            archive_asset = {"name": archive.name, "size": 7, "id": 12345, "state": "uploaded"}
            feed_asset = {"name": feed.name, "size": 11, "id": 12346, "state": "uploaded"}
            uploaded = {"draft": True, "tag_name": "v0.3.0", "assets": [archive_asset]}
            ready = {"draft": True, "tag_name": "v0.3.0", "assets": [archive_asset, feed_asset]}
            with patch.object(release, "run", side_effect=["", json.dumps([[uploaded]]), "", json.dumps([[ready]]), ""]) as run, \
                 patch.object(release, "rewrite_private_feed") as rewrite, \
                 patch.dict(release.os.environ, {"GITHUB_SHA": "sourcecommit"}), patch("builtins.print"):
                release.publish(PRIVATE_CONFIG, REPO, archive, feed, private_key="secret")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn(archive, commands[0])
            self.assertNotIn(feed, commands[0])
            self.assertIn("--draft", commands[0])
            self.assertEqual(commands[2][1:3], ["release", "upload"])
            self.assertIn(feed, commands[2])
            self.assertEqual(commands[-1][1:3], ["release", "edit"])
            self.assertIn("--latest", commands[-1])
            self.assertEqual(rewrite.call_args.args[4], 12345)

    def test_private_release_cannot_publish_if_signing_or_feed_upload_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "update.zip"
            archive.write_bytes(b"archive")
            feed = Path(temp) / "appcast.xml"
            uploaded = {"draft": True, "tag_name": "v0.3.0", "assets": [{"name": archive.name, "size": 7,
                                                    "id": 12345, "state": "uploaded"}]}
            for sign_failure in (True, False):
                responses = ["", json.dumps([[uploaded]])]
                if not sign_failure:
                    responses.append(release.ReleaseError("feed upload failed"))
                with patch.object(release, "run", side_effect=responses) as run, \
                     patch.object(release, "rewrite_private_feed", side_effect=release.ReleaseError("signing failed") if sign_failure else None), \
                     patch.dict(release.os.environ, {"GITHUB_SHA": "sourcecommit"}), \
                     self.assertRaises(release.ReleaseError):
                    release.publish(PRIVATE_CONFIG, REPO, archive, feed, private_key="secret")
                self.assertFalse(any("--latest" in call.args[0] for call in run.call_args_list))

    def test_draft_discovery_uses_listing_not_published_tag_endpoint(self):
        with patch.object(release, "run", return_value=json.dumps([[{"tag_name": "v0.3.0", "draft": True}]])) as run:
            self.assertTrue(release.draft_metadata(REPO, "v0.3.0")["draft"])
        self.assertIn("--paginate", run.call_args.args[0])
        self.assertNotIn("/tags/", run.call_args.args[0][-1])
        for entries in ([], [{"tag_name": "v0.3.0", "draft": False}]):
            with patch.object(release, "run", return_value=json.dumps([entries])), self.assertRaises(release.ReleaseError):
                release.draft_metadata(REPO, "v0.3.0")

    def test_private_feed_rewrite_removes_old_signature_and_signs_final_asset_url(self):
        with tempfile.TemporaryDirectory() as temp:
            feed = Path(temp) / "appcast.xml"
            feed.write_text('<rss><channel><item><enclosure url="old"/></item></channel></rss><!-- old signature -->')
            with patch.object(release, "run") as run, patch.object(release, "validate_appcast") as validate:
                release.rewrite_private_feed(PRIVATE_CONFIG, REPO, feed, Path("archive.zip"), 12345, "secret")
            self.assertNotIn("old signature", feed.read_text())
            self.assertIn("https://api.github.com/repos/example/ScholarsEye/releases/assets/12345", feed.read_text())
            self.assertEqual(run.call_count, 2)
            self.assertIn("--verify", run.call_args_list[1].args[0])
            self.assertEqual(validate.call_args.kwargs["archive_asset_id"], 12345)

    def test_drafts_and_published_versions_cannot_be_overwritten(self):
        for draft in (False, True):
            with self.subTest(draft=draft), self.assertRaisesRegex(release.ReleaseError, "already exists"):
                release.validate_release_history(CONFIG, [{"tag_name": "v0.3.0", "draft": draft}])

    def test_version_order_is_numeric_and_pre_releases_do_not_become_stable(self):
        history = [{"tag_name": "v0.2.9"}, {"tag_name": "v0.2.10"},
                   {"tag_name": "v9.0.0", "prerelease": True}]
        self.assertEqual(release.validate_release_history(CONFIG, history)["tag_name"], "v0.2.10")
        with self.assertRaisesRegex(release.ReleaseError, "greater"):
            release.validate_release_history(CONFIG, [{"tag_name": "v0.10.0"}])

    def test_build_progress_protects_existing_users_from_non_updates(self):
        feed = f'<rss xmlns:sparkle="{NS}"><channel><item><sparkle:version>2</sparkle:version></item></channel></rss>'
        release.validate_build_progress(CONFIG, feed)
        for build in ("1", "2"):
            with self.subTest(build=build), self.assertRaises(release.ReleaseError):
                release.validate_build_progress(dict(CONFIG, build=build), feed)
        with self.assertRaises(release.ReleaseError):
            release.validate_build_progress(CONFIG, "<rss/>")

    def test_production_app_must_require_signatures_and_omit_machine_paths(self):
        info = {"CFBundleIdentifier": "com.scholarseye.app", "CFBundleVersion": "3",
                "CFBundleShortVersionString": "0.3.0", "SUFeedURL": CONFIG["updateFeedURL"],
                "SUPublicEDKey": CONFIG["publicEDKey"], "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True}
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "ScholarsEye.app"
            (app / "Contents").mkdir(parents=True)
            path = app / "Contents/Info.plist"
            path.write_bytes(plistlib.dumps(info))
            release.validate_app(CONFIG, app)
            for key, value in (("SURequireSignedFeed", False), ("CFBundleVersion", "2"),
                               ("ScholarsEyeRecordingsPath", "/Users/developer/recordings")):
                path.write_bytes(plistlib.dumps(dict(info, **{key: value})))
                with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                    release.validate_app(CONFIG, app)

    def test_feed_points_to_immutable_archive_and_validates_size(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "ScholarsEye-0.3.0-macOS-AppleSilicon.zip"
            archive.write_bytes(b"pretend archive")
            signature = base64.b64encode(bytes(64)).decode()
            feed_text = f'''<rss xmlns:sparkle="{NS}"><channel><item>
                <sparkle:version>3</sparkle:version><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
                <enclosure url="https://github.com/{REPO}/releases/download/v0.3.0/{archive.name}"
                length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
                </item></channel></rss>'''
            feed = Path(temp) / "appcast.xml"
            feed.write_text(feed_text)
            self.assertEqual(release.validate_appcast(CONFIG, REPO, feed, archive), signature)
            for bad in (feed_text.replace("download/v0.3.0/", "latest/download/"),
                        feed_text.replace('length="15"', 'length="1"'),
                        feed_text.replace("<sparkle:version>3", "<sparkle:version>2")):
                feed.write_text(bad)
                with self.assertRaises(release.ReleaseError):
                    release.validate_appcast(CONFIG, REPO, feed, archive)

    def test_failed_asset_upload_never_publishes_draft(self):
        with patch.object(release, "run", side_effect=release.ReleaseError("upload failed")) as run, \
             patch.dict(release.os.environ, {"GITHUB_SHA": "abc123"}):
            with self.assertRaisesRegex(release.ReleaseError, "upload failed"):
                release.publish(CONFIG, REPO, Path("update.zip"), Path("appcast.xml"))
        self.assertEqual(run.call_count, 1)
        self.assertIn("--draft", run.call_args.args[0])

    def test_complete_assets_publish_before_latest_switch(self):
        with patch.object(release, "run", return_value="") as run, \
             patch.dict(release.os.environ, {"GITHUB_SHA": "abc123"}), patch("builtins.print"):
            release.publish(CONFIG, REPO, Path("update.zip"), Path("appcast.xml"))
        first, second = [call.args[0] for call in run.call_args_list]
        self.assertIn(Path("update.zip"), first)
        self.assertIn(Path("appcast.xml"), first)
        self.assertIn("--draft", first)
        self.assertIn("--draft=false", second)
        self.assertIn("--latest", second)

    def test_separate_distribution_repository_does_not_use_private_source_commit(self):
        with patch.object(release, "run", return_value="") as run, \
             patch.dict(release.os.environ, {"GITHUB_SHA": "privatecommit", "GITHUB_REPOSITORY": "owner/private-source"}), \
             patch("builtins.print"):
            release.publish(CONFIG, REPO, Path("update.zip"), Path("appcast.xml"))
        create = run.call_args_list[0].args[0]
        self.assertNotIn("privatecommit", create)
        self.assertNotIn("--generate-notes", create)
        self.assertNotIn("--target", create)

    def test_signing_secret_only_goes_to_stdin_and_errors_redact_it(self):
        result = release.subprocess.CompletedProcess(["sign_update"], 1, "", "bad key SENSITIVE")
        with patch.object(release.subprocess, "run", return_value=result) as run, \
             patch.dict(release.os.environ, {"SPARKLE_PRIVATE_KEY": "SENSITIVE"}):
            with self.assertRaises(release.ReleaseError) as raised:
                release.run(["sign_update", "--ed-key-file", "-"], private_key="SENSITIVE")
        self.assertNotIn("SENSITIVE", str(raised.exception))
        self.assertEqual(run.call_args.kwargs["input"], "SENSITIVE\n")
        self.assertNotIn("SPARKLE_PRIVATE_KEY", run.call_args.kwargs["env"])
        self.assertNotIn("SENSITIVE", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
