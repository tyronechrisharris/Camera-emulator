#!/usr/bin/env bash
set -Eeuo pipefail

for dependency in ffmpeg ffprobe python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$dependency" >&2
    exit 2
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_dir}/.." && pwd)"
source_dir="${repository_root}/assets"
prepared_dir="${source_dir}/prepared"
force_prepare="${FORCE_PREPARE_ASSETS:-0}"
recipe_version="h264-640x480-15fps-gop15-x264-medium-crf23-aac128k-v1"
recipe_path="${prepared_dir}/.recipe-version"

if [[ "$force_prepare" != 0 && "$force_prepare" != 1 ]]; then
  printf 'error: FORCE_PREPARE_ASSETS must be 0 or 1\n' >&2
  exit 2
fi

mkdir -p "$prepared_dir"

declare -a temporary_files=()
cleanup() {
  local temporary_file
  if ((${#temporary_files[@]})); then
    for temporary_file in "${temporary_files[@]}"; do
      rm -f -- "$temporary_file"
    done
  fi
}
trap cleanup EXIT

prepare_asset() {
  local name="$1"
  local source_path="${source_dir}/${name}"
  local output_path="${prepared_dir}/${name}"
  local temporary_path
  local current_recipe=""

  if [[ ! -f "$source_path" ]]; then
    printf 'error: source asset is missing: %s\n' "$source_path" >&2
    return 1
  fi

  if [[ -f "$recipe_path" ]]; then
    current_recipe="$(<"$recipe_path")"
  fi

  if [[ "$force_prepare" == 0 \
      && "$current_recipe" == "$recipe_version" \
      && -f "$output_path" \
      && "$output_path" -nt "$source_path" ]]; then
    if "${script_dir}/validate-assets.sh" "$output_path" >/dev/null 2>&1; then
      printf 'prepared asset is current: %s\n' "$output_path"
      return 0
    fi
    printf 'prepared asset failed validation; rebuilding: %s\n' "$output_path" >&2
  fi

  temporary_path="$(mktemp "${output_path}.tmp.XXXXXX")"
  temporary_files+=("$temporary_path")
  printf 'normalizing %s -> %s\n' "$source_path" "$output_path"

  ffmpeg \
    -hide_banner \
    -nostdin \
    -loglevel warning \
    -y \
    -i "$source_path" \
    -map 0:v:0 \
    -map '0:a:0?' \
    -map_metadata -1 \
    -vf 'scale=640:480:flags=lanczos,setsar=1,fps=15' \
    -c:v libx264 \
    -preset medium \
    -crf 23 \
    -pix_fmt yuv420p \
    -profile:v high \
    -level:v 3.1 \
    -g 15 \
    -keyint_min 15 \
    -sc_threshold 0 \
    -x264-params 'open-gop=0' \
    -c:a aac \
    -b:a 128k \
    -ar 44100 \
    -ac 2 \
    -movflags +faststart \
    -f mp4 \
    "$temporary_path"

  "${script_dir}/validate-assets.sh" "$temporary_path"
  chmod 0644 "$temporary_path"
  mv -f -- "$temporary_path" "$output_path"
  printf 'prepared asset ready: %s\n' "$output_path"
}

prepare_asset RPM_1.mp4
prepare_asset RPM_2.mp4

"${script_dir}/validate-assets.sh"
recipe_temporary_path="$(mktemp "${recipe_path}.tmp.XXXXXX")"
temporary_files+=("$recipe_temporary_path")
printf '%s\n' "$recipe_version" >"$recipe_temporary_path"
chmod 0644 "$recipe_temporary_path"
mv -f -- "$recipe_temporary_path" "$recipe_path"
printf '%s\n' 'asset preparation complete'
