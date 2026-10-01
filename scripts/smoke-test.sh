#!/usr/bin/env bash
set -Eeuo pipefail

for dependency in python3 ffprobe; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$dependency" >&2
    exit 2
  fi
done

export RTSP_HOST="${RTSP_HOST:-127.0.0.1}"
export RTSP_PORT="${RTSP_PORT:-8554}"
export SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-15}"
export SMOKE_PARALLELISM="${SMOKE_PARALLELISM:-10}"

python3 - <<'PY'
from __future__ import annotations

import concurrent.futures
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


CAMERA_PATHS = tuple(f"cam_{number:02d}" for number in range(1, 51))


def configuration_error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


host = os.environ["RTSP_HOST"]
port = os.environ["RTSP_PORT"]

try:
    timeout_seconds = float(os.environ["SMOKE_TIMEOUT_SECONDS"])
except ValueError:
    configuration_error("SMOKE_TIMEOUT_SECONDS must be a number")
if timeout_seconds <= 0:
    configuration_error("SMOKE_TIMEOUT_SECONDS must be greater than zero")

try:
    parallelism = int(os.environ["SMOKE_PARALLELISM"])
except ValueError:
    configuration_error("SMOKE_PARALLELISM must be an integer")
if not 1 <= parallelism <= len(CAMERA_PATHS):
    configuration_error(
        f"SMOKE_PARALLELISM must be between 1 and {len(CAMERA_PATHS)}"
    )

# This is an additional network-level bound inside ffprobe.  Python's subprocess
# timeout below remains the authoritative wall-clock bound for every probe.
read_timeout_microseconds = max(1, int(timeout_seconds * 1_000_000))


@dataclass(frozen=True)
class ProbeResult:
    path: str
    error: str | None = None


def compact_error(value: str | bytes | None) -> str:
    if value is None:
        return "no diagnostic output"
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    compact = " ".join(value.split())
    return compact[-500:] if compact else "no diagnostic output"


def stream_description(stream: dict[str, Any]) -> str:
    stream_type = stream.get("codec_type", "unknown")
    codec = stream.get("codec_name", "unknown")
    if stream_type == "video":
        return (
            f"video={codec} "
            f"{stream.get('width', '?')}x{stream.get('height', '?')} "
            f"{stream.get('r_frame_rate', '?')}"
        )
    return f"{stream_type}={codec}"


def probe(path: str) -> ProbeResult:
    url = f"rtsp://{host}:{port}/{path}"
    command = [
        "ffprobe",
        "-v",
        "error",
        "-rtsp_transport",
        "tcp",
        "-rw_timeout",
        str(read_timeout_microseconds),
        "-show_entries",
        "stream=codec_type,codec_name,width,height,r_frame_rate",
        "-of",
        "json",
        url,
    ]

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        return ProbeResult(
            path,
            f"timed out after {timeout_seconds:g}s: {compact_error(exc.stderr)}",
        )
    except OSError as exc:
        return ProbeResult(path, f"could not run ffprobe: {exc}")

    if completed.returncode != 0:
        return ProbeResult(
            path,
            f"ffprobe exited {completed.returncode}: {compact_error(completed.stderr)}",
        )

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        return ProbeResult(path, f"ffprobe returned invalid JSON: {exc}")

    streams = payload.get("streams")
    if not isinstance(streams, list):
        return ProbeResult(path, "ffprobe response did not contain a streams list")

    video_ok = any(
        stream.get("codec_type") == "video"
        and stream.get("codec_name") == "h264"
        and stream.get("width") == 640
        and stream.get("height") == 480
        and stream.get("r_frame_rate") == "15/1"
        for stream in streams
        if isinstance(stream, dict)
    )
    audio_ok = any(
        stream.get("codec_type") == "audio" and stream.get("codec_name") == "aac"
        for stream in streams
        if isinstance(stream, dict)
    )

    if video_ok and audio_ok:
        return ProbeResult(path)

    observed = ", ".join(
        stream_description(stream) for stream in streams if isinstance(stream, dict)
    )
    missing: list[str] = []
    if not video_ok:
        missing.append("H264 video at 640x480 and 15/1 fps")
    if not audio_ok:
        missing.append("AAC audio")
    return ProbeResult(
        path,
        f"missing {' and '.join(missing)}; observed: {observed or 'no streams'}",
    )


with concurrent.futures.ThreadPoolExecutor(max_workers=parallelism) as executor:
    # executor.map preserves CAMERA_PATHS order even though probes run in
    # parallel, so output and failure diagnostics are deterministic.
    results = tuple(executor.map(probe, CAMERA_PATHS))

failures = tuple(result for result in results if result.error is not None)
for result in results:
    if result.error is None:
        print(f"PASS {result.path}")
    else:
        print(f"FAIL {result.path}: {result.error}", file=sys.stderr)

if failures:
    print(
        f"smoke test failed: {len(failures)}/{len(CAMERA_PATHS)} path(s) failed",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"smoke test passed: all {len(CAMERA_PATHS)} camera paths are valid")
PY
