#!/usr/bin/env bats
#
# mux.bats — tests for lib/mux.sh :: mux_audio VIDEO AUDIO OUT
#
# Contract:
#   - Combines VIDEO + AUDIO into OUT
#   - Video stream COPIED (-c:v copy); audio encoded to AAC (-c:a aac)
#   - If VIDEO already has audio, the supplied AUDIO replaces it
#     (OUT has exactly one audio stream)
#   - OUT duration ≈ VIDEO duration (video is master clock)
#   - -movflags +faststart; quiet; validates inputs exist
#   - Returns non-zero + stderr if VIDEO or AUDIO is missing

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

bats_require_minimum_version 1.5.0

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  source "$REPO_ROOT/lib/mux.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# Helper: build a silent video fixture
# A color video with no audio track, 3 seconds, libx264.
# ---------------------------------------------------------------------------
mk_silent_video() {
  local out="${1:?mk_silent_video: OUT required}"
  local secs="${2:-3}"
  "$FFMPEG" \
    -nostdin -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:d=${secs}" \
    -r 30 \
    -c:v libx264 -pix_fmt yuv420p \
    -an \
    "$out"
}

# ---------------------------------------------------------------------------
# Test 1: muxing audio onto a silent video yields OUT with both v and a streams
# ---------------------------------------------------------------------------

@test "mux_audio: silent video + audio → OUT has both video and audio streams" {
  local silent="$WORK_DIR/silent.mp4"
  local audio="$WORK_DIR/tone.aac"
  local out="$WORK_DIR/out.mp4"

  mk_silent_video "$silent" 3
  mk_audio "$audio" 440 3

  run mux_audio "$silent" "$audio" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  assert_has_stream "$out" v
  assert_has_stream "$out" a
}

# ---------------------------------------------------------------------------
# Test 2: video codec of OUT equals video codec of VIDEO (stream was copied)
# Also assert nb_frames and width match as a stronger codec-copy check.
# ---------------------------------------------------------------------------

@test "mux_audio: video codec of OUT matches VIDEO (stream copied, not re-encoded)" {
  local silent="$WORK_DIR/silent.mp4"
  local audio="$WORK_DIR/tone.aac"
  local out="$WORK_DIR/out.mp4"

  mk_silent_video "$silent" 3
  mk_audio "$audio" 440 3

  run mux_audio "$silent" "$audio" "$out"
  [ "$status" -eq 0 ]

  local src_codec out_codec
  src_codec="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$silent")"
  out_codec="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out")"
  [ "$src_codec" = "$out_codec" ]

  # Width must also match (sanity: same stream geometry)
  local src_width out_width
  src_width="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 \
    "$silent")"
  out_width="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out")"
  [ "$src_width" = "$out_width" ]

  # nb_frames must match (copy means no frames added or dropped)
  local src_frames out_frames
  src_frames="$("$FFPROBE" -v error -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$silent")"
  out_frames="$("$FFPROBE" -v error -select_streams v:0 \
    -count_packets \
    -show_entries stream=nb_read_packets \
    -of default=noprint_wrappers=1:nokey=1 \
    "$out")"
  [ "$src_frames" = "$out_frames" ]
}

# ---------------------------------------------------------------------------
# Test 3: OUT duration ≈ VIDEO duration (video is master clock)
# ---------------------------------------------------------------------------

@test "mux_audio: OUT duration matches VIDEO duration within tolerance" {
  local silent="$WORK_DIR/silent.mp4"
  local audio="$WORK_DIR/tone.aac"
  local out="$WORK_DIR/out.mp4"

  mk_silent_video "$silent" 3
  mk_audio "$audio" 440 3

  run mux_audio "$silent" "$audio" "$out"
  [ "$status" -eq 0 ]

  assert_duration "$out" 3 0.3
}

# ---------------------------------------------------------------------------
# Test 4: muxing onto a video that already has audio REPLACES the audio
# OUT must have exactly ONE audio stream.
# ---------------------------------------------------------------------------

@test "mux_audio: existing audio in VIDEO is replaced — OUT has exactly one audio stream" {
  local clip="$WORK_DIR/clip.mp4"         # has video + audio (sine @ 220 Hz)
  local new_audio="$WORK_DIR/new.aac"     # different sine @ 880 Hz
  local out="$WORK_DIR/out.mp4"

  mk_clip "$clip" 220 3                   # mk_clip embeds an audio track
  mk_audio "$new_audio" 880 3

  run mux_audio "$clip" "$new_audio" "$out"
  [ "$status" -eq 0 ]

  # Count audio streams in OUT — must be exactly 1
  local count
  count="$("$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$out" | grep -c .)" || true
  count="${count:-0}"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 5a: missing VIDEO → non-zero return + stderr message
# ---------------------------------------------------------------------------

@test "mux_audio: missing VIDEO → non-zero exit + stderr message" {
  local audio="$WORK_DIR/tone.aac"
  local out="$WORK_DIR/out.mp4"

  mk_audio "$audio" 440 3

  run --separate-stderr mux_audio "$WORK_DIR/no_such_video.mp4" "$audio" "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Test 5b: missing AUDIO → non-zero return + stderr message
# ---------------------------------------------------------------------------

@test "mux_audio: missing AUDIO → non-zero exit + stderr message" {
  local silent="$WORK_DIR/silent.mp4"
  local out="$WORK_DIR/out.mp4"

  mk_silent_video "$silent" 3

  run --separate-stderr mux_audio "$silent" "$WORK_DIR/no_such_audio.aac" "$out"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
}
