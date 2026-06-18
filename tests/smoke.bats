#!/usr/bin/env bats
#
# smoke.bats — proves the test harness itself works:
#   - mk_clip generates a clip
#   - assert_duration passes for ~3s (tol 0.3)
#   - assert_has_stream detects both audio and video streams

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load "$REPO_ROOT/tests/helpers/fixtures.sh"
  load "$REPO_ROOT/tests/helpers/assert.sh"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK_DIR"
}

@test "mk_clip produces a file" {
  mk_clip "$WORK_DIR/clip.mp4"
  [ -f "$WORK_DIR/clip.mp4" ]
}

@test "clip duration is approximately 3 seconds" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_duration "$WORK_DIR/clip.mp4" 3 0.3
}

@test "clip has a video stream" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_has_stream "$WORK_DIR/clip.mp4" v
}

@test "clip has an audio stream" {
  mk_clip "$WORK_DIR/clip.mp4"
  assert_has_stream "$WORK_DIR/clip.mp4" a
}

@test "mk_image produces a file" {
  mk_image "$WORK_DIR/frame.png" red
  [ -f "$WORK_DIR/frame.png" ]
}

@test "mk_audio produces a file" {
  mk_audio "$WORK_DIR/tone.aac" 440 2
  [ -f "$WORK_DIR/tone.aac" ]
}

@test "seam_ok passes on a clean mid-clip boundary" {
  # Use a longer clip (6s) so we have room for frame sampling
  mk_clip "$WORK_DIR/long.mp4" 220 6
  # Frame 90 is at the 3-second mark — interior, no seam
  assert_seam_ok "$WORK_DIR/long.mp4" 90
}
