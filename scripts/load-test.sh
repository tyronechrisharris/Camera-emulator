#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v ffmpeg >/dev/null 2>&1; then
  printf 'error: required command not found: ffmpeg\n' >&2
  exit 2
fi

rtsp_host="${RTSP_HOST:-127.0.0.1}"
rtsp_port="${RTSP_PORT:-8554}"
duration_seconds="${1:-${LOAD_TEST_DURATION_SECONDS:-75}}"
io_timeout_seconds="${LOAD_TEST_IO_TIMEOUT_SECONDS:-10}"
log_dir="${LOAD_TEST_LOG_DIR:-./load-test-logs}"

if [[ ! "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: duration must be a positive integer number of seconds\n' >&2
  exit 2
fi
if [[ ! "$io_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: LOAD_TEST_IO_TIMEOUT_SECONDS must be a positive integer\n' >&2
  exit 2
fi

mkdir -p "$log_dir"

declare -a child_pids=()
declare -a camera_paths=()

terminate_children() {
  local pid

  for pid in "${child_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${child_pids[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
}

handle_interrupt() {
  local signal="$1"
  local exit_status="$2"

  trap - INT TERM
  printf 'load test interrupted by %s; stopping all readers\n' "$signal" >&2
  terminate_children
  exit "$exit_status"
}

trap 'handle_interrupt INT 130' INT
trap 'handle_interrupt TERM 143' TERM

read_timeout_microseconds=$((io_timeout_seconds * 1000000))

printf 'starting 50 RTSP/TCP readers for %s second(s)\n' "$duration_seconds"
printf 'per-camera logs: %s\n' "$log_dir"

# Start every reader before waiting for any of them so all 50 connections are
# active concurrently for the requested load-test interval.
for ((camera_number = 1; camera_number <= 50; camera_number++)); do
  printf -v camera_path 'cam_%02d' "$camera_number"
  camera_paths[camera_number]="$camera_path"
  camera_url="rtsp://${rtsp_host}:${rtsp_port}/${camera_path}"
  camera_log="${log_dir}/${camera_path}.log"

  ffmpeg \
    -hide_banner \
    -nostdin \
    -loglevel info \
    -rtsp_transport tcp \
    -timeout "$read_timeout_microseconds" \
    -analyzeduration 20000000 \
    -probesize 10000000 \
    -i "$camera_url" \
    -t "$duration_seconds" \
    -map 0:v:0 \
    -map 0:a:0 \
    -c copy \
    -f null \
    - >"$camera_log" 2>&1 &
  child_pids[camera_number]=$!
done

failure_count=0

# Wait for every PID, including after an earlier reader has failed.  Reporting
# remains in cam_01..cam_50 order regardless of child completion order.
for ((camera_number = 1; camera_number <= 50; camera_number++)); do
  camera_path="${camera_paths[camera_number]}"
  camera_log="${log_dir}/${camera_path}.log"
  if wait "${child_pids[camera_number]}"; then
    printf 'PASS %s\n' "$camera_path"
  else
    child_status=$?
    failure_count=$((failure_count + 1))
    printf 'FAIL %s: ffmpeg exited %s (log: %s)\n' \
      "$camera_path" "$child_status" "$camera_log" >&2
  fi
done

trap - INT TERM

if ((failure_count > 0)); then
  printf 'load test failed: %d/50 reader(s) failed\n' "$failure_count" >&2
  exit 1
fi

printf 'load test passed: all 50 readers completed %s second(s)\n' \
  "$duration_seconds"
