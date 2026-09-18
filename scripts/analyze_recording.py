#!/usr/bin/env python3
"""Audit a finished ScholarsEye session without modifying its recordings.

Uses ffprobe for container metadata and ffmpeg to decode every recorded stream.
Only repeated, byte-identical decoded screen frames AND silence on every audio
track can produce idle candidates. Candidates are a preparation plan, not edits.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction
from typing import List, Tuple


Interval = Tuple[float, float]
VERSION = 1
SILENCE_EVENT = re.compile(r"silence_(start|end)[:=]\s*(-?[\d.]+)")
AUDIO_BOUNDARY_GAP = 0.1  # AAC packet alignment at a continuously recorded chunk boundary.


class AnalysisError(Exception):
    pass


def number(value, name: str, minimum: float = 0) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        raise AnalysisError("Invalid {}".format(name))
    if not math.isfinite(result) or result < minimum:
        raise AnalysisError("Invalid {}".format(name))
    return result


def merge(intervals: List[Interval], tolerance: float = 0.000001) -> List[Interval]:
    result = []
    for start, end in sorted(intervals):
        if end <= start:
            continue
        if result and start <= result[-1][1] + tolerance:
            result[-1] = (result[-1][0], max(result[-1][1], end))
        else:
            result.append((start, end))
    return result


def intersect(left: List[Interval], right: List[Interval]) -> List[Interval]:
    result = []
    left, right = merge(left), merge(right)
    i = j = 0
    while i < len(left) and j < len(right):
        start, end = max(left[i][0], right[j][0]), min(left[i][1], right[j][1])
        if end > start:
            result.append((start, end))
        if left[i][1] <= right[j][1]:
            i += 1
        else:
            j += 1
    return result


def subtract(available: List[Interval], omitted: List[Interval]) -> List[Interval]:
    result = []
    for start, end in merge(available):
        cursor = start
        for cut_start, cut_end in merge(omitted):
            if cut_end <= cursor or cut_start >= end:
                continue
            if cut_start > cursor:
                result.append((cursor, cut_start))
            cursor = max(cursor, cut_end)
        if cursor < end:
            result.append((cursor, end))
    return result


def encoded(intervals: List[Interval]) -> list:
    return [{"startOffsetSeconds": round(a, 6), "endOffsetSeconds": round(b, 6),
             "durationSeconds": round(b - a, 6)} for a, b in intervals]


def executable(name: str) -> str:
    installed = Path("/opt/homebrew/bin") / name
    found = str(installed) if installed.is_file() else shutil.which(name)
    if not found:
        raise AnalysisError("{} is required for post-recording analysis".format(name))
    return found


def probe(path: Path, ffprobe: str) -> dict:
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode or result.stderr.strip():
        raise AnalysisError("Cannot read {}: {}".format(path.name, result.stderr.strip()[:2000]))
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise AnalysisError("Invalid ffprobe response for {}".format(path.name))
    if not metadata.get("streams"):
        raise AnalysisError("No media streams in {}".format(path.name))
    return metadata


def checked_process(command: list, on_line) -> None:
    """Consume output incrementally; stderr spills to disk instead of growing RAM."""
    with tempfile.TemporaryFile(mode="w+b") as errors:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            for line in process.stdout:
                on_line(line)
            returncode = process.wait()
        except BaseException:
            process.kill()
            process.wait()
            raise
        finally:
            process.stdout.close()
        errors.seek(0)
        error = errors.read(8192).decode("utf-8", errors="replace").strip()
        if returncode or error:
            raise AnalysisError("Media decode failed: {}".format(error or "ffmpeg exit {}".format(returncode)))


def video_runs(path: Path, stream: dict, ffmpeg: str, duration: float, fps: float) -> dict:
    """Hash full-resolution decoded pixels. Tiny text changes end a static run."""
    state = {"timebase": None, "count": 0, "hash": None, "start": None, "end": None, "lastTimestamp": None,
             "runs": [], "firstHash": None, "lastHash": None}
    # There must be continuous capture evidence. Gaps beyond 2.5 expected frames
    # cannot support a static-screen inference, even if their endpoints match.
    max_gap = 2.5 / fps

    def finish():
        if state["start"] is not None and state["end"] > state["start"]:
            state["runs"].append((state["start"], state["end"], state["hash"]))

    def line_received(line):
        if line.startswith("#tb 0:"):
            state["timebase"] = float(Fraction(line.split(":", 1)[1].strip()))
        elif line and not line.startswith("#"):
            fields = [field.strip() for field in line.split(",")]
            if len(fields) != 6 or state["timebase"] is None:
                raise AnalysisError("Unexpected frame metadata in {}".format(path.name))
            timestamp = int(fields[2]) * state["timebase"]
            frame_duration = int(fields[3]) * state["timebase"]
            timestamp = max(0, timestamp)
            end = min(duration, timestamp + min(frame_duration, max_gap))
            digest = fields[5]
            if state["lastTimestamp"] is not None and timestamp < state["lastTimestamp"]:
                raise AnalysisError("Non-monotonic video timestamps in {}".format(path.name))
            if (digest != state["hash"] or state["end"] is None
                    or timestamp - state["end"] > 0.000001):
                finish()
                state["start"], state["hash"] = timestamp, digest
            state["end"] = end
            state["lastTimestamp"] = timestamp
            state["count"] += 1
            state["firstHash"] = state["firstHash"] or digest
            state["lastHash"] = digest

    checked_process(
        [ffmpeg, "-nostdin", "-v", "error", "-xerror", "-threads", "2", "-err_detect", "explode",
         "-copyts", "-i", str(path), "-map", "0:{}".format(stream["index"]),
         "-an", "-fps_mode", "passthrough", "-enc_time_base", "demux",
         "-f", "framemd5", "pipe:1"], line_received,
    )
    finish()
    if state["count"] == 0:
        raise AnalysisError("No decodable video frames in {}".format(path.name))
    return state


def audio_silence(path: Path, stream: dict, ffmpeg: str, duration: float, silence_db: float) -> List[Interval]:
    """With mono=0, silence requires every channel in the track to be silent."""
    intervals = []
    state = {"start": None, "samples": 0}

    def line_received(line):
        if line.startswith("frame:"):
            state["samples"] += 1
        for kind, timestamp in SILENCE_EVENT.findall(line):
            timestamp = min(duration, max(0, float(timestamp)))
            if kind == "start":
                state["start"] = timestamp
            elif state["start"] is not None:
                intervals.append((state["start"], timestamp))
                state["start"] = None

    # Metadata is emitted through stdout; decoder errors remain isolated on stderr.
    filter_text = "silencedetect=noise={}dB:duration=1:mono=0,ametadata=mode=print:file=-".format(silence_db)
    checked_process(
        [ffmpeg, "-nostdin", "-v", "error", "-xerror", "-threads", "2", "-err_detect", "explode",
         "-copyts", "-i", str(path), "-map", "0:{}".format(stream["index"]),
         "-vn", "-af", filter_text, "-f", "null", "-"], line_received,
    )
    stream_start = max(0, number(stream.get("start_time", 0), "audio start", -math.inf))
    stream_duration = number(stream.get("duration", 0), "audio duration")
    stream_end = min(duration, stream_start + stream_duration)
    if state["start"] is not None and stream_end > state["start"]:
        intervals.append((state["start"], stream_end))
    return intersect(intervals, [(stream_start, stream_end)])


def merge_matching_runs(runs: list) -> list:
    """Never join different images or any gap, including between MP4 chunks."""
    result = []
    for start, end, digest in sorted(runs):
        if end <= start:
            continue
        if result and digest == result[-1][2] and abs(start - result[-1][1]) <= 0.000001:
            result[-1] = (result[-1][0], end, digest)
        else:
            result.append((start, end, digest))
    return result


def analyze(session: Path, minimum_idle: float, margin: float, silence_db: float) -> dict:
    session = session.resolve()
    manifest_path = session / "manifest.json"
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
    except (OSError, json.JSONDecodeError) as exc:
        raise AnalysisError("Cannot read session manifest: {}".format(exc))
    if not isinstance(manifest, dict):
        raise AnalysisError("Session manifest must be a JSON object")
    if manifest.get("schemaVersion") != VERSION:
        raise AnalysisError("Unsupported session manifest version")
    if manifest.get("status") != "complete" or manifest.get("unfinishedFiles"):
        raise AnalysisError("Session is incomplete; finish or recover it before analysis")
    chunks = manifest.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        raise AnalysisError("Completed session has no chunks")
    if not all(isinstance(chunk, dict) for chunk in chunks):
        raise AnalysisError("Invalid recording chunks in manifest")
    config = manifest.get("configuration", {})
    if not isinstance(config, dict):
        raise AnalysisError("Invalid recording configuration in manifest")
    fps = number(config.get("framesPerSecond", 1), "frames per second", 0.01)
    expected_audio_tracks = int(bool(config.get("recordMicrophone"))) + int(bool(config.get("recordSystemAudio")))
    ffmpeg, ffprobe = executable("ffmpeg"), executable("ffprobe")
    video_spans, silent_spans, available, metrics, warnings = [], [], [], [], []
    audio_complete = expected_audio_tracks > 0
    previous_end = 0
    previous_audio_ends_silent = False
    seen_paths = set()
    for chunk in sorted(chunks, key=lambda item: number(item.get("startOffsetSeconds"), "chunk start")):
        file_name = chunk.get("fileName")
        if not isinstance(file_name, str):
            raise AnalysisError("Missing chunk file name")
        path = (session / file_name).resolve()
        try:
            path.relative_to(session)
        except ValueError:
            raise AnalysisError("Chunk path escapes session folder")
        if not path.is_file() or path in seen_paths:
            raise AnalysisError("Missing or duplicate recording chunk: {}".format(file_name))
        seen_paths.add(path)
        start = number(chunk.get("startOffsetSeconds"), "chunk start")
        duration = number(chunk.get("durationSeconds"), "chunk duration", 0.000001)
        if start < previous_end - 0.001:
            raise AnalysisError("Recording chunks overlap")
        continuous_boundary = bool(available) and abs(start - previous_end) <= 0.000001
        previous_end = start + duration
        available.append((start, start + duration))
        metadata = probe(path, ffprobe)
        container_duration = number(metadata["format"].get("duration"), "container duration", 0.000001)
        if duration - container_duration > max(1.5 / fps, 0.1):
            raise AnalysisError("Recording ends before its completed manifest: {}".format(file_name))
        videos = [s for s in metadata["streams"] if s["codec_type"] == "video"]
        audios = [s for s in metadata["streams"] if s["codec_type"] == "audio"]
        if len(videos) != 1:
            raise AnalysisError("Expected exactly one screen video stream in {}".format(file_name))
        video = videos[0]
        actual_bytes = path.stat().st_size
        declared_bytes = chunk.get("byteCount")
        if declared_bytes is not None and actual_bytes != declared_bytes:
            raise AnalysisError("Recording size does not match completed manifest: {}".format(file_name))
        video_result = video_runs(path, video, ffmpeg, duration, fps)
        if chunk.get("videoFrames") is not None and chunk["videoFrames"] != video_result["count"]:
            raise AnalysisError("Decoded frame count does not match completed manifest: {}".format(file_name))
        video_spans.extend((start + a, start + b, digest) for a, b, digest in video_result["runs"])
        all_silent = [(0, duration)]
        audio_starts_silent = audio_ends_silent = bool(audios)
        for audio in audios:
            track_silence = audio_silence(path, audio, ffmpeg, duration, silence_db)
            track_start = max(0, number(audio.get("start_time", 0), "audio start", -math.inf))
            track_end = min(duration, track_start + number(audio.get("duration", 0), "audio duration"))
            audio_starts_silent = audio_starts_silent and bool(track_silence) and abs(track_silence[0][0] - track_start) < 0.001
            audio_ends_silent = audio_ends_silent and bool(track_silence) and abs(track_silence[-1][1] - track_end) < 0.001
            all_silent = intersect(all_silent, track_silence)
        if not audios or len(audios) < expected_audio_tracks or chunk.get("droppedAudioSamples", 0):
            audio_complete = False
            warnings.append("{}: audio is missing or has dropped samples; keep the entire session".format(file_name))
        else:
            chunk_silence = [(start + a, start + b) for a, b in all_silent]
            # AAC tracks can begin a fraction of one packet after the screen.
            # Bridge only that tiny boundary gap, never an actual sound event
            # inside a chunk or a manual recording pause.
            if (continuous_boundary and previous_audio_ends_silent and audio_starts_silent
                    and silent_spans and chunk_silence
                    and 0 <= chunk_silence[0][0] - silent_spans[-1][1] <= AUDIO_BOUNDARY_GAP):
                silent_spans[-1] = (silent_spans[-1][0], chunk_silence[0][1])
                chunk_silence = chunk_silence[1:]
            silent_spans.extend(chunk_silence)
        previous_audio_ends_silent = audio_ends_silent
        stream_metrics = []
        for stream in metadata["streams"]:
            stream_metrics.append({key: stream.get(key) for key in (
                "index", "codec_type", "codec_name", "profile", "width", "height", "pix_fmt",
                "sample_rate", "channels", "bit_rate", "start_time", "duration", "avg_frame_rate")
                if key in stream})
        metrics.append({"fileName": file_name, "startOffsetSeconds": start,
                        "durationSeconds": duration, "containerDurationSeconds": metadata["format"].get("duration"),
                        "bytes": actual_bytes, "videoFrames": video_result["count"],
                        "bitsPerSecond": round(actual_bytes * 8 / duration), "streams": stream_metrics})
    if not expected_audio_tracks:
        warnings.append("No audio was requested; screen-only footage cannot establish idle time")
    static_runs = merge_matching_runs(video_spans)
    candidate_evidence = []
    if audio_complete:
        # Keep distinct static images separate even when their intervals touch.
        for start, end, _ in static_runs:
            candidate_evidence.extend((a, b) for a, b in intersect([(start, end)], silent_spans)
                                      if b - a >= minimum_idle and b - a > 2 * margin)
    omitted = [(a + margin, b - margin) for a, b in candidate_evidence]
    retained = subtract(available, omitted)
    bytes_total = sum(chunk["bytes"] for chunk in metrics)
    recorded_duration = sum(b - a for a, b in available)
    omitted_duration = sum(b - a for a, b in omitted)
    disk = shutil.disk_usage(session)
    return {
        "schemaVersion": VERSION, "status": "complete", "sessionID": manifest.get("id"),
        "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        "recordingsModified": False, "automaticOmissionEnabled": False,
        "candidateCaveat": "An unchanged screen and silence can also mean reading or thinking. These are candidates, not proof of absence.",
        "policy": {"minimumIdleSeconds": minimum_idle, "preservedMarginSeconds": margin,
                   "silenceThresholdDB": silence_db, "visualCriterion": "identical full-resolution decoded frame hashes",
                   "maximumAudioChunkBoundaryGapSeconds": AUDIO_BOUNDARY_GAP,
                   "allRecordedAudioRequired": True, "timestampBasis": "original chunk offset plus media presentation timestamp"},
        "storage": {"recordingBytes": bytes_total, "recordedDurationSeconds": round(recorded_duration, 6),
                    "estimatedBytesPerHour": round(bytes_total / recorded_duration * 3600),
                    "averageBitsPerSecond": round(bytes_total / recorded_duration * 8),
                    "diskFreeBytes": disk.free, "diskTotalBytes": disk.total,
                    "bytesSaved": 0},
        "inferencePlan": {"candidateEvidenceIntervals": encoded(candidate_evidence),
                          "candidateOmissionIntervals": encoded(omitted),
                          "retainedIntervalsIfCandidatesOmitted": encoded(retained),
                          "originalRecordedIntervals": encoded(available),
                          "candidateSecondsSaved": round(omitted_duration, 6),
                          "candidateFractionSaved": round(omitted_duration / recorded_duration, 6)},
        "chunks": metrics, "warnings": warnings,
    }


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".analysis-", suffix=".tmp", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(payload, handle, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_folder", type=Path)
    parser.add_argument("--output", type=Path, help="JSON plan path; defaults to SESSION/analysis.json")
    parser.add_argument("--minimum-idle-seconds", type=float, default=180)
    parser.add_argument("--preserve-margin-seconds", type=float, default=30)
    parser.add_argument("--silence-db", type=float, default=-60)
    args = parser.parse_args()
    session = args.session_folder.resolve()
    output = (args.output or session / "analysis.json").resolve()
    if output.suffix != ".json" or output == session / "manifest.json":
        parser.error("Output must be a JSON file other than the source manifest")
    try:
        minimum_idle = number(args.minimum_idle_seconds, "minimum idle seconds", 1)
        margin = number(args.preserve_margin_seconds, "preserved margin")
        silence_db = number(args.silence_db, "silence threshold", -120)
        if silence_db > 0:
            raise AnalysisError("Silence threshold must be between -120 and 0 dB")
        payload = analyze(session, minimum_idle, margin, silence_db)
    except (AnalysisError, OSError, subprocess.SubprocessError, KeyError, TypeError, ValueError) as exc:
        payload = {"schemaVersion": VERSION, "status": "error", "recordingsModified": False, "error": str(exc)}
    write_json(output, payload)
    print(json.dumps({"status": payload["status"], "output": str(output), "error": payload.get("error")}))
    return 0 if payload["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
