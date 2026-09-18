"""Integration checks use small generated media, never personal recordings."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "analyze_recording.py"
spec = importlib.util.spec_from_file_location("recording_analysis", SCRIPT)
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class RecordingAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        self.ffmpeg = analysis.executable("ffmpeg")

    def tearDown(self):
        self.temporary.cleanup()

    def chunk(self, name, screen="white", sound="silent", start=0, duration=4):
        path = self.folder / name
        command = [self.ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                   "color=c={}:s=96x64:r=1:d={}".format(screen, duration)]
        if sound != "missing":
            source = ("anullsrc=r=16000:cl=mono" if sound == "silent"
                      else "sine=frequency=500:sample_rate=16000")
            command += ["-f", "lavfi", "-i", source]
        if sound == "second_track_active":
            command += ["-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-map", "0:v", "-map", "1:a", "-map", "2:a"]
        command += ["-t", str(duration), "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-c:a", "aac", str(path)]
        subprocess.run(command, check=True, capture_output=True)
        return {"id": name, "fileName": name, "startOffsetSeconds": start,
                "durationSeconds": duration, "byteCount": path.stat().st_size, "droppedAudioSamples": 0}

    def manifest(self, chunks, status="complete", microphone=True, system=False):
        payload = {"schemaVersion": 1, "id": "test-session", "status": status,
                   "configuration": {"framesPerSecond": 1, "recordMicrophone": microphone,
                                     "recordSystemAudio": system},
                   "chunks": chunks, "unfinishedFiles": []}
        (self.folder / "manifest.json").write_text(json.dumps(payload))

    def run_analysis(self, threshold=3, margin=1):
        return analysis.analyze(self.folder, threshold, margin, -60)

    def test_static_silent_video_preserves_margins_and_original_bytes(self):
        chunk = self.chunk("one.mp4", duration=6)
        self.manifest([chunk])
        before = hashlib.sha256((self.folder / "one.mp4").read_bytes()).hexdigest()
        result = self.run_analysis()
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["chunks"][0]["videoFrames"], 6)
        omitted = result["inferencePlan"]["candidateOmissionIntervals"]
        self.assertEqual(len(omitted), 1)
        self.assertAlmostEqual(omitted[0]["startOffsetSeconds"], 1, places=2)
        self.assertAlmostEqual(omitted[0]["endOffsetSeconds"], 5, places=2)
        self.assertEqual(before, hashlib.sha256((self.folder / "one.mp4").read_bytes()).hexdigest())
        self.assertEqual(result["storage"]["bytesSaved"], 0)
        self.assertFalse(result["automaticOmissionEnabled"])

    def test_audio_activity_and_absent_audio_each_prevent_omission(self):
        for sound in ["active", "missing", "second_track_active"]:
            with self.subTest(sound=sound):
                chunk = self.chunk(sound + ".mp4", sound=sound)
                self.manifest([chunk], system=(sound == "second_track_active"))
                self.assertEqual(self.run_analysis()["inferencePlan"]["candidateOmissionIntervals"], [])

    def test_static_identical_screen_can_cross_chunk_boundary(self):
        chunks = [self.chunk("one.mp4", duration=4), self.chunk("two.mp4", start=4, duration=4)]
        self.manifest(chunks)
        candidates = self.run_analysis(threshold=6)["inferencePlan"]["candidateOmissionIntervals"]
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["startOffsetSeconds"], 1, places=2)
        self.assertAlmostEqual(candidates[0]["endOffsetSeconds"], 7, places=2)

    def test_changed_screen_or_pause_does_not_join_static_chunks(self):
        one = self.chunk("one.mp4", duration=4)
        for second, start in [("black", 4), ("white", 5)]:
            with self.subTest(second=second, start=start):
                two = self.chunk("{}-{}.mp4".format(second, start), screen=second, start=start)
                self.manifest([one, two])
                self.assertEqual(self.run_analysis(threshold=6)["inferencePlan"]["candidateOmissionIntervals"], [])

    def test_incomplete_corrupted_and_missing_chunks_are_explicit_errors(self):
        chunk = self.chunk("one.mp4")
        self.manifest([chunk], status="interrupted")
        with self.assertRaisesRegex(analysis.AnalysisError, "incomplete"):
            self.run_analysis()
        self.manifest([chunk])
        (self.folder / "one.mp4").write_bytes(b"not a video")
        with self.assertRaises(analysis.AnalysisError):
            self.run_analysis()
        (self.folder / "one.mp4").unlink()
        with self.assertRaisesRegex(analysis.AnalysisError, "Missing"):
            self.run_analysis()

    def test_dropped_audio_disables_omission(self):
        chunk = self.chunk("one.mp4")
        chunk["droppedAudioSamples"] = 1
        self.manifest([chunk])
        result = self.run_analysis()
        self.assertTrue(result["warnings"])
        self.assertEqual(result["inferencePlan"]["candidateOmissionIntervals"], [])

    def test_cli_reports_errors_in_json_and_returns_nonzero(self):
        output = self.folder / "result.json"
        result = subprocess.run(["python3", str(SCRIPT), str(self.folder), "--output", str(output)], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(output.read_text())["status"], "error")

    def test_default_three_minute_threshold_and_thirty_second_margins(self):
        chunk = self.chunk("three-minutes.mp4", duration=184)
        self.manifest([chunk])
        result = analysis.analyze(self.folder, 180, 30, -60)
        candidates = result["inferencePlan"]["candidateOmissionIntervals"]
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["startOffsetSeconds"], 30, places=2)
        self.assertAlmostEqual(candidates[0]["endOffsetSeconds"], 154, places=2)


if __name__ == "__main__":
    unittest.main()
