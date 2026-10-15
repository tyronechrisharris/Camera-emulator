#!/usr/bin/env bash
set -Eeuo pipefail

git diff --check

python3 - <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


root = Path.cwd()
compose_path = root / "docker-compose.yml"
mediamtx_path = root / "mediamtx.yml"
readme_path = root / "README.md"
prepare_path = root / "scripts" / "prepare-assets.sh"
validate_path = root / "scripts" / "validate-assets.sh"


def fail(message: str) -> None:
    print(f"verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


for path in (compose_path, mediamtx_path, readme_path, prepare_path, validate_path):
    if not path.is_file():
        fail(f"required file is missing: {path.relative_to(root)}")

compose = compose_path.read_text(encoding="utf-8")
mediamtx = mediamtx_path.read_text(encoding="utf-8")
readme = readme_path.read_text(encoding="utf-8")

# The Pi deployment must have one MediaMTX service and no more than two
# stream-copy publishers.  This deliberately rejects the original one-container
# (and one encoder) per camera scaling model.
service_names: list[str] = []
in_services = False
for line in compose.splitlines():
    if re.fullmatch(r"services:\s*", line):
        in_services = True
        continue
    if in_services and line and not line.startswith((" ", "\t", "#")):
        break
    match = re.fullmatch(r"  ([A-Za-z0-9_.-]+):\s*", line)
    if in_services and match:
        service_names.append(match.group(1))

if "mediamtx" not in service_names:
    fail("docker-compose.yml must define a mediamtx service")
if not 2 <= len(service_names) <= 3:
    fail(f"expected 2-3 total services, found {len(service_names)}: {service_names}")

# Only deployment/runtime commands belong in this check. The preparation
# script intentionally performs each source transcode once before containers
# start; neither publisher is allowed to contain an encoder or video filter.
runtime_paths = (
    compose_path,
    root / "scripts" / "smoke-test.sh",
    root / "scripts" / "load-test.sh",
)
runtime_text = "\n".join(
    path.read_text(encoding="utf-8") for path in runtime_paths if path.is_file()
)

for forbidden in (
    r"\blibx26[45]\b",
    r"\bdrawtext\b",
    r"(?:^|[\s,])scale=",
    r"(?:^|[\s,])fps=",
    r"(?:^|[\s\"'])-vf(?:[\s\"']|$)",
    r"(?:^|[\s\"'])-filter(?:_complex)?(?:[\s\"']|$)",
):
    if re.search(forbidden, runtime_text, flags=re.IGNORECASE | re.MULTILINE):
        fail(f"runtime configuration contains a transcoding/filter token matching {forbidden!r}")

if not re.search(r"(?:-c(?::[va])?\s*[\"']?\s*copy|[\"']-c(?::[va])?[\"']\s*\n\s*-?\s*[\"']copy[\"'])", runtime_text):
    fail("publisher command must explicitly use FFmpeg stream copy (-c copy or -c:v/-c:a copy)")

for asset in ("RPM_1.mp4", "RPM_2.mp4"):
    if f"/assets/prepared/{asset}" not in compose:
        fail(f"publisher configuration does not reference prepared asset {asset}")

if not re.search(r"\./assets\s*:/assets\s*:ro\b", compose):
    fail("assets must be mounted read-only at /assets")
if "nofile" not in compose or "65536" not in compose:
    fail("services must raise the nofile limit to at least 65536")
if re.search(r"(?:image:\s*\S*:latest\b|image:\s*\S+\n)", compose):
    # Every image must be version/digest pinned.  A bare image name also tracks
    # latest implicitly.
    for line in compose.splitlines():
        stripped = line.strip()
        if stripped.startswith("image:"):
            image = stripped.split(None, 1)[1]
            tail = image.rsplit("/", 1)[-1]
            if image.endswith(":latest") or (":" not in tail and "@sha256:" not in image):
                fail(f"container image is not pinned: {image}")

prepare = prepare_path.read_text(encoding="utf-8")
for required_pattern in (
    r"(?m)^\s+-c:v libx264\s*\\?$",
    r"(?m)^\s+-g 15\s*\\?$",
    r"(?m)^\s+-keyint_min 15\s*\\?$",
    r"(?m)^\s+-sc_threshold 0\s*\\?$",
    r"open-gop=0",
    r"fps=15",
    r"scale=640:480",
):
    if not re.search(required_pattern, prepare):
        fail(f"asset preparation is missing required setting {required_pattern!r}")

validate = validate_path.read_text(encoding="utf-8")
if "MAX_KEYFRAME_GAP_SECONDS = 1.2" not in validate:
    fail("prepared-asset validation must enforce a 1.2-second keyframe-gap limit")
if "SMOKE_MAX_KEYFRAME_GAP_SECONDS" not in (root / "scripts" / "smoke-test.sh").read_text(encoding="utf-8"):
    fail("live smoke test must verify keyframe cadence")

gitignore = (root / ".gitignore").read_text(encoding="utf-8")
if "assets/prepared/" not in gitignore:
    fail("generated prepared assets must remain ignored")

# Fifty explicit paths make the externally observable contract unambiguous and
# let deployment checks enumerate the same stable URLs.
camera_ids = sorted({int(value) for value in re.findall(r"(?m)^\s{2}cam_(\d{2}):\s*$", mediamtx)})
expected_ids = list(range(1, 51))
if camera_ids != expected_ids:
    fail(f"expected explicit paths cam_01..cam_50; found {len(camera_ids)} valid path(s)")

blocks = re.split(r"(?m)(?=^  cam_\d{2}:\s*$)", mediamtx)
camera_blocks = [block for block in blocks if re.match(r"^  cam_\d{2}:\s*$", block.splitlines()[0])]
if len(camera_blocks) != 50:
    fail(f"expected 50 camera path blocks, found {len(camera_blocks)}")

source_counts = {"source_01": 0, "source_02": 0}
for block in camera_blocks:
    name = re.match(r"^  (cam_\d{2}):", block).group(1)
    if not re.search(r"(?m)^\s+sourceOnDemand:\s*true\s*$", block):
        fail(f"{name} must enable sourceOnDemand")
    match = re.search(r"rtsp://(?:127\.0\.0\.1|localhost):8554/(source_0[12])\b", block)
    if not match:
        fail(f"{name} must proxy one of the two local source paths")
    source_counts[match.group(1)] += 1

if source_counts != {"source_01": 25, "source_02": 25}:
    fail(f"camera paths must be balanced 25/25 across both assets, got {source_counts}")

for source in source_counts:
    if not re.search(rf"(?m)^\s{{2}}{source}:\s*$", mediamtx):
        fail(f"missing publisher path {source}")

for endpoint in ("cam_01", "cam_50"):
    if endpoint not in readme:
        fail(f"README must document the camera endpoint range ({endpoint} missing)")
if "50" not in readme or not re.search(r"stream.?copy|without transcoding|no transcoding", readme, re.IGNORECASE):
    fail("README must document the 50-stream, no-transcoding design")

print("static camera-emulator contract checks passed")
PY

if [[ -d scripts ]]; then
  while IFS= read -r -d '' script; do
    bash -n "$script"
  done < <(find scripts -type f -name '*.sh' -print0)
fi

# Validate source media properties when ffprobe is available in the verifier
# image.  Deployment verification repeats this against all 50 RTSP endpoints.
if command -v ffprobe >/dev/null 2>&1; then
  for asset in assets/RPM_1.mp4 assets/RPM_2.mp4; do
    values="$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height,r_frame_rate \
      -of csv=p=0 "$asset")"
    [[ "$values" == h264,640,480,15/1 ]]
  done
  if [[ -f assets/prepared/RPM_1.mp4 && -f assets/prepared/RPM_2.mp4 ]]; then
    scripts/validate-assets.sh
  fi
fi

printf '%s\n' 'fleet verifier passed'
