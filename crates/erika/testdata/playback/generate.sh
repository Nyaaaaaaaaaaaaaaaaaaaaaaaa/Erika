#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FIXTURE_NAME="playback-fixture.mkv"
readonly FIXTURE_PATH="${SCRIPT_DIR}/${FIXTURE_NAME}"
readonly CHECKSUM_PATH="${SCRIPT_DIR}/SHA256SUMS"
readonly REQUIRED_VERSION="8.1.2"
readonly AV1_FIXTURE_NAMES=(
  "playback-fixture.mkv"
  "av1-video.mp4"
  "av1-video.mov"
  "av1-video.webm"
  "av1-video.ivf"
  "av1-video.obu"
  "static.avif"
)

usage() {
  cat <<'EOF'
Usage: ./generate.sh [--check | --update]

  --check   Rebuild twice, validate, and compare with the committed fixture.
            This is the default.
  --update  Rebuild twice, validate, replace the fixture, and refresh hashes.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

native_path() {
  case "$(uname -s)" in
    CYGWIN*) cygpath -w "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

mode="check"
case "${1:-}" in
  "" | --check)
    ;;
  --update)
    mode="update"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for tool in ffmpeg ffprobe sha256sum cmp awk; do
  command -v "${tool}" >/dev/null 2>&1 || fail "required tool not found: ${tool}"
done

check_version() {
  local tool="$1"
  local first_line
  first_line="$("${tool}" -version | awk 'NR == 1 { print; exit }')"
  case "${first_line}" in
    "${tool} version ${REQUIRED_VERSION}" | "${tool} version ${REQUIRED_VERSION} "* | "${tool} version ${REQUIRED_VERSION}-"*)
      ;;
    *)
      fail "${tool} ${REQUIRED_VERSION} is required; found: ${first_line}"
      ;;
  esac
}

check_version ffmpeg
check_version ffprobe

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/erika-playback-fixture.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

generate_fixture_set() {
  local output_dir="$1"
  local output="${output_dir}/${FIXTURE_NAME}"
  local output_native
  local script_dir_native

  mkdir -p "${output_dir}"
  output_native="$(native_path "${output}")"
  script_dir_native="$(native_path "${SCRIPT_DIR}")"

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -filter_threads 1 \
    -filter_complex_threads 1 \
    -f lavfi \
    -i "testsrc2=size=160x90:rate=30:duration=8" \
    -f lavfi \
    -i "aevalsrc=0.25*sin(2*PI*880*t)*lt(mod(t\,1)\,0.1):sample_rate=48000:duration=8:channel_layout=mono" \
    -f lavfi \
    -i "aevalsrc=0.25*sin(2*PI*1320*t)*lt(mod(t\,1)\,0.1):sample_rate=48000:duration=8:channel_layout=mono" \
    -f srt \
    -i "${script_dir_native}/track-a.srt" \
    -f srt \
    -i "${script_dir_native}/track-b.srt" \
    -map 0:v:0 \
    -map 1:a:0 \
    -map 2:a:0 \
    -map 3:s:0 \
    -map 4:s:0 \
    -map_metadata -1 \
    -fflags +bitexact \
    -c:v libaom-av1 \
    -cpu-used:v 8 \
    -row-mt:v 0 \
    -tiles:v 1x1 \
    -lag-in-frames:v 0 \
    -crf:v 35 \
    -b:v 0 \
    -pix_fmt yuv420p \
    -r:v 30 \
    -g:v 30 \
    -keyint_min:v 30 \
    -sc_threshold:v 0 \
    -threads:v 1 \
    -flags:v +bitexact \
    -c:a flac \
    -sample_fmt:a s16 \
    -ar:a 48000 \
    -ac:a 1 \
    -compression_level:a 5 \
    -threads:a 1 \
    -flags:a +bitexact \
    -c:s copy \
    -metadata title="Erika deterministic playback fixture" \
    -metadata:s:v:0 title="deterministic-testsrc2" \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:0 title="pulse-880-hz" \
    -metadata:s:a:1 language=jpn \
    -metadata:s:a:1 title="pulse-1320-hz" \
    -metadata:s:s:0 language=eng \
    -metadata:s:s:0 title="track-a" \
    -metadata:s:s:1 language=jpn \
    -metadata:s:s:1 title="track-b" \
    -disposition:v:0 default \
    -disposition:a:0 default \
    -disposition:a:1 0 \
    -disposition:s:0 default \
    -disposition:s:1 0 \
    -t 8 \
    -bitexact \
    -f matroska \
    -y "${output_native}"

  # The MP4/MOV demuxer family is exercised with both common filename forms.
  # FFmpeg's AV1 muxing policy requires the ISO-BMFF flavour even for .mov.
  ffmpeg -hide_banner -loglevel error -nostdin -i "${output_native}" -map 0:v:0 \
    -map_metadata -1 -frames:v 30 -c:v copy -fflags +bitexact -bitexact \
    -f mp4 -y "$(native_path "${output_dir}/av1-video.mp4")"
  ffmpeg -hide_banner -loglevel error -nostdin -i "${output_native}" -map 0:v:0 \
    -map_metadata -1 -frames:v 30 -c:v copy -fflags +bitexact -bitexact \
    -f mp4 -y "$(native_path "${output_dir}/av1-video.mov")"
  ffmpeg -hide_banner -loglevel error -nostdin -i "${output_native}" -map 0:v:0 \
    -map_metadata -1 -frames:v 30 -c:v copy -fflags +bitexact -bitexact \
    -f webm -y "$(native_path "${output_dir}/av1-video.webm")"
  ffmpeg -hide_banner -loglevel error -nostdin -i "${output_native}" -map 0:v:0 \
    -map_metadata -1 -frames:v 30 -c:v copy -fflags +bitexact -bitexact \
    -f ivf -y "$(native_path "${output_dir}/av1-video.ivf")"
  # Encode raw low-overhead OBU directly so the sequence header is carried in
  # band; remuxing the Matroska track would leave it only in codec extradata.
  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -filter_threads 1 \
    -f lavfi \
    -i "testsrc2=size=160x90:rate=30:duration=1" \
    -map_metadata -1 \
    -frames:v 30 \
    -c:v libaom-av1 \
    -cpu-used:v 8 \
    -row-mt:v 0 \
    -tiles:v 1x1 \
    -lag-in-frames:v 0 \
    -crf:v 35 \
    -b:v 0 \
    -pix_fmt yuv420p \
    -r:v 30 \
    -g:v 30 \
    -keyint_min:v 30 \
    -threads:v 1 \
    -flags:v +bitexact \
    -fflags +bitexact \
    -bitexact \
    -f obu \
    -y "$(native_path "${output_dir}/av1-video.obu")"

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -filter_threads 1 \
    -f lavfi \
    -i "testsrc2=size=160x90:rate=1:duration=1" \
    -map_metadata -1 \
    -frames:v 1 \
    -c:v libaom-av1 \
    -still-picture 1 \
    -cpu-used:v 8 \
    -row-mt:v 0 \
    -tiles:v 1x1 \
    -threads:v 1 \
    -lag-in-frames:v 0 \
    -crf:v 35 \
    -b:v 0 \
    -pix_fmt yuv420p \
    -flags:v +bitexact \
    -bitexact \
    -f avif \
    -y "$(native_path "${output_dir}/static.avif")"
}

probe_stream_field() {
  local file="$1"
  local selector="$2"
  local field="$3"

  ffprobe \
    -v error \
    -select_streams "${selector}" \
    -show_entries "stream=${field}" \
    -of default=noprint_wrappers=1:nokey=1 \
    "$(native_path "${file}")" | tr -d '\r'
}

expect_stream_field() {
  local file="$1"
  local selector="$2"
  local field="$3"
  local expected="$4"
  local actual

  actual="$(probe_stream_field "${file}" "${selector}" "${field}")"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${selector} ${field}: expected '${expected}', got '${actual}'"
}

validate_fixture() {
  local file="$1"
  local stream_count
  local duration
  local frame_count
  local keyframes
  local expected_keyframes
  local native_file

  native_file="$(native_path "${file}")"

  stream_count="$(
    ffprobe \
      -v error \
      -show_entries stream=index \
      -of csv=p=0 \
      "${native_file}" | awk 'END { print NR }'
  )"
  [[ "${stream_count}" == "5" ]] || fail "expected 5 streams, got ${stream_count}"

  # Absolute indices make the expected Matroska stream order explicit.
  expect_stream_field "${file}" v:0 index 0
  expect_stream_field "${file}" v:0 codec_name av1
  expect_stream_field "${file}" v:0 width 160
  expect_stream_field "${file}" v:0 height 90
  expect_stream_field "${file}" v:0 r_frame_rate 30/1
  expect_stream_field "${file}" v:0 has_b_frames 0

  expect_stream_field "${file}" a:0 index 1
  expect_stream_field "${file}" a:0 codec_name flac
  expect_stream_field "${file}" a:0 sample_rate 48000
  expect_stream_field "${file}" a:0 channels 1

  expect_stream_field "${file}" a:1 index 2
  expect_stream_field "${file}" a:1 codec_name flac
  expect_stream_field "${file}" a:1 sample_rate 48000
  expect_stream_field "${file}" a:1 channels 1

  expect_stream_field "${file}" s:0 index 3
  expect_stream_field "${file}" s:0 codec_name subrip
  expect_stream_field "${file}" s:1 index 4
  expect_stream_field "${file}" s:1 codec_name subrip

  duration="$(
    ffprobe \
      -v error \
      -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 \
      "${native_file}"
  )"
  awk -v duration="${duration}" \
    'BEGIN { exit !(duration >= 7.999 && duration <= 8.001) }' ||
    fail "expected 8.000 seconds, got ${duration}"

  frame_count="$(
    ffprobe \
      -v error \
      -count_frames \
      -select_streams v:0 \
      -show_entries stream=nb_read_frames \
      -of default=noprint_wrappers=1:nokey=1 \
      "${native_file}" | tr -d '\r'
  )"
  [[ "${frame_count}" == "240" ]] || fail "expected 240 video frames, got ${frame_count}"

  keyframes="$(
    ffprobe \
      -v error \
      -select_streams v:0 \
      -show_entries packet=pts_time,flags \
      -of csv=p=0 \
      "${native_file}" |
      awk -F, '$2 ~ /K/ { printf "%.6f\n", $1 }'
  )"
  expected_keyframes="$(cat <<'EOF'
0.000000
1.000000
2.000000
3.000000
4.000000
5.000000
6.000000
7.000000
EOF
  )"
  [[ "${keyframes}" == "${expected_keyframes}" ]] ||
    fail "unexpected keyframe timestamps:\n${keyframes}"
}

validate_visual_fixture() {
  local file="$1"
  local expected_frames="$2"
  local frame_count
  local native_file

  native_file="$(native_path "${file}")"

  expect_stream_field "${file}" v:0 codec_name av1
  expect_stream_field "${file}" v:0 width 160
  expect_stream_field "${file}" v:0 height 90
  frame_count="$(
    ffprobe \
      -v error \
      -count_frames \
      -select_streams v:0 \
      -show_entries stream=nb_read_frames \
      -of default=noprint_wrappers=1:nokey=1 \
      "${native_file}" | tr -d '\r'
  )"
  [[ "${frame_count}" == "${expected_frames}" ]] ||
    fail "${file}: expected ${expected_frames} frames, got ${frame_count}"
}

first_build="${tmp_dir}/first"
second_build="${tmp_dir}/second"

generate_fixture_set "${first_build}"
generate_fixture_set "${second_build}"
for fixture in "${AV1_FIXTURE_NAMES[@]}"; do
  cmp -s "${first_build}/${fixture}" "${second_build}/${fixture}" ||
    fail "two clean builds of ${fixture} are not byte-for-byte identical"
done
validate_fixture "${first_build}/${FIXTURE_NAME}"
for fixture in av1-video.mp4 av1-video.mov av1-video.webm av1-video.ivf av1-video.obu; do
  validate_visual_fixture "${first_build}/${fixture}" 30
done
validate_visual_fixture "${first_build}/static.avif" 1

if [[ "${mode}" == "update" ]]; then
  for fixture in "${AV1_FIXTURE_NAMES[@]}"; do
    cp "${first_build}/${fixture}" "${SCRIPT_DIR}/${fixture}"
  done
  (
    cd "${SCRIPT_DIR}"
    sha256sum "${AV1_FIXTURE_NAMES[@]}" track-a.srt track-b.srt >"${CHECKSUM_PATH}"
  )
else
  [[ -f "${FIXTURE_PATH}" ]] || fail "fixture is missing: ${FIXTURE_PATH}"
  [[ -f "${CHECKSUM_PATH}" ]] || fail "checksum file is missing: ${CHECKSUM_PATH}"
  cmp -s "${first_build}/${FIXTURE_NAME}" "${FIXTURE_PATH}" ||
    fail "committed fixture differs from a clean build; run ./generate.sh --update intentionally"
  for fixture in "${AV1_FIXTURE_NAMES[@]:1}"; do
    [[ -f "${SCRIPT_DIR}/${fixture}" ]] || fail "fixture is missing: ${fixture}"
    cmp -s "${first_build}/${fixture}" "${SCRIPT_DIR}/${fixture}" ||
      fail "committed ${fixture} differs from a clean build; run ./generate.sh --update intentionally"
  done
fi

(
  cd "${SCRIPT_DIR}"
  sha256sum -c SHA256SUMS
)

printf 'ok: AV1/AVIF fixture set is deterministic and structurally valid\n'
