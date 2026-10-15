#!/usr/bin/env bash
set -Eeuo pipefail

for dependency in ffprobe python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$dependency" >&2
    exit 2
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_dir}/.." && pwd)"

if (($# > 0)); then
  asset_paths=("$@")
else
  asset_paths=(
    "${repository_root}/assets/prepared/RPM_1.mp4"
    "${repository_root}/assets/prepared/RPM_2.mp4"
  )
fi

python3 - "${asset_paths[@]}" <<'PY'
from __future__ import annotations

import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any


MAX_KEYFRAME_GAP_SECONDS = 1.2
MIN_FPS = 14.5
MAX_FPS = 15.5


def fail(path: Path, message: str) -> None:
    print(f"FAIL {path}: {message}", file=sys.stderr)
    raise ValueError(message)


def run_probe(path: Path, *arguments: str) -> dict[str, Any]:
    completed = subprocess.run(
        ["ffprobe", "-v", "error", *arguments, "-of", "json", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = " ".join(completed.stderr.split())[-500:] or "no diagnostic output"
        fail(path, f"ffprobe exited {completed.returncode}: {detail}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        fail(path, f"ffprobe returned invalid JSON: {exc}")


def timestamp(frame: dict[str, Any]) -> float | None:
    value = frame.get("best_effort_timestamp_time")
    if value is None:
        value = frame.get("pts_time")
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def validate(path: Path) -> None:
    if not path.is_file():
        fail(path, "prepared asset is missing; run scripts/prepare-assets.sh")
    if path.stat().st_size == 0:
        fail(path, "prepared asset is empty")

    metadata = run_probe(
        path,
        "-show_entries",
        (
            "stream=index,codec_type,codec_name,width,height,avg_frame_rate,"
            "r_frame_rate:format=duration"
        ),
    )
    streams = metadata.get("streams")
    if not isinstance(streams, list):
        fail(path, "stream metadata is missing")

    video_streams = [
        stream
        for stream in streams
        if isinstance(stream, dict) and stream.get("codec_type") == "video"
    ]
    if len(video_streams) != 1:
        fail(path, f"expected one video stream; observed {len(video_streams)}")
    video = video_streams[0]
    observed_video = (
        video.get("codec_name"),
        video.get("width"),
        video.get("height"),
        video.get("avg_frame_rate"),
    )
    if observed_video != ("h264", 640, 480, "15/1"):
        fail(
            path,
            "expected H.264 640x480 at 15/1 fps; observed "
            f"{observed_video[0]} {observed_video[1]}x{observed_video[2]} "
            f"at {observed_video[3]}",
        )

    audio_streams = [
        stream
        for stream in streams
        if isinstance(stream, dict) and stream.get("codec_type") == "audio"
    ]
    if len(audio_streams) != 1 or audio_streams[0].get("codec_name") != "aac":
        observed_audio = ", ".join(
            str(stream.get("codec_name", "unknown")) for stream in audio_streams
        ) or "none"
        fail(path, f"expected one AAC audio stream; observed {observed_audio}")

    frame_payload = run_probe(
        path,
        "-select_streams",
        "v:0",
        "-show_frames",
        "-show_entries",
        "frame=key_frame,pict_type,width,height,pts_time,best_effort_timestamp_time",
    )
    frames = frame_payload.get("frames")
    if not isinstance(frames, list):
        fail(path, "frame metadata is missing")
    frames = [frame for frame in frames if isinstance(frame, dict)]
    if len(frames) < 30:
        fail(path, f"expected at least 30 video frames; observed {len(frames)}")
    if any(frame.get("width") != 640 or frame.get("height") != 480 for frame in frames):
        fail(path, "decoded frame dimensions are not consistently 640x480")

    timestamps = [value for frame in frames if (value := timestamp(frame)) is not None]
    deltas = [
        later - earlier
        for earlier, later in zip(timestamps, timestamps[1:])
        if later > earlier
    ]
    if len(deltas) < 20:
        fail(path, "not enough timestamps to measure the frame rate")
    median_period = statistics.median(deltas)
    observed_fps = 1.0 / median_period
    if not MIN_FPS <= observed_fps <= MAX_FPS:
        fail(path, f"expected 15 fps; measured approximately {observed_fps:.3f} fps")

    keyframe_timestamps = [
        value
        for frame in frames
        if str(frame.get("key_frame")) == "1"
        and (value := timestamp(frame)) is not None
    ]
    if len(keyframe_timestamps) < 2:
        fail(path, f"expected multiple keyframes; observed {len(keyframe_timestamps)}")
    keyframe_gaps = [
        later - earlier
        for earlier, later in zip(keyframe_timestamps, keyframe_timestamps[1:])
    ]

    try:
        container_duration = float(metadata["format"]["duration"])
    except (KeyError, TypeError, ValueError):
        fail(path, "container duration is unavailable")
    # The next loop starts with the first keyframe. Include that seam in the
    # cadence check because this file is continuously looped with stream copy.
    seam_gap = (
        container_duration - keyframe_timestamps[-1] + keyframe_timestamps[0]
    )
    maximum_gap = max(*keyframe_gaps, seam_gap)
    if maximum_gap > MAX_KEYFRAME_GAP_SECONDS + 0.001:
        fail(
            path,
            f"maximum keyframe gap is {maximum_gap:.3f}s "
            f"(limit {MAX_KEYFRAME_GAP_SECONDS:.3f}s, including loop seam)",
        )

    first_frame_time = timestamps[0]
    first_keyframe_time = keyframe_timestamps[0]
    if first_keyframe_time - first_frame_time > 0.100:
        fail(
            path,
            f"first independently decodable frame begins after "
            f"{first_keyframe_time - first_frame_time:.3f}s",
        )

    print(
        f"PASS {path}: {observed_fps:.3f} fps, "
        f"{len(keyframe_timestamps)} keyframes, max gap {maximum_gap:.3f}s"
    )


failures = 0
for argument in sys.argv[1:]:
    try:
        validate(Path(argument))
    except ValueError:
        failures += 1

if failures:
    print(f"asset validation failed: {failures}/{len(sys.argv) - 1} file(s)", file=sys.stderr)
    raise SystemExit(1)

print(f"asset validation passed: {len(sys.argv) - 1} file(s)")
PY
