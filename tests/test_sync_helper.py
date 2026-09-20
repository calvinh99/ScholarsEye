"""Exercise the exact Python helper shipped inside the native sync client."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class SessionSyncRemoteHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (PROJECT_ROOT / "apps/macos/ScholarsEye/SessionSyncRemoteHelper.swift").read_text()
        match = re.search(r'static let python = #"""\n(.*?)\n"""#', source, re.DOTALL)
        if match is None:
            raise AssertionError("Could not find the embedded remote helper.")
        cls.helper = match.group(1)
        compile(cls.helper, "SessionSyncRemoteHelper.py", "exec")

    def setUp(self):
        # macOS /tmp and /var are symlinks, which the remote path policy rejects.
        self.temporary = tempfile.TemporaryDirectory(
            prefix="scholarseye-sync-helper-", dir=os.path.realpath(tempfile.gettempdir())
        )
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.library = self.base / "library"
        self.library.mkdir()

    def invoke(self, action, root, *arguments, success=True):
        result = subprocess.run(
            [sys.executable, "-", action, str(root), *arguments],
            input=self.helper, text=True, capture_output=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertTrue(result.stderr.startswith("Session sync: "), result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result.stderr

    def make_session(self, identifier="session-001", status="complete", root=None,
                     chunk_name="chunk-0001.mp4", diagnostics=b'{"fixture":true}'):
        folder = (root or self.library) / identifier
        folder.mkdir(parents=True)
        payload = b"Small immutable MP4 test payload; decoding is not part of sync."
        manifest = {
            "schemaVersion": 1, "id": identifier,
            "startedAt": "2026-09-20T12:00:00Z", "endedAt": "2026-09-20T12:01:00Z",
            "status": status,
            "configuration": {
                "framesPerSecond": 1, "maxWidth": 2560, "videoBitrate": 400000,
                "codec": "hevc", "recordMicrophone": True, "recordSystemAudio": False,
                "chunkDuration": 60,
            },
            "displayID": 1, "displayWidth": 2560, "displayHeight": 1440,
            "durationSeconds": 60, "bytesWritten": len(payload),
            "chunks": [{
                "id": 1, "fileName": chunk_name, "codec": "hevc", "hardwareAccelerated": True,
                "startOffsetSeconds": 0, "durationSeconds": 60, "byteCount": len(payload),
                "videoFrames": 60, "droppedVideoFrames": 0, "droppedAudioSamples": 0,
                "microphoneSamples": 2880000, "systemAudioSamples": 0,
            }],
            "events": [], "unfinishedFiles": [],
        }
        (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        (folder / chunk_name).write_bytes(payload)
        if diagnostics is not None:
            (folder / "diagnostics.json").write_bytes(diagnostics)
        return folder

    @staticmethod
    def edit_manifest(folder, edit):
        path = folder / "manifest.json"
        value = json.loads(path.read_text())
        edit(value)
        path.write_text(json.dumps(value), encoding="utf-8")

    def entry(self, folder):
        entries = self.invoke("inventory", folder.parent)["sessions"]
        return next(item for item in entries if item["id"] == folder.name)

    def stage_copy(self, source, destination):
        entry = self.entry(source)
        stage = Path(self.invoke("prepare", destination, entry["id"], entry["digest"])["path"])
        for item in entry["files"]:
            shutil.copyfile(source / item["name"], stage / item["name"])
        return entry, stage

    def assert_rejected(self, identifier):
        result = self.invoke("inventory", self.library)
        self.assertNotIn(identifier, [item["id"] for item in result["sessions"]])
        self.assertTrue(any(item.startswith(identifier + ": ") for item in result["rejected"]), result)

    def test_inventory_shape_and_exact_immutable_fingerprint(self):
        folder = self.make_session()
        (folder / "analysis.json").write_text('{"ignored":true}')
        (folder / "unlisted.mp4").write_bytes(b"ignored extra media")
        (self.library / ".hidden").mkdir()
        result = self.invoke("inventory", self.library)
        self.assertEqual(set(result), {"root", "sessions", "rejected"})
        self.assertEqual(result["root"], str(self.library))
        self.assertEqual(result["rejected"], [])
        self.assertEqual(len(result["sessions"]), 1)
        entry = result["sessions"][0]
        self.assertEqual(set(entry), {"id", "digest", "files"})
        self.assertEqual(entry["id"], folder.name)
        expected_files = []
        for name in ["chunk-0001.mp4", "diagnostics.json", "manifest.json"]:
            payload = (folder / name).read_bytes()
            expected_files.append({"name": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
        self.assertEqual(entry["files"], expected_files)
        encoded = "".join(item["name"] + "\0" + str(item["bytes"]) + "\0" + item["sha256"] + "\n"
                          for item in expected_files).encode("utf-8")
        self.assertEqual(entry["digest"], hashlib.sha256(encoded).hexdigest())

    def test_incomplete_sessions_are_skipped_without_warnings(self):
        for status in ["recording", "paused", "failed", "interrupted"]:
            self.make_session(identifier=status, status=status)
        result = self.invoke("inventory", self.library)
        self.assertEqual(result["sessions"], [])
        self.assertEqual(result["rejected"], [])

    def test_malformed_completed_session_is_reported(self):
        folder = self.make_session()
        (folder / "manifest.json").write_text('{"status":"complete"}')
        self.assert_rejected(folder.name)

    def test_invalid_json_is_reported(self):
        folder = self.make_session()
        (folder / "manifest.json").write_text('{"status":')
        self.assert_rejected(folder.name)

    def test_missing_diagnostics_and_zero_legacy_chunk_byte_count_are_allowed(self):
        folder = self.make_session(diagnostics=None)
        self.edit_manifest(folder, lambda value: value["chunks"][0].update(byteCount=0))
        entry = self.entry(folder)
        self.assertEqual([item["name"] for item in entry["files"]], ["chunk-0001.mp4", "manifest.json"])

    def test_prepare_resumes_existing_partial_regular_files(self):
        folder = self.make_session()
        entry = self.entry(folder)
        destination = self.base / "destination"
        first = self.invoke("prepare", destination, entry["id"], entry["digest"])
        stage = Path(first["path"])
        self.assertEqual(stage.name, entry["id"] + "-" + entry["digest"])
        self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
        self.assertEqual(stage.parent.stat().st_mode & 0o777, 0o700)
        (stage / "chunk-0001.mp4").write_bytes(b"partial")
        (stage / "manifest.json").write_bytes(b"")
        self.assertEqual(self.invoke("prepare", destination, entry["id"], entry["digest"]), first)
        self.assertEqual((stage / "chunk-0001.mp4").read_bytes(), b"partial")

    @unittest.skipUnless(sys.platform == "darwin", "Native exclusive rename requires macOS")
    def test_atomic_finalize_and_idempotent_retry(self):
        source = self.make_session()
        destination = self.base / "destination"
        entry, stage = self.stage_copy(source, destination)
        self.assertFalse((destination / entry["id"]).exists())
        self.assertEqual(self.invoke("finalize", destination, entry["id"], entry["digest"]), {"status": "imported"})
        self.assertFalse(stage.exists())
        self.assertEqual(self.invoke("finalize", destination, entry["id"], entry["digest"]), {"status": "unchanged"})
        self.assertEqual(self.entry(destination / entry["id"]), entry)

    @unittest.skipUnless(sys.platform == "darwin", "Native exclusive rename requires macOS")
    def test_finalize_never_overwrites_conflicting_session(self):
        source = self.make_session()
        destination = self.base / "destination"
        entry, stage = self.stage_copy(source, destination)
        conflicting = self.make_session(root=destination, diagnostics=b'{"different":true}')
        before = {path.name: path.read_bytes() for path in conflicting.iterdir()}
        self.invoke("finalize", destination, entry["id"], entry["digest"], success=False)
        self.assertEqual({path.name: path.read_bytes() for path in conflicting.iterdir()}, before)
        self.assertTrue(stage.exists())

    def test_finalize_rejects_corrupt_staged_payload(self):
        source = self.make_session()
        destination = self.base / "destination"
        entry, stage = self.stage_copy(source, destination)
        media = stage / "chunk-0001.mp4"
        media.write_bytes(b"!" * len(media.read_bytes()))
        error = self.invoke("finalize", destination, entry["id"], entry["digest"], success=False)
        self.assertIn("fingerprint", error)
        self.assertFalse((destination / entry["id"]).exists())
        self.assertTrue(stage.exists())

    def test_remote_root_rejects_traversal_controls_and_root_aliases(self):
        paths = ["/", "~/", "relative/path", str(self.library) + "/../escape",
                 str(self.library) + "/./child", str(self.library) + "\n",
                 str(self.library) + "\u0085", str(self.library) + "\u200e", "/" + "a" * 2049]
        for path in paths:
            with self.subTest(path=repr(path)):
                self.invoke("inventory", path, success=False)

    def test_root_and_ancestor_symlinks_are_rejected(self):
        alias = self.base / "alias"
        alias.symlink_to(self.library, target_is_directory=True)
        self.invoke("inventory", alias, success=False)
        self.invoke("inventory", alias / "child", success=False)
        self.assertFalse((self.library / "child").exists())

    def test_session_and_core_file_symlinks_are_rejected(self):
        source = self.make_session(identifier="original")
        (self.library / "linked").symlink_to(source, target_is_directory=True)
        self.assert_rejected("linked")
        for name in ["manifest.json", "chunk-0001.mp4", "diagnostics.json"]:
            with self.subTest(name=name):
                folder = self.make_session(identifier="linked-" + name.replace(".", "-"))
                (folder / name).unlink()
                (folder / name).symlink_to(source / name)
                self.assert_rejected(folder.name)
        folder = self.make_session(identifier="dangling-diagnostics")
        (folder / "diagnostics.json").unlink()
        (folder / "diagnostics.json").symlink_to(self.base / "does-not-exist")
        self.assert_rejected(folder.name)

    def test_staging_symlinks_are_rejected(self):
        source = self.make_session()
        entry = self.entry(source)
        destination = self.base / "destination"
        destination.mkdir()
        (destination / ".scholarseye-sync").symlink_to(self.library, target_is_directory=True)
        self.invoke("prepare", destination, entry["id"], entry["digest"], success=False)
        (destination / ".scholarseye-sync").unlink()
        stage = Path(self.invoke("prepare", destination, entry["id"], entry["digest"])["path"])
        (stage / "chunk-0001.mp4").symlink_to(source / "chunk-0001.mp4")
        self.invoke("prepare", destination, entry["id"], entry["digest"], success=False)
        (stage / "chunk-0001.mp4").unlink()
        stage.rmdir()
        stage.symlink_to(source, target_is_directory=True)
        self.invoke("prepare", destination, entry["id"], entry["digest"], success=False)

    def test_chunk_traversal_duplicate_and_size_mismatch_are_rejected(self):
        for identifier, edit in [
            ("traversal", lambda value: value["chunks"][0].update(fileName="../outside.mp4")),
            ("duplicate", lambda value: value["chunks"].append(value["chunks"][0].copy())),
            ("size-mismatch", lambda value: value["chunks"][0].update(byteCount=999)),
            ("negative-size", lambda value: value["chunks"][0].update(byteCount=-1)),
        ]:
            with self.subTest(identifier=identifier):
                folder = self.make_session(identifier=identifier)
                self.edit_manifest(folder, edit)
                self.assert_rejected(identifier)

    def test_empty_diagnostics_and_empty_media_are_rejected(self):
        self.make_session(identifier="empty-diagnostics", diagnostics=b"")
        self.assert_rejected("empty-diagnostics")
        folder = self.make_session(identifier="empty-media")
        (folder / "chunk-0001.mp4").write_bytes(b"")
        self.assert_rejected("empty-media")

    def test_safe_name_boundaries_and_invalid_fingerprints(self):
        valid_name = "a" * 186 + ".mp4"
        valid = self.make_session(identifier="valid-name", chunk_name=valid_name)
        self.assertEqual(len(valid_name), 190)
        self.entry(valid)
        self.make_session(identifier="long-name", chunk_name="a" * 187 + ".mp4")
        self.assert_rejected("long-name")
        digest = self.entry(valid)["digest"]
        for identifier, fingerprint in [("../escape", digest), ("a" * 191, digest), ("valid-name", "bad")]:
            with self.subTest(identifier=identifier):
                self.invoke("prepare", self.base / "destination", identifier, fingerprint, success=False)


if __name__ == "__main__":
    unittest.main()
