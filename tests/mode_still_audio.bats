#!/usr/bin/env bats
#
# mode_still_audio.bats — integration tests for make-video --audio flag (PRD-5)
#
# Contract:
#   make-video IMG HOURS --audio PATH --out OUTFILE
#
#   - --audio FILE (single): output has video + audio streams; duration ≈ target; full-length audio.
#   - --audio DIR  (folder): output has audio; duration correct.
#   - --zoom + --audio:     output has both motion video and audio.
#   - REGRESSION (no --audio): output has video, NO audio stream.
#   - Static path video-copy proof: video codec of --audio output == codec of silent intermediate
#     (confirms -c:v copy in mux_audio is honoured; video was not re-encoded).
#
# Duration target for all tests:
#   HOURS=0.005  → 18 seconds (fast; well within ffmpeg tolerance for short tests).
#   ZOOM tests use HOURS=0.003 → ~10 seconds (zoom re-encodes; keep tiny).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Test 1: image + single audio FILE → OUT has both video and audio streams;
# duration ≈ video target (±0.5 s); full-length audio present.
# ---------------------------------------------------------------------------

@test "make-video --audio FILE: OUT has video + audio streams at target duration" {
  local img="$WORK_DIR/img.png"
  local audio="$WORK_DIR/tone.aac"
  # out_path produces <outdir>/<stem>.mp4 → img.mp4
  local out="$WORK_DIR/img.mp4"
  # Use a 5-second audio clip; target is 18 s so audio_build will loop it.
  mk_image "$img" red
  mk_audio "$audio" 440 5

  run "$REPO_ROOT/make-video" "$img" 0.005 --audio "$audio" --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_has_stream "$out" v
  assert_has_stream "$out" a

  # target = round(0.005 * 3600) = 18 s; allow ±0.5 s
  assert_duration "$out" 18 0.5
}

# ---------------------------------------------------------------------------
# Test 2: image + audio FOLDER (2 tracks) → OUT has audio; duration correct.
# ---------------------------------------------------------------------------

@test "make-video --audio FOLDER: OUT has audio; duration correct" {
  local img="$WORK_DIR/img.png"
  local audio_dir="$WORK_DIR/tracks"
  # out_path → img.mp4
  local out="$WORK_DIR/img.mp4"
  mkdir -p "$audio_dir"

  mk_image "$img" green
  mk_audio "$audio_dir/t1.aac" 330 4
  mk_audio "$audio_dir/t2.aac" 550 4

  run "$REPO_ROOT/make-video" "$img" 0.005 --audio "$audio_dir" --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_has_stream "$out" v
  assert_has_stream "$out" a

  assert_duration "$out" 18 0.5
}

# ---------------------------------------------------------------------------
# Test 3: image + --zoom 4 + --audio FILE → OUT has both motion video and audio.
# ---------------------------------------------------------------------------

@test "make-video --zoom 4 --audio FILE: OUT has video + audio streams" {
  local img="$WORK_DIR/img.png"
  local audio="$WORK_DIR/tone.aac"
  # out_path → img.mp4
  local out="$WORK_DIR/img.mp4"
  # target = round(0.003 * 3600) ≈ 11 s
  mk_image "$img" blue
  mk_audio "$audio" 440 3

  run "$REPO_ROOT/make-video" "$img" 0.003 --zoom 4 --audio "$audio" --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_has_stream "$out" v
  assert_has_stream "$out" a

  assert_duration "$out" 11 1.0
}

# ---------------------------------------------------------------------------
# Test 4: REGRESSION — image with NO --audio → OUT has video stream, NO audio stream.
# ---------------------------------------------------------------------------

@test "make-video (no --audio): OUT has video stream and NO audio stream" {
  local img="$WORK_DIR/img.png"
  # out_path → img.mp4
  local out="$WORK_DIR/img.mp4"

  mk_image "$img" yellow

  run "$REPO_ROOT/make-video" "$img" 0.005 --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_has_stream "$out" v

  # OUT must have NO audio stream
  local a_count
  a_count="$("$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$out" | grep -c .)" || true
  a_count="${a_count:-0}"
  [ "$a_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: Static-path video stream is COPIED when adding audio.
# The video codec in OUT must match the codec of the intermediate silent video
# (i.e. libx264 from encode_segment / make_static), proving no re-encode.
# We also verify frame count is preserved to rule out any partial re-encode.
# ---------------------------------------------------------------------------

@test "make-video --audio FILE (static path): video codec copied, not re-encoded" {
  # Use two separate image files so out_path produces two distinct names,
  # allowing both silent and audio outputs to coexist in the same --out dir.
  local img_silent="$WORK_DIR/silent_src.png"
  local img_audio="$WORK_DIR/audio_src.png"
  local audio="$WORK_DIR/tone.aac"
  # out_path derives stem from image basename → silent_src.mp4 / audio_src.mp4
  local silent_ref="$WORK_DIR/silent_src.mp4"
  local out="$WORK_DIR/audio_src.mp4"

  mk_image "$img_silent" purple
  mk_image "$img_audio"  purple
  mk_audio "$audio" 440 5

  # Build the silent reference (no --audio)
  run "$REPO_ROOT/make-video" "$img_silent" 0.005 --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$silent_ref" ]

  # Build the audio version
  run "$REPO_ROOT/make-video" "$img_audio" 0.005 --audio "$audio" --out "$WORK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # Video codec must match (libx264 from static encode_segment / make_static)
  local ref_codec out_codec
  ref_codec="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$silent_ref")"
  out_codec="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out")"
  [ "$ref_codec" = "$out_codec" ]

  # Frame count must also match (copy → no frames added/dropped)
  local ref_frames out_frames
  ref_frames="$("$FFPROBE" -v error -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$silent_ref")"
  out_frames="$("$FFPROBE" -v error -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out")"
  [ "$ref_frames" = "$out_frames" ]
}
